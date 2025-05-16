#!/bin/bash

# User management menu
user_management_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                ${BLUE}User Management Menu ${NC}                               |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. Add User (with Web, Database, and File Sharing Access)            |"
    echo "| 2. Remove User                                                       |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " user_choice
    case $user_choice in
      1) add_user ;;
      2) remove_user ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Add user function
add_user() {
  echo "Adding a user ..."
  read -p "Enter the server domain name (e.g., example.com) : " DOMAIN_NAME
  read -p "Enter a username: " USERNAME

  # Refuse creation of 'root'
  if [[ "$USERNAME" == "root" ]]; then
    echo "Erreur : la création de l'utilisateur 'root' est interdite."
    echo "Appuyez sur une touche pour continuer..."
    read -n 1 -s
    return
  fi

  read -sp "Enter a password: " PASSWORD
  echo
  echo "Creating directory"
  DIR="/srv/web/$USERNAME"
  mkdir -p "$DIR"
  echo "Created $DIR directory ... "

  # Create user
  useradd $USERNAME
  echo "$USERNAME:$PASSWORD" | chpasswd

  # Create home directory and set quota
  if [ ! -d "/home/$USERNAME" ]; then
    mkdir -p "/home/$USERNAME"
    chown $USERNAME:$USERNAME "/home/$USERNAME"
    chmod 700 "/home/$USERNAME"
  fi

  # Set quota for user's home directory (50MB)
  if command -v setquota &> /dev/null; then
    echo "Setting quota for user's home directory..."
    # Set soft limit to 50MB, hard limit to 55MB
    setquota -u $USERNAME 50000 55000 0 0 /home || echo "Failed to set home directory quota, continuing anyway..."
    echo "Home directory quota set to 50MB for $USERNAME"
  else
    echo "WARNING: setquota command not found. Home directory quota not set."
  fi

  # Set quota for web directory (50MB)
  if command -v setquota &> /dev/null; then
    echo "Setting quota for user's web directory..."
    # Set soft limit to 50MB, hard limit to 55MB
    setquota -u $USERNAME 50000 55000 0 0 /srv/web || echo "Failed to set web directory quota, continuing anyway..."
    echo "Web directory quota set to 50MB for $USERNAME"
  else
    echo "WARNING: setquota command not found. Web directory quota not set."
  fi

  # Add SMB user
  if command -v smbpasswd &> /dev/null; then
      (echo "$PASSWORD"; echo "$PASSWORD") | smbpasswd -a $USERNAME
      echo "SMB user created"
  else
      echo "WARNING: smbpasswd not found. SMB user not created."
  fi

  # Set permissions
  chown -R $USERNAME:$USERNAME "$DIR"
  chmod -R 755 "$DIR"

  # Add SMB share configuration
  if [ -f "/etc/samba/smb.conf" ]; then
      cat <<EOL >> /etc/samba/smb.conf
[$USERNAME]
    path = $DIR
    valid users = $USERNAME
    read only = no
EOL
      systemctl restart smb || echo "Failed to restart smb service"
  else
      echo "WARNING: Samba configuration file not found. SMB share not created."
  fi

  # Configure FTP access for the user
  echo "Setting up FTP access for $USERNAME..."

  # Check if vsftpd is installed, if not install it
  if ! rpm -q vsftpd &>/dev/null; then
      echo "Installing vsftpd for FTP access..."
      dnf install -y vsftpd
  fi

  # Make sure vsftpd is running
  systemctl enable vsftpd
  systemctl start vsftpd

  # Ensure the user can access their home directory via FTP
  mkdir -p "$DIR/ftp"
  chown $USERNAME:$USERNAME "$DIR/ftp"
  chmod 755 "$DIR/ftp"

  # Add firewall rule for FTP if not already added
  firewall-cmd --permanent --add-service=ftp
  firewall-cmd --permanent --add-port=30000-31000/tcp  # For passive FTP
  firewall-cmd --reload

  # Check if MariaDB is installed and running
  if ! rpm -q MariaDB-server &>/dev/null || ! systemctl is-active --quiet mariadb; then
      echo -e "${RED}WARNING: MariaDB is not installed or not running. Database will not be created.${NC}"
      echo "Please install MariaDB first from the main menu (option 10)."
  else
      # Create the user's database with size limit
      echo "Creating database for user $USERNAME with 100MB limit..."
      create_limited_database "$USERNAME" 100 "$PASSWORD"
      echo "Database ${USERNAME}_db created with 100MB limit."

      # Create the phpMyAdmin user access separately for better control
      echo "Setting up phpMyAdmin access for $USERNAME..."
      mysql -u root -prootpassword -e "GRANT SELECT ON mysql.db TO '$USERNAME'@'localhost';" || {
          echo -e "${YELLOW}Warning: Could not grant phpMyAdmin access privileges for $USERNAME.${NC}"
      }

      mysql -u root -prootpassword -e "GRANT SELECT ON mysql.user TO '$USERNAME'@'localhost';" || {
          echo -e "${YELLOW}Warning: Could not grant phpMyAdmin access privileges for $USERNAME.${NC}"
      }

      # For phpMyAdmin storage features if configured
      mysql -u root -prootpassword -e "GRANT SELECT, INSERT, UPDATE, DELETE ON phpmyadmin.* TO '$USERNAME'@'localhost';" || {
          echo -e "${YELLOW}Warning: Could not grant phpMyAdmin storage privileges for $USERNAME. This is normal if the phpmyadmin database doesn't exist.${NC}"
      }

      mysql -u root -prootpassword -e "FLUSH PRIVILEGES;" || {
          echo -e "${RED}Failed to flush privileges.${NC}"
      }

      echo -e "${GREEN}Database user '$USERNAME' configured with phpMyAdmin access.${NC}"
  fi

  # Create a simple index.php file in the user's directory
  echo "<html><body><h1>Welcome, $USERNAME!</h1><p>Your database name is ${USERNAME}_db.</p><?php phpinfo(); ?></body></html>" > "$DIR/index.php"

  # Set up the virtual host for the user's website (HTTP with redirect to HTTPS)
  cat <<EOL > /etc/httpd/conf.d/001-$USERNAME.conf
<VirtualHost *:80>
    ServerName $USERNAME.$DOMAIN_NAME
    DocumentRoot /srv/web/$USERNAME
    <Directory /srv/web/$USERNAME>
        AllowOverride All
        Require all granted
    </Directory>
    DirectoryIndex index.php
    ErrorLog /var/log/httpd/${USERNAME}_error.log
    CustomLog /var/log/httpd/${USERNAME}_access.log combined

    # Redirect all HTTP traffic to HTTPS
    Redirect "/" "https://$USERNAME.$DOMAIN_NAME/"
</VirtualHost>
EOL

  # Only add HTTPS if SSL certificates exist
  if [ -f "/etc/httpd/ssl/$DOMAIN_NAME.crt" ] && [ -f "/etc/httpd/ssl/$DOMAIN_NAME.key" ]; then
      cat <<EOL >> /etc/httpd/conf.d/001-$USERNAME.conf
<VirtualHost *:443>
    ServerName $USERNAME.$DOMAIN_NAME
    DocumentRoot /srv/web/$USERNAME
    <Directory /srv/web/$USERNAME>
        AllowOverride All
        Require all granted
    </Directory>
    DirectoryIndex index.php
    SSLEngine on
    SSLCertificateFile /etc/httpd/ssl/$DOMAIN_NAME.crt
    SSLCertificateKeyFile /etc/httpd/ssl/$DOMAIN_NAME.key
    ErrorLog /var/log/httpd/${USERNAME}_ssl_error.log
    CustomLog /var/log/httpd/${USERNAME}_ssl_access.log combined
</VirtualHost>
EOL
  else
      echo "WARNING: SSL certificates not found. HTTPS not configured."
  fi

  # Configure SELinux if enabled
  if command -v semanage &> /dev/null && command -v sestatus &> /dev/null && sestatus | grep -q "enabled"; then
      echo "Configuring SELinux for web content..."
      semanage fcontext -a -e /var/www /srv/web || echo "SELinux context setting failed, continuing anyway..."
      restorecon -Rv /srv || echo "SELinux context restoration failed, continuing anyway..."
  fi

  # Update DNS entry if available
  if [ -f "/var/named/forward.$DOMAIN_NAME" ]; then
      # Check if entry already exists
      if ! grep -q "^$USERNAME" "/var/named/forward.$DOMAIN_NAME"; then
          # Get the server IP address
          SERVER_IP=$(grep "^@" "/var/named/forward.$DOMAIN_NAME" | awk '{print $NF}')
          if [ -n "$SERVER_IP" ]; then
              # Add the user subdomain to DNS
              sed -i "/^ns /a $USERNAME      IN  A       $SERVER_IP" "/var/named/forward.$DOMAIN_NAME"
              # Increment the serial number in the SOA record
              serial=$(grep "Serial" /var/named/forward.$DOMAIN_NAME | awk '{print $1}')
              new_serial=$((serial + 1))
              sed -i "s/$serial ; Serial/$new_serial ; Serial/" "/var/named/forward.$DOMAIN_NAME"
              # Reload named service
              systemctl reload named
              echo "DNS entry for $USERNAME.$DOMAIN_NAME added successfully."
          fi
      fi
  fi

  # Restart Apache
  systemctl restart httpd || echo "Failed to restart httpd service"

  echo -e "${GREEN}User $USERNAME has been created with web, FTP, and SMB access.${NC}"
  if rpm -q MariaDB-server &>/dev/null && systemctl is-active --quiet mariadb; then
      echo -e "${GREEN}Database ${USERNAME}_db has been created with a 100MB limit.${NC}"
      echo -e "${GREEN}User can access phpMyAdmin at https://phpmyadmin.$DOMAIN_NAME with username '$USERNAME' and the same password.${NC}"
  fi
  echo "User has the following quotas:"
  echo "- Home directory: 50MB"
  echo "- Web directory: 50MB"
  if rpm -q MariaDB-server &>/dev/null && systemctl is-active --quiet mariadb; then
      echo "- Database: 100MB"
  fi
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Remove user function
remove_user() {
  echo "Removing a user ... "
  echo "Users list : "
  pdbedit -L
  read -p "Enter a user to delete: " USERNAME

  # Refuse deletion of 'root'
  if [[ "$USERNAME" == "root" ]]; then
    echo "Erreur : la suppression de l'utilisateur 'root' est interdite."
    echo "Appuyez sur une touche pour continuer..."
    read -n 1 -s
    return
  fi

  userdel -r $USERNAME  # -r flag removes home directory too
  smbpasswd -x $USERNAME
  rm -rf /srv/web/$USERNAME

  # Check if MariaDB is installed and running before dropping database and user
  if rpm -q MariaDB-server &>/dev/null && systemctl is-active --quiet mariadb; then
      # Drop the user's database
      mysql -u root -prootpassword -e "DROP DATABASE IF EXISTS ${USERNAME}_db;"
      # Drop the MariaDB user
      mysql -u root -prootpassword -e "DROP USER IF EXISTS '$USERNAME'@'localhost';"
      # Flush privileges to apply changes
      mysql -u root -prootpassword -e "FLUSH PRIVILEGES;"
      echo "Database and database user for $USERNAME removed."
  else
      echo "WARNING: MariaDB is not running. User database not removed."
  fi

  # Remove Apache virtual host configuration
  rm -f /etc/httpd/conf.d/001-$USERNAME.conf

  # Remove DNS entry if available
  if [ -f "/var/named/forward.$DOMAIN_NAME" ]; then
      # Check if entry exists
      if grep -q "^$USERNAME" "/var/named/forward.$DOMAIN_NAME"; then
          # Remove the user subdomain from DNS
          sed -i "/^$USERNAME/d" "/var/named/forward.$DOMAIN_NAME"
          # Increment the serial number in the SOA record
          serial=$(grep "Serial" /var/named/forward.$DOMAIN_NAME | awk '{print $1}')
          new_serial=$((serial + 1))
          sed -i "s/$serial ; Serial/$new_serial ; Serial/" "/var/named/forward.$DOMAIN_NAME"
          # Reload named service
          systemctl reload named
          echo "DNS entry for $USERNAME removed successfully."
      fi
  fi

  # Remove SMB share configuration
  if [ -f "/etc/samba/smb.conf" ]; then
      # Remove the user share section from smb.conf
      sed -i "/\[$USERNAME\]/,/read only = no/d" /etc/samba/smb.conf
      systemctl restart smb || echo "Failed to restart smb service"
  fi

  # Restart Apache
  systemctl restart httpd

  echo -e "${GREEN}User $USERNAME and their data have been completely removed.${NC}"
  echo "Press any key to continue..."
  read -n 1 -s key
}
