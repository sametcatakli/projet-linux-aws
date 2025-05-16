#!/bin/bash

BACKUP_USER="ec2-user"
BACKUP_HOST="10.42.0.129"
DIRS_TO_BACKUP=("/var" "/home" "/srv")
BACKUP_DIR="~/saveConf"

for DIR in "${DIRS_TO_BACKUP[@]}"
do
    echo "Sauvegarde de $DIR vers $BACKUP_HOST:$BACKUP_DIR$(dirname $DIR)"
    rsync -avz --delete --exclude=lost+found -e "ssh -i ~/.ssh/serveur2.pem" "$DIR" "$BACKUP_USER@$BACKUP_HOST:$BACKUP_DIR$(dirname $DIR)/"
done

echo "Sauvegarde terminée."

!RENDRE EXECUTABLE
chmod +x backup.sh

touch /var/log/backup.log
chmod 777 /var/log/backup.log

!AJOUTER LES CRONTABS
crontab -e
0 2 * * * /home/projet-linux-aws/scripts/backup.sh >> /var/log/backup.log 2>&1
