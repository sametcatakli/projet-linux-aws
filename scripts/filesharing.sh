#!/bin/bash

# File sharing menu
file_sharing_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                ${BLUE}File Sharing Services Menu ${NC}                         |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. NFS Share                                                         |"
    echo "| 2. Samba Share                                                       |"
    echo "| 3. FTP Share                                                         |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " share_choice
    case $share_choice in
      1) nfs_share ;;
      2) smb_share ;;
      3) ftp_share ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# NFS share function
nfs_share() {
  echo "Installing NFS share"
  sudo mkdir -p /srv/share

  # Install NFS utilities
  install_if_missing nfs-utils

  # Enable and start NFS server
  systemctl enable nfs-server --now

  # Configure firewall if available
  if systemctl is-active --quiet firewalld; then
      echo "Configuring firewall for NFS..."
      firewall-cmd --permanent --add-service=nfs || echo "Failed to add NFS service to firewall"
      firewall-cmd --permanent --add-service=mountd || echo "Failed to add mountd service to firewall"
      firewall-cmd --permanent --add-service=rpc-bind || echo "Failed to add rpc-bind service to firewall"
      firewall-cmd --reload || echo "Failed to reload firewall"
  else
      echo "Firewalld is not active. Please enable it and configure NFS firewall rules later."
  fi

  # Set up quota for NFS share
  if command -v setquota &> /dev/null; then
      echo "Setting up quota for NFS share..."
      # Set a soft and hard limit of 50MB for the nobody user
      setquota -u nobody 50000 55000 0 0 /srv/share || echo "Failed to set quota, continuing anyway..."
  fi

  # Configure NFS exports
  echo "/srv/share *(rw,sync,no_root_squash)" > /etc/exports
  exportfs -a

  # Restart NFS server
  systemctl restart nfs-server

  echo "NFS services restarted"
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Samba share function
smb_share() {
  echo "Installing Samba share"
  sudo mkdir -p /srv/share

  # Install required packages
  dnf -y install samba samba-client

  # Check if firewalld is installed, and install if not
  if command -v firewall-cmd &> /dev/null; then
      echo "Configuring firewall for Samba..."
      firewall-cmd --permanent --add-service=samba || echo "Firewall rule addition failed, continuing anyway..."
      firewall-cmd --reload || echo "Firewall reload failed, continuing anyway..."
  else
      echo "firewalld not detected. If you need firewall rules, please configure them manually."
  fi

  # Setup quota for the share directory
  echo "Setting up quotas for Samba share..."
  if command -v setquota &> /dev/null; then
      # Set a soft and hard limit of 50MB for the nobody user (used for anonymous shares)
      setquota -u nobody 50000 55000 0 0 /srv/share || echo "Failed to set quota for nobody user, continuing anyway..."
  else
      echo "setquota command not found. Quota setup skipped."
  fi

  chown -R nobody:nobody /srv/share
  chmod -R 0777 /srv/share

  cat <<EOL > /etc/samba/smb.unauth.conf
[unauth_share]
   path = /srv/share/
   browsable = yes
   writable = yes
   guest ok = yes
   guest only = yes
   force user = nobody
   force group = nobody
   create mask = 0777
   directory mask = 0777
   read only = no
EOL

  PRIMARY_CONF="/etc/samba/smb.conf"
  INCLUDE_LINE="include = /etc/samba/smb.unauth.conf"

  if ! grep -Fxq "$INCLUDE_LINE" "$PRIMARY_CONF"; then
      echo "$INCLUDE_LINE" >> "$PRIMARY_CONF"
      echo "Include line added to $PRIMARY_CONF"
  else
      echo "Include line already exists in $PRIMARY_CONF"
  fi

  # SELinux configuration if SELinux is enabled
  if command -v sestatus &> /dev/null && sestatus | grep -q "enabled"; then
      echo "Configuring SELinux for Samba..."
      /sbin/restorecon -R -v /srv/share || echo "SELinux restorecon failed, continuing anyway..."
      setsebool -P samba_export_all_rw 1 || echo "SELinux boolean setting failed, continuing anyway..."
  else
      echo "SELinux not detected or not enabled."
  fi

  # Restart Samba services
  systemctl restart smb || echo "Failed to restart smb service, check if it's installed properly"
  systemctl restart nmb || echo "Failed to restart nmb service, check if it's installed properly"
  systemctl enable smb
  systemctl enable nmb

  echo "Samba services restarted"

  echo "Press any key to continue..."
  read -n 1 -s key
}

# FTP share function
ftp_share() {
  echo "Installing and configuring anonymous FTP share..."

  # Install vsftpd
  dnf -y install vsftpd

  # Backup original config
  cp /etc/vsftpd/vsftpd.conf /etc/vsftpd/vsftpd.conf.bak

  # Create FTP directory
  mkdir -p /srv/share/ftp
  chown -R nobody:nobody /srv/share/ftp
  chmod -R 0777 /srv/share/ftp

  # Set up quota for FTP share
  if command -v setquota &> /dev/null; then
      echo "Setting up quota for FTP share..."
      # Set a soft and hard limit of 50MB for the nobody user
      setquota -u nobody 50000 55000 0 0 /srv/share || echo "Failed to set quota, continuing anyway..."
  fi

  # Configure anonymous FTP
  cat <<EOL > /etc/vsftpd/vsftpd.conf
anonymous_enable=YES
local_enable=YES
write_enable=YES
anon_upload_enable=YES
anon_mkdir_write_enable=YES
dirmessage_enable=YES
xferlog_enable=YES
connect_from_port_20=YES
chown_uploads=NO
xferlog_std_format=YES
listen=YES
listen_ipv6=NO
pam_service_name=vsftpd
userlist_enable=YES
anon_root=/srv/share/ftp
anon_umask=022
pasv_enable=YES
pasv_min_port=30000
pasv_max_port=31000
EOL

  # Enable and start vsftpd
  systemctl enable vsftpd
  systemctl start vsftpd

  # Open FTP ports in firewall
  firewall-cmd --permanent --add-service=ftp
  firewall-cmd --permanent --add-port=30000-31000/tcp  # For passive FTP
  firewall-cmd --reload

  echo "Anonymous FTP share configured at /srv/share/ftp"
  echo "Press any key to continue..."
  read -n 1 -s key
}
