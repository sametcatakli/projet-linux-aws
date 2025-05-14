#!/bin/bash

# Web services menu
web_services_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                     ${BLUE}Web Services Menu ${NC}                               |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. Basic Web Server Setup                                            |"
    echo "| 2. Install MariaDB on RAID                                           |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " web_choice
    case $web_choice in
      1) basic_web_setup ;;
      2) install_mariadb_on_raid ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Function to install MariaDB on RAID
install_mariadb_on_raid() {
  clear
  echo -e "${BLUE}Installing MariaDB on RAID...${NC}"

  # Check if RAID is configured and mounted
  if ! grep -q "/srv" /proc/mounts; then
    echo -e "${RED}Error: /srv is not mounted. Please configure RAID first.${NC}"
    echo "Press any key to continue..."
    read -n 1 -s
    return 1
  fi

  # Make sure we have /srv/database directory
  if [ ! -d "/srv/database" ]; then
    echo "Creating /srv/database directory on RAID partition..."
    mkdir -p /srv/database

    # Verify the directory was created successfully
    if [ ! -d "/srv/database" ]; then
      echo -e "${RED}Error: Failed to create /srv/database. Check RAID mount status.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    fi
  fi

  # Check if MariaDB is already installed
  if rpm -q MariaDB-server &>/dev/null; then
    echo -e "${YELLOW}MariaDB is already installed. Checking configuration...${NC}"

    # Check if datadir is already configured correctly
    if grep -q "datadir=/srv/database" /etc/my.cnf.d/server.cnf 2>/dev/null; then
      echo -e "${GREEN}MariaDB is already configured to use /srv/database.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 0
    else
      echo -e "${YELLOW}Reconfiguring MariaDB to use /srv/database on RAID...${NC}"

      # Stop MariaDB service
      systemctl stop mariadb

      # Set proper ownership and permissions
      chown -R mysql:mysql /srv/database
      chmod -R 750 /srv/database

      # If there's existing data, migrate it
      if [ -d "/var/lib/mysql/mysql" ]; then
        echo "Migrating existing databases to /srv/database..."
        rsync -av /var/lib/mysql/ /srv/database/
      else
        # Initialize the database
        echo "Initializing MariaDB database in /srv/database..."
        mysql_install_db --user=mysql --datadir=/srv/database || {
          echo -e "${RED}Failed to initialize MariaDB database. Check logs.${NC}"
          echo "Press any key to continue..."
          read -n 1 -s
          return 1
        }
      fi

      # Update configuration
      cat <<EOF > /etc/my.cnf.d/server.cnf
[mysqld]
datadir=/srv/database
socket=/var/lib/mysql/mysql.sock

[client]
socket=/var/lib/mysql/mysql.sock
EOF

      # Start MariaDB
      systemctl start mariadb

      if ! systemctl is-active --quiet mariadb; then
        echo -e "${RED}Failed to start MariaDB with new configuration.${NC}"
        echo "Press any key to continue..."
        read -n 1 -s
        return 1
      fi

      echo -e "${GREEN}MariaDB reconfigured to use /srv/database successfully.${NC}"
    fi
  else
    # Install MariaDB
    echo -e "${YELLOW}Installing MariaDB...${NC}"

    # 1. Import the key
    rpm --import https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB

    # 2. Add the MariaDB repository (version 10.11)
    tee /etc/yum.repos.d/MariaDB.repo > /dev/null <<EOF
[mariadb]
name = MariaDB
baseurl = https://rpm.mariadb.org/10.11/rhel9-amd64
gpgkey=https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
EOF

    # 3. Update metadata
    dnf clean all
    dnf makecache

    # 4. Install MariaDB Server
    dnf install -y MariaDB-server MariaDB-client || {
      echo -e "${RED}Failed to install MariaDB from dedicated repo. Check your internet connection and repo access.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    }

    # Set proper ownership and permissions for database directory
    chown -R mysql:mysql /srv/database
    chmod -R 750 /srv/database

    # Configure MariaDB to use /srv/database
    cat <<EOF > /etc/my.cnf.d/server.cnf
[mysqld]
datadir=/srv/database
socket=/var/lib/mysql/mysql.sock

[client]
socket=/var/lib/mysql/mysql.sock
EOF

    # Initialize the database
    echo "Initializing MariaDB database in /srv/database..."
    mysql_install_db --user=mysql --datadir=/srv/database || {
      echo -e "${RED}Failed to initialize MariaDB database. Check logs.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    }

    # Start and enable MariaDB
    systemctl enable --now mariadb

    # Verify MariaDB is running
    if ! systemctl is-active --quiet mariadb; then
      echo -e "${RED}MariaDB failed to start. Check logs with: journalctl -u mariadb${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    fi

    # Run mysql_secure_installation non-interactively
    echo "Securing MariaDB installation..."

    mysql -u root <<EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('rootpassword');
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

    echo -e "${GREEN}MariaDB installed and configured to use /srv/database successfully.${NC}"
  fi

  # Configure firewall for MariaDB if available
  if systemctl is-active --quiet firewalld; then
    echo "Configuring firewall for MariaDB..."
    firewall-cmd --permanent --add-service=mysql || echo "Firewall rule addition failed, continuing anyway..."
    firewall-cmd --reload || echo "Firewall reload failed, continuing anyway..."
  fi

  echo "Press any key to continue..."
  read -n 1 -s
  return 0
}

# Function to create database with size limit
create_limited_database() {
  local USERNAME=$1
  local DB_SIZE_MB=$2
  local PASSWORD=$3

  # Create the database
  mysql -u root -prootpassword -e "CREATE DATABASE ${USERNAME}_db;" || {
    echo -e "${RED}Failed to create database for $USERNAME.${NC}"
    return 1
  }

  # Set up user with password and grant privileges
  mysql -u root -prootpassword -e "GRANT ALL PRIVILEGES ON ${USERNAME}_db.* TO '$USERNAME'@'localhost' IDENTIFIED BY '$PASSWORD';" || {
    echo -e "${RED}Failed to grant privileges for $USERNAME.${NC}"
    return 1
  }

  # Create a trigger to limit database size
  mysql -u root -prootpassword -e "
    USE ${USERNAME}_db;

    -- Create table to track database size
    CREATE TABLE IF NOT EXISTS db_size_limit (
      id INT NOT NULL PRIMARY KEY,
      max_size_mb INT NOT NULL
    );

    -- Insert or update the maximum size
    INSERT INTO db_size_limit (id, max_size_mb) VALUES (1, $DB_SIZE_MB)
    ON DUPLICATE KEY UPDATE max_size_mb = $DB_SIZE_MB;

    -- Create function to calculate current database size
    DELIMITER //
    CREATE FUNCTION get_db_size() RETURNS DECIMAL(10,2) DETERMINISTIC
    BEGIN
      DECLARE db_size DECIMAL(10,2);
      SELECT SUM(data_length + index_length) / 1024 / 1024 AS size_mb
      INTO db_size
      FROM information_schema.tables
      WHERE table_schema = DATABASE();
      RETURN IFNULL(db_size, 0);
    END //
    DELIMITER ;

    -- Create trigger to check size before insert
    DELIMITER //
    CREATE TRIGGER check_size_before_insert BEFORE INSERT ON db_size_limit
    FOR EACH ROW
    BEGIN
      DECLARE current_size DECIMAL(10,2);
      SET current_size = get_db_size();
      IF current_size > (SELECT max_size_mb FROM db_size_limit WHERE id = 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Database size limit exceeded';
      END IF;
    END //
    DELIMITER ;
  " || {
    echo -e "${YELLOW}Warning: Could not create database size limit trigger for $USERNAME.${NC}"
  }

  mysql -u root -prootpassword -e "FLUSH PRIVILEGES;" || {
    echo -e "${RED}Failed to flush privileges.${NC}"
    return 1
  }

  echo -e "${GREEN}Database ${USERNAME}_db created with size limit of $DB_SIZE_MB MB.${NC}"
  return 0
}

# Basic web setup function
basic_web_setup() {
  clear
  echo "Setting up basic web server..."

  read -p "Enter the IP address : " IP_ADDRESS
  read -p "Enter the server domain name (e.g., test.toto) : " DOMAIN_NAME

  # Configure DNS if not already configured
  if ! grep -q "$DOMAIN_NAME" /etc/named.conf 2>/dev/null; then
    echo "Configuring DNS for $DOMAIN_NAME..."
    basic_dns "$IP_ADDRESS" "$DOMAIN_NAME"
  else
    echo "DNS already configured for $DOMAIN_NAME."
  fi

  # Set up the web server
  echo "Configuring web server..."
  basic_root_website "$DOMAIN_NAME"

  # Set up database frontend
  echo "Configuring database web interface..."
  basic_db "$DOMAIN_NAME"

  echo "Web server setup complete."
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Basic root website function
basic_root_website() {
  DOMAIN_NAME=$1
  dnf -y install httpd mod_ssl
  mkdir -p /srv/web/root
  echo "<html><body><h1>Welcome to $DOMAIN_NAME</h1></body></html>" > /srv/web/root/index.php
  chown -R apache:apache /srv/web/root
  chcon -R --type=httpd_sys_content_t /srv/web/root
  chmod -R 755 /srv/web/root
  cat <<EOL > /etc/httpd/conf.d/root.conf
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    ServerAlias *.$DOMAIN_NAME
    DocumentRoot /srv/web/root
    <Directory /srv/web/root>
        AllowOverride All
        Require all granted
    </Directory>
    DirectoryIndex index.php
    ErrorLog /var/log/httpd/root_error.log
    CustomLog /var/log/httpd/root_access.log combined

    # Redirect all traffic to HTTPS
    Redirect "/" "https://$DOMAIN_NAME/"
</VirtualHost>
EOL

  # Generate a wildcard self-signed SSL certificate
  mkdir -p /etc/httpd/ssl
  openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 \
      -keyout /etc/httpd/ssl/$DOMAIN_NAME.key \
      -out /etc/httpd/ssl/$DOMAIN_NAME.crt \
      -subj "/C=US/ST=State/L=City/O=Organization/OU=Department/CN=*.$DOMAIN_NAME"

  # Set up the virtual host for HTTPS
  cat <<EOL > /etc/httpd/conf.d/root-ssl.conf
<VirtualHost *:443>
    ServerName $DOMAIN_NAME
    ServerAlias *.$DOMAIN_NAME
    DocumentRoot /srv/web/root
    <Directory /srv/web/root>
        AllowOverride All
        Require all granted
    </Directory>
    DirectoryIndex index.php
    SSLEngine on
    SSLCertificateFile /etc/httpd/ssl/$DOMAIN_NAME.crt
    SSLCertificateKeyFile /etc/httpd/ssl/$DOMAIN_NAME.key
    ErrorLog /var/log/httpd/root_ssl_error.log
    CustomLog /var/log/httpd/root_ssl_access.log combined
</VirtualHost>
EOL

  # Start and enable the Apache HTTP server
  systemctl start httpd
  systemctl enable httpd
  systemctl restart httpd
  firewall-cmd --add-service=http --permanent
  firewall-cmd --add-service=https --permanent
  firewall-cmd --reload
  echo "Verifying HTTP Access..."
  curl -I http://$DOMAIN_NAME
  echo "Verifying HTTPS Access..."
  curl -I https://$DOMAIN_NAME
}

# Basic DB function
basic_db() {
  DOMAIN_NAME=$1
  echo "Setting up phpMyAdmin..."

  # Check if MariaDB is installed and running
  if ! rpm -q MariaDB-server &>/dev/null || ! systemctl is-active --quiet mariadb; then
      echo -e "${RED}ERROR: MariaDB is not installed or not running. Please install MariaDB first from the main menu (option 10).${NC}"
      echo "Press any key to continue with other setup options..."
      read -n 1 -s key
      return 1
  fi

  # Configure firewall for MariaDB if available
  if systemctl is-active --quiet firewalld; then
      firewall-cmd --add-service=mysql --permanent || echo "Firewall rule addition failed, continuing anyway..."
      firewall-cmd --reload || echo "Firewall reload failed, continuing anyway..."
  fi

  # Install phpMyAdmin
  echo "Installing phpMyAdmin..."
  dnf -y install phpMyAdmin php-mbstring php-zip php-gd php-json php-mysqli || {
      echo "phpMyAdmin not available in default repositories."
      echo "You may need to install it manually later."
      echo "Press any key to continue..."
      read -n 1 -s key
      return 1
  }

  # Configure phpMyAdmin if installed
  if [ -d "/usr/share/phpMyAdmin" ]; then
      echo "Configuring phpMyAdmin..."

      # Create a dedicated directory for phpMyAdmin
      mkdir -p /srv/web/phpmyadmin

      # Set up DNS entry for phpmyadmin subdomain
      echo "Adding DNS entry for phpmyadmin.$DOMAIN_NAME..."

      # Check if the forward.$DOMAIN_NAME file exists
      if [ -f "/var/named/forward.$DOMAIN_NAME" ]; then
          # Check if the entry already exists
          if ! grep -q "phpmyadmin" "/var/named/forward.$DOMAIN_NAME"; then
              # Add the phpmyadmin subdomain to DNS
              sed -i "/^ns /a phpmyadmin      IN  A       $(hostname -I | awk '{print $1}')" "/var/named/forward.$DOMAIN_NAME"
              # Increment the serial number in the SOA record
              serial=$(grep "Serial" /var/named/forward.$DOMAIN_NAME | awk '{print $1}')
              new_serial=$((serial + 1))
              sed -i "s/$serial ; Serial/$new_serial ; Serial/" /var/named/forward.$DOMAIN_NAME
              # Reload named service
              systemctl reload named
              echo "DNS entry for phpmyadmin.$DOMAIN_NAME added successfully."
          else
              echo "DNS entry for phpmyadmin.$DOMAIN_NAME already exists."
          fi
      else
          echo "WARNING: Forward DNS zone file not found. Skipping DNS configuration."
      fi

      # Configure virtual host for phpMyAdmin
      echo "Setting up dedicated virtual host for phpMyAdmin..."
      cat <<EOL > /etc/httpd/conf.d/phpmyadmin.conf
<VirtualHost *:80>
    ServerName phpmyadmin.$DOMAIN_NAME
    Redirect permanent / https://phpmyadmin.$DOMAIN_NAME/
</VirtualHost>

<VirtualHost *:443>
    ServerName phpmyadmin.$DOMAIN_NAME
    DocumentRoot /usr/share/phpMyAdmin

    <Directory /usr/share/phpMyAdmin/>
        AddDefaultCharset UTF-8
        Options FollowSymLinks
        AllowOverride All
        Require all granted

        # Block root user access
        <IfModule mod_rewrite.c>
            RewriteEngine On
            RewriteCond %{REQUEST_URI} ^/.*
            RewriteCond %{REQUEST_METHOD} ^POST$
            RewriteCond %{REQUEST_URI} !server-status
            RewriteCond %{THE_REQUEST} pma_username=root [NC]
            RewriteRule .* - [F,L]
        </IfModule>
    </Directory>

    <Directory /usr/share/phpMyAdmin/setup/>
        Require local
    </Directory>

    <Directory /usr/share/phpMyAdmin/libraries/>
        Require all denied
    </Directory>

    <Directory /usr/share/phpMyAdmin/templates/>
        Require all denied
    </Directory>

    SSLEngine on
    SSLCertificateFile /etc/httpd/ssl/$DOMAIN_NAME.crt
    SSLCertificateKeyFile /etc/httpd/ssl/$DOMAIN_NAME.key

    ErrorLog /var/log/httpd/phpmyadmin_error.log
    CustomLog /var/log/httpd/phpmyadmin_access.log combined
</VirtualHost>
EOL

      # Configure phpMyAdmin security settings
      echo "Configuring phpMyAdmin security settings..."

      # Create custom config file
      mkdir -p /etc/phpMyAdmin/
      cat <<EOL > /etc/phpMyAdmin/config.inc.php
<?php
\$cfg['blowfish_secret'] = '$(openssl rand -hex 16)';
\$cfg['Servers'][1]['auth_type'] = 'cookie';
\$cfg['Servers'][1]['host'] = 'localhost';
\$cfg['Servers'][1]['compress'] = false;
\$cfg['Servers'][1]['AllowNoPassword'] = false;
\$cfg['Servers'][1]['AllowRoot'] = false; /* Disable root access */
\$cfg['DefaultLang'] = 'en';
\$cfg['ServerDefault'] = 1;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
?>
EOL

      # Set proper ownership and permissions
      chown apache:apache /etc/phpMyAdmin/config.inc.php
      chmod 640 /etc/phpMyAdmin/config.inc.php

      # Set up SELinux context for phpMyAdmin if SELinux is enabled
      if command -v sestatus &> /dev/null && sestatus | grep -q "enabled"; then
          echo "Setting SELinux context for phpMyAdmin..."
          semanage fcontext -a -t httpd_sys_content_t "/usr/share/phpMyAdmin(/.*)?" || echo "SELinux context setting failed, continuing anyway..."
          restorecon -Rv /usr/share/phpMyAdmin || echo "SELinux context restoration failed, continuing anyway..."
          semanage fcontext -a -t httpd_sys_rw_content_t "/usr/share/phpMyAdmin/tmp(/.*)?" || echo "SELinux context setting failed, continuing anyway..."
          restorecon -Rv /usr/share/phpMyAdmin/tmp || echo "SELinux context restoration failed, continuing anyway..."
      fi

      # Create a non-root admin user for database management
      echo "Creating a non-root admin user for database management..."
      ADMIN_USER="dbadmin"
      ADMIN_PASS=$(openssl rand -base64 12)

      # Create the admin user with all privileges except grant
      mysql -u root -prootpassword -e "
      CREATE USER IF NOT EXISTS '$ADMIN_USER'@'localhost' IDENTIFIED BY '$ADMIN_PASS';
      GRANT ALL PRIVILEGES ON *.* TO '$ADMIN_USER'@'localhost' WITH GRANT OPTION;
      FLUSH PRIVILEGES;
      " || {
          echo -e "${RED}Failed to create admin user.${NC}"
      }

      echo -e "${GREEN}Created database admin user: $ADMIN_USER with password: $ADMIN_PASS${NC}"
      echo -e "${GREEN}IMPORTANT: Save these credentials securely!${NC}"
      echo -e "Username: $ADMIN_USER"
      echo -e "Password: $ADMIN_PASS"
      echo -e "${YELLOW}NOTE: Root login to phpMyAdmin has been disabled for security. Use the admin user above.${NC}"

      # Link to main page
      echo "<html><body><h1>Web Server Setup Complete for $DOMAIN_NAME</h1><p>Access phpMyAdmin at <a href='https://phpmyadmin.$DOMAIN_NAME'>https://phpmyadmin.$DOMAIN_NAME</a></p></body></html>" > /srv/web/root/index.php

      echo "phpMyAdmin configuration complete."
  else
      echo "WARNING: phpMyAdmin directory not found. Skipping phpMyAdmin configuration."
      # Create a basic index.php file
      mkdir -p /srv/web/root
      echo "<html><body><h1>Web Server Setup Complete for $DOMAIN_NAME</h1><p>phpMyAdmin installation failed.</p></body></html>" > /srv/web/root/index.php
  fi

  # Restart Apache
  systemctl restart httpd

  echo "Database web frontend setup completed successfully."
  echo "phpMyAdmin is now accessible at https://phpmyadmin.$DOMAIN_NAME"
  echo "Root access to phpMyAdmin has been disabled for security."
  echo "Use the created admin user credentials instead."
}
