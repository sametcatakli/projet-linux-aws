#!/bin/sh
#
# backup-sync-s3.sh — Sync quotidien de /srv/database et /srv/web vers S3
#

# === 1) CONFIGURATION (À PERSONNALISER) ===
AWS_ACCESS_KEY_ID="ASIAT2STJLI2IL3AC3JO"
AWS_SECRET_ACCESS_KEY="0G21TRe5/+wH3I5aFnjvGRMseql7SgooAFLKyub3"
AWS_DEFAULT_REGION="us-east-1"
BUCKET_NAME="backup-projet-linux-heh"

SCRIPT_PATH="/home/ec2-user/backup-sync-s3.sh"
LOG_FILE="/home/ec2-user/backup-sync-s3.log"
LOCAL_DIRS="/srv/database /srv/web"

# Vérifier que le nom du bucket est renseigné
if [ -z "$BUCKET_NAME" ]; then
  echo "[ERROR] BUCKET_NAME non défini ! Éditez le script." >&2
  exit 1
fi

# === 2) INSTALLATION ROBUSTE DE L'AWS CLI VIA DNF (FALLBACK PIP) ===
if ! command -v aws >/dev/null 2>&1; then
  echo "[INFO] AWS CLI introuvable → installation via dnf…"
  if command -v dnf >/dev/null 2>&1; then
    dnf makecache
    if ! dnf install -y awscli python3 python3-pip; then
      echo "[WARN] dnf awscli a échoué → fallback pip" >&2
      python3 -m pip install --no-cache-dir awscli \
        || { echo "[ERROR] Impossible d’installer awscli via pip" >&2; exit 1; }
    fi
  else
    echo "[ERROR] dnf introuvable, impossible d’installer awscli" >&2
    exit 1
  fi
fi

# === 3) EXPORTER LES IDENTIFIANTS & LA RÉGION ===
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

# === 4) SYNCHRONISATION QUOTIDIENNE ===
for DIR in $LOCAL_DIRS; do
  NAME=$(basename "$DIR")
  echo "[INFO] $(date '+%F %T') — Sync $DIR → s3://$BUCKET_NAME/$NAME"
  aws s3 sync \
    "$DIR" \
    "s3://$BUCKET_NAME/$NAME" \
    --delete \
    >> "$LOG_FILE" 2>&1
  if [ $? -ne 0 ]; then
    echo "[ERROR] Échec du sync de $DIR (voir $LOG_FILE)" >&2
  fi
done

# === 5) CRON (02:00 chaque jour) ===
CRON_ENTRY="0 2 * * * $SCRIPT_PATH >> $LOG_FILE 2>&1"
# On ajoute la tâche si elle n'existe pas déjà
crontab -l 2>/dev/null | grep -F "$CRON_ENTRY" >/dev/null || \
  ( crontab -l 2>/dev/null; echo "$CRON_ENTRY" ) | crontab -

exit 0
