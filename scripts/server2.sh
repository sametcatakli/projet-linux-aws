#!/usr/bin/env bash
#
# server2.sh  — Server Web (10.42.0.73)
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

# --- API endpoint ---
API_HOST="10.42.0.158"
API_PORT=8000

# 1) RAID-1 + LUKS + LVM + mount
encrypt_and_setup(){
  if ! grep -q "^${MD_DEVICE}" /proc/mdstat; then
    echo "→ Création RAID-1"
    for d in "$DEV1" "$DEV2"; do
      parted -s "$d" mklabel gpt mkpart primary 0% 100% set 1 raid on
    done
    mdadm --create "$MD_DEVICE" --level=1 --raid-devices=2 "${DEV1}p1" "${DEV2}p1"
    echo "$(mdadm --detail --scan)" >> /etc/mdadm.conf
  fi

  if ! cryptsetup isLuks "$MD_DEVICE"; then
    echo "→ Format LUKS"
    printf "%s" "$LUKS_PASSWORD" > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    cryptsetup luksFormat "$MD_DEVICE" "$KEY_FILE" --batch-mode
  fi
  cryptsetup open "$MD_DEVICE" "$CRYPT_NAME" --key-file "$KEY_FILE"

  PV="/dev/mapper/${CRYPT_NAME}"
  pvs "$PV" >/dev/null 2>&1 || pvcreate "$PV"
  vgs "$VG_NAME" >/dev/null 2>&1 || vgcreate "$VG_NAME" "$PV"
  lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1 || lvcreate -l 100%VG -n "$LV_NAME" "$VG_NAME"

  mkfs.ext4 -F -L srv "/dev/${VG_NAME}/${LV_NAME}"
  mkdir -p "$MOUNT_POINT"
  grep -q "^${CRYPT_NAME}" /etc/crypttab \
    || echo "${CRYPT_NAME}  ${MD_DEVICE}  ${KEY_FILE}  luks" >> /etc/crypttab
  grep -q "/dev/${VG_NAME}/${LV_NAME}" /etc/fstab \
    || echo "/dev/${VG_NAME}/${LV_NAME}  ${MOUNT_POINT}  ext4  defaults,noatime  0 2" >> /etc/fstab
  mount -a
  echo "→ /srv monté sur LUKS/LVM"
}

# 2) Apache, MariaDB, Samba, NFS
setup_web(){
  echo "→ Installation des services web"
  yum install -y httpd mariadb-server samba nfs-utils curl
  systemctl enable --now httpd mariadb smb nmb nfs-server

  # Sécuriser MariaDB
  mysql -e "DELETE FROM mysql.user WHERE User=''"      || true
  mysql -e "DROP DATABASE IF EXISTS test"               || true
  mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%'" || true
  mysql -e "FLUSH PRIVILEGES"                           || true

  mkdir -p "${MOUNT_POINT}/www"
  cat >> /etc/httpd/conf/httpd.conf <<EOF
<Directory "${MOUNT_POINT}/www">
    Require all granted
</Directory>
EOF

  # NFS root share
  grep -q "${MOUNT_POINT}/www" /etc/exports \
    || echo "${MOUNT_POINT}/www 10.42.0.0/24(rw,sync,no_root_squash)" >> /etc/exports
  exportfs -ra
}

# 3) Gestion interactive des users (+ SMB, NFS, vhost, DNS via API)
manage_users(){
  while true; do
    echo; echo "1) Ajouter un user   q) Quitter"
    read -rp "> " choice
    case "$choice" in
      1)
        read -rp "Nom d'utilisateur : " u
        useradd -m -s /bin/bash "$u"
        # home‐dir web
        mkdir -p "${MOUNT_POINT}/www/${u}"
        chown "$u":"$u" "${MOUNT_POINT}/www/${u}"
        # Apache vhost
        cat > /etc/httpd/conf.d/${u}.conf <<EOF
<VirtualHost *:80>
    ServerName ${u}.toto.lan
    DocumentRoot ${MOUNT_POINT}/www/${u}
    <Directory ${MOUNT_POINT}/www/${u}>
        Require all granted
    </Directory>
</VirtualHost>
EOF
        systemctl reload httpd
        # Samba
        grep -q "\[${u}\]" /etc/samba/smb.conf \
          || cat >> /etc/samba/smb.conf <<EOF

[${u}]
  path = ${MOUNT_POINT}/www/${u}
  valid users = ${u}
  read only = no
  create mask = 0750
EOF
        systemctl reload smb
        # NFS
        grep -q "${MOUNT_POINT}/www/${u}" /etc/exports \
          || echo "${MOUNT_POINT}/www/${u} 10.42.0.0/24(rw,sync,no_root_squash)" >> /etc/exports
        exportfs -ra
        # SMB password = username
        smbpasswd -a "$u" <<< "$u\n$u" &>/dev/null
        # DNS via API with token
        curl -s -H "Authorization: Bearer $API_TOKEN" \
          -X POST "http://${API_HOST}:${API_PORT}/add?host=${u}&ip=$(hostname -I | awk '{print $1}')"
        echo "→ Utilisateur $u créé avec SMB, NFS, Apache et DNS."
        ;;
      q) break ;;
      *) echo "Choix invalide." ;;
    esac
  done
}

main(){
  encrypt_and_setup
  setup_web
  manage_users
  echo "--- Server Web prêt ---"
}
main
