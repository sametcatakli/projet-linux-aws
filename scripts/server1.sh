#!/usr/bin/env bash
#
# network_setup.sh  — Server Réseau (10.42.0.158)
#
set -euo pipefail
IFS=$'\n\t'

# --- Load secrets from .env in the same folder as this script ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
[ -f "$ENV_FILE" ] || { echo "$ENV_FILE introuvable"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${LUKS_PASSWORD:?LUKS_PASSWORD non défini dans $ENV_FILE}"
: "${API_TOKEN:?API_TOKEN non défini dans $ENV_FILE}"

# --- Disk & LUKS/LVM settings ---
DEV1="/dev/nvme1n1"
DEV2="/dev/nvme2n1"
MD_DEVICE="/dev/md0"
CRYPT_NAME="crypt_srv"
KEY_FILE="/root/crypt.key"
MOUNT_POINT="/srv"
VG_NAME="vg_srv"
LV_NAME="lv_srv"

# --- DNS / NTP / API settings ---
DOMAIN="toto.lan"
NET_CIDR="10.42.0.0/24"
DNS_ZONE_DIR="${MOUNT_POINT}/dns/zones"
API_DIR="${MOUNT_POINT}/api/dns_api"
API_PORT=8000

# 1) RAID-1 + LUKS + LVM + mount
create_encrypted_raid_lvm(){
  # RAID
  if ! grep -q "^${MD_DEVICE}" /proc/mdstat; then
    echo "→ Création RAID-1"
    for d in "$DEV1" "$DEV2"; do
      parted -s "$d" mklabel gpt mkpart primary 0% 100% set 1 raid on
    done
    mdadm --create "$MD_DEVICE" --level=1 --raid-devices=2 "${DEV1}p1" "${DEV2}p1"
    echo "$(mdadm --detail --scan)" >> /etc/mdadm.conf
  fi

  # LUKS
  if ! cryptsetup isLuks "$MD_DEVICE"; then
    echo "→ Format LUKS"
    printf "%s" "$LUKS_PASSWORD" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    cryptsetup luksFormat "$MD_DEVICE" "$KEY_FILE" --batch-mode
  fi
  # open
  if [ ! -e "/dev/mapper/${CRYPT_NAME}" ]; then
    cryptsetup open "$MD_DEVICE" "$CRYPT_NAME" --key-file "$KEY_FILE"
  fi

  # LVM on top of LUKS
  PV="/dev/mapper/${CRYPT_NAME}"
  pvs "$PV" >/dev/null 2>&1 || pvcreate "$PV"
  vgs "$VG_NAME" >/dev/null 2>&1 || vgcreate "$VG_NAME" "$PV"
  lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1 || lvcreate -l 100%VG -n "$LV_NAME" "$VG_NAME"

  # FS & mount
  FS_DEV="/dev/${VG_NAME}/${LV_NAME}"
  mkfs.ext4 -F -L srv "$FS_DEV"
  mkdir -p "$MOUNT_POINT"
  grep -q "^${CRYPT_NAME}" /etc/crypttab \
    || echo "${CRYPT_NAME}  ${MD_DEVICE}  ${KEY_FILE}  luks" >> /etc/crypttab
  grep -q "${FS_DEV}" /etc/fstab \
    || echo "${FS_DEV}  ${MOUNT_POINT}  ext4  defaults,noatime  0 2" >> /etc/fstab
  systemctl enable --now lvm2-lvmetad || true
  mount -a
  echo "→ /srv monté sur LUKS/LVM"
}

# 2) DNS maître+cache, zone inverse & NTP
setup_network_services(){
  echo "→ Installation bind-utils, bind & chrony"
  yum install -y bind bind-utils chrony python3-pip

  mkdir -p "$DNS_ZONE_DIR"
  # Chrony
  sed -i '/^pool/s/^/#/' /etc/chrony.conf
  cat >> /etc/chrony.conf <<EOF
pool 0.be.pool.ntp.org iburst
allow ${NET_CIDR}
EOF
  systemctl enable --now chronyd

  # Bind config
  sed -i 's/^\s*recursion.*/    recursion yes;/' /etc/named.conf
  sed -i 's/^\s*allow-query.*/    allow-query { any; };/' /etc/named.conf
  sed -i 's/^\s*allow-recursion.*/    allow-recursion { '"${NET_CIDR}"'; };/' /etc/named.conf
  cat >> /etc/named.conf <<EOF

zone "${DOMAIN}" IN {
    type master;
    file "${DNS_ZONE_DIR}/db.${DOMAIN}";
    allow-update { none; };
};

zone "0.42.10.in-addr.arpa" IN {
    type master;
    file "${DNS_ZONE_DIR}/db.10.42.0";
    allow-update { none; };
};
EOF

  # Forward zone
  [[ -f "${DNS_ZONE_DIR}/db.${DOMAIN}" ]] || cat > "${DNS_ZONE_DIR}/db.${DOMAIN}" <<EOF
\$TTL 1D
@   IN SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
        $(date +"%Y%m%d")01 ; serial
        1H         ; refresh
        15M        ; retry
        1W         ; expire
        1D )      ; minimum
    IN NS   ns1.${DOMAIN}.
ns1 IN A    10.42.0.158
www IN A    10.42.0.73
EOF

  # Reverse zone
  [[ -f "${DNS_ZONE_DIR}/db.10.42.0" ]] || cat > "${DNS_ZONE_DIR}/db.10.42.0" <<EOF
\$TTL 1D
@   IN SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
        $(date +"%Y%m%d")01 ; serial
        1H         ; refresh
        15M        ; retry
        1W         ; expire
        1D )      ; minimum
    IN NS   ns1.${DOMAIN}.
158 IN PTR  ns1.${DOMAIN}.
73  IN PTR  www.${DOMAIN}.
EOF

  systemctl enable --now named
  echo "→ DNS & NTP configurés"
}

# 3) DNS-API via FastAPI + token auth
setup_dns_api(){
  echo "→ Installation FastAPI & dnspython"
  pip3 install fastapi uvicorn dnspython

  mkdir -p "$API_DIR"
  cat > "$API_DIR/app.py" <<'PY'
from fastapi import FastAPI, HTTPException, Header
import dns.update, dns.query, os

app = FastAPI()
ZONE = os.getenv("DOMAIN", "toto.lan")
API_TOKEN = os.getenv("API_TOKEN")
DNS_SERVER = os.getenv("DNS_SERVER", "127.0.0.1")

def verify(token: str):
    if token != f"Bearer {API_TOKEN}":
        raise HTTPException(401, "Unauthorized")

@app.post("/add")
def add(host: str, ip: str, authorization: str = Header(None)):
    verify(authorization)
    u = dns.update.Update(ZONE)
    u.replace(host, 300, "A", ip)
    resp = dns.query.tcp(u, DNS_SERVER)
    return {"result": resp.to_text()}

@app.post("/del")
def delete(host: str, authorization: str = Header(None)):
    verify(authorization)
    u = dns.update.Update(ZONE)
    u.delete(host, "A")
    resp = dns.query.tcp(u, DNS_SERVER)
    return {"result": resp.to_text()}
PY

  cat > /etc/systemd/system/dnsapi.service <<EOF
[Unit]
Description=DNS Update API
After=network.target named.service

[Service]
WorkingDirectory=${API_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/uvicorn app:app --host 0.0.0.0 --port ${API_PORT}
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now dnsapi.service
  echo "→ DNS API configurée (port ${API_PORT})"
}

main(){
  create_encrypted_raid_lvm
  setup_network_services
  setup_dns_api
  echo "--- Server Réseau prêt ---"
}
main
