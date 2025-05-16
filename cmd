sudo mkdir -p /mnt/share
sudo mount -t nfs 10.42.0.119:/srv/share /mnt/share

sudo clamscan -r /mnt/share
/usr/bin/freshclam --quiet && /usr/bin/clamdscan  /srv/web --log=/var/log/clamav/daily_scan.log



sudo rkhunter --propupd
sudo rkhunter --update && sudo rkhunter --check --skip-keypress

0 0 * * * sh /home/ec2-user/projet-linux-aws/scripts/backup.sh >> /var/backup.log

/home/ec2-user/projet-linux-aws/scripts/backup.sh >> /var/backup.log
