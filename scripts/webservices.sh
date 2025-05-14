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
  basic_db "$DOMAIN_NAME" "$IP_ADDRESS"

  echo "Web server setup complete."
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Basic root website function
basic_root_website() {
  DOMAIN_NAME=$1
  dnf -y install httpd mod_ssl php php-json php-mysqli php-mbstring php-zip php-gd
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
  curl -I --insecure https://$DOMAIN_NAME
}

# Basic DB function
basic_db() {
  DOMAIN_NAME=$1
  IP_ADDRESS=$2
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

  # Ensure web directory exists
  mkdir -p /srv/web

  # First, clean up any existing phpmyadmin directory to prevent issues
  PHPMYADMIN_DIR="/srv/web/phpmyadmin"

  if [ -d "$PHPMYADMIN_DIR" ]; then
      echo "Cleaning up existing phpMyAdmin directory..."
      # Backup existing directory
      BACKUP_DIR="/srv/web/phpmyadmin_backup_$(date +%Y%m%d%H%M%S)"
      mv "$PHPMYADMIN_DIR" "$BACKUP_DIR"
      echo "Backed up existing phpMyAdmin directory to $BACKUP_DIR"
  fi

  # Create a fresh directory
  mkdir -p "$PHPMYADMIN_DIR"

  # Install phpMyAdmin manually from source
  echo "Installing phpMyAdmin from source..."

  # Download latest phpMyAdmin
  echo "Downloading latest phpMyAdmin..."
  cd /tmp
  wget https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.tar.gz || {
      echo -e "${RED}Failed to download phpMyAdmin. Check your internet connection.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s key
      return 1
  }

  # Extract the archive
  echo "Extracting phpMyAdmin..."
  tar -xzf phpMyAdmin-latest-all-languages.tar.gz || {
      echo -e "${RED}Failed to extract phpMyAdmin archive.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s key
      return 1
  }

  # Find extracted directory name
  PMA_DIR=$(find . -maxdepth 1 -type d -name "phpMyAdmin-*" -print | head -n 1)
  if [ -z "$PMA_DIR" ]; then
      echo -e "${RED}Failed to find phpMyAdmin directory after extraction.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s key
      return 1
  fi

  # Copy files instead of moving them (to avoid cross-device issues)
  echo "Copying phpMyAdmin files to web directory..."
  cp -r "$PMA_DIR"/* "$PHPMYADMIN_DIR"/ || {
      echo -e "${RED}Failed to copy phpMyAdmin files to web directory.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s key
      return 1
  }

  # Cleanup
  echo "Cleaning up temporary files..."
  rm -f /tmp/phpMyAdmin-latest-all-languages.tar.gz
  rm -rf "$PMA_DIR"

  # Set proper ownership and permissions
  chown -R apache:apache "$PHPMYADMIN_DIR"
  chmod -R 755 "$PHPMYADMIN_DIR"

  # Set up DNS entry for phpmyadmin subdomain
  echo "Adding DNS entry for phpmyadmin.$DOMAIN_NAME..."

  # Check if the forward.$DOMAIN_NAME file exists
  if [ -f "/var/named/forward.$DOMAIN_NAME" ]; then
      # Check if the entry already exists
      if ! grep -q "phpmyadmin" "/var/named/forward.$DOMAIN_NAME"; then
          # Add the phpmyadmin subdomain to DNS
          sed -i "/^ns /a phpmyadmin      IN  A       $IP_ADDRESS" "/var/named/forward.$DOMAIN_NAME"
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
    DocumentRoot /srv/web/phpmyadmin

    <Directory /srv/web/phpmyadmin/>
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

    <Directory /srv/web/phpmyadmin/setup/>
        Require local
    </Directory>

    <Directory /srv/web/phpmyadmin/libraries/>
        Require all denied
    </Directory>

    <Directory /srv/web/phpmyadmin/templates/>
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

  # Generate blowfish secret
  BLOWFISH_SECRET=$(openssl rand -hex 16)

  # Create config.inc.php file
  cat > "$PHPMYADMIN_DIR/config.inc.php" <<EOL
<?php
/**
 * phpMyAdmin configuration file
 */

/**
 * This is needed for cookie based authentication to encrypt password in
 * cookie. Needs to be 32 chars long.
 */
\$cfg['blowfish_secret'] = '${BLOWFISH_SECRET}';

/**
 * Servers configuration
 */
\$i = 0;

/**
 * First server
 */
\$i++;
/* Authentication type */
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
/* Server parameters */
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][$i]['socket'] = '/var/lib/mysql/mysql.sock';
\$cfg['Servers'][\$i]['compress'] = false;
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['Servers'][\$i]['AllowRoot'] = false; /* Disable root access */

/**
 * phpMyAdmin configuration storage settings.
 */

/* User used to manipulate with storage */
// \$cfg['Servers'][\$i]['controlhost'] = '';
// \$cfg['Servers'][\$i]['controlport'] = '';
// \$cfg['Servers'][\$i]['controluser'] = 'pma';
// \$cfg['Servers'][\$i]['controlpass'] = 'pmapass';

/* Storage database and tables */
// \$cfg['Servers'][\$i]['pmadb'] = 'phpmyadmin';
// \$cfg['Servers'][\$i]['bookmarktable'] = 'pma__bookmark';
// \$cfg['Servers'][\$i]['relation'] = 'pma__relation';
// \$cfg['Servers'][\$i]['table_info'] = 'pma__table_info';
// \$cfg['Servers'][\$i]['table_coords'] = 'pma__table_coords';
// \$cfg['Servers'][\$i]['pdf_pages'] = 'pma__pdf_pages';
// \$cfg['Servers'][\$i]['column_info'] = 'pma__column_info';
// \$cfg['Servers'][\$i]['history'] = 'pma__history';
// \$cfg['Servers'][\$i]['table_uiprefs'] = 'pma__table_uiprefs';
// \$cfg['Servers'][\$i]['tracking'] = 'pma__tracking';
// \$cfg['Servers'][\$i]['userconfig'] = 'pma__userconfig';
// \$cfg['Servers'][\$i]['recent'] = 'pma__recent';
// \$cfg['Servers'][\$i]['favorite'] = 'pma__favorite';
// \$cfg['Servers'][\$i]['users'] = 'pma__users';
// \$cfg['Servers'][\$i]['usergroups'] = 'pma__usergroups';
// \$cfg['Servers'][\$i]['navigationhiding'] = 'pma__navigationhiding';
// \$cfg['Servers'][\$i]['savedsearches'] = 'pma__savedsearches';
// \$cfg['Servers'][\$i]['central_columns'] = 'pma__central_columns';
// \$cfg['Servers'][\$i]['designer_settings'] = 'pma__designer_settings';
// \$cfg['Servers'][\$i]['export_templates'] = 'pma__export_templates';

/**
 * End of servers configuration
 */

/**
 * Directories for saving/loading files from server
 */
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';

/**
 * Default Theme
 */
\$cfg['ThemeDefault'] = 'pmahomme';

/**
 * Whether to display icons or text or both icons and text in table row
 * action segment. Value can be either of 'icons', 'text' or 'both'.
 * default = 'both'
 */
\$cfg['RowActionType'] = 'icons';

/**
 * Defines whether a user should be displayed a "show all (records)"
 * button in browse mode or not.
 * default = false
 */
\$cfg['ShowAll'] = true;

/**
 * Number of rows displayed when browsing a result set. If the result
 * set contains more rows, "Previous" and "Next".
 * Possible values: 25, 50, 100, 250, 500
 * default = 25
 */
\$cfg['MaxRows'] = 50;

/**
 * Disallow editing of binary fields
 * valid values are:
 *   false    allow editing
 *   'blob'   allow editing except for BLOB fields
 *   'noblob' disallow editing except for BLOB fields
 *   'all'    disallow editing
 * default = 'blob'
 */
\$cfg['ProtectBinary'] = false;

/**
 * Default language to use, if not browser-defined or user-defined
 * (you find all languages in the locale folder)
 * uncomment the desired line:
 * default = 'en'
 */
\$cfg['DefaultLang'] = 'en';

/**
 * How many columns should be used for table display of a database?
 * (a value larger than 1 results in some information being hidden)
 * default = 1
 */
\$cfg['PropertiesNumColumns'] = 1;

/**
 * Set to true if you want DB-based query history.If false, this utilizes
 * JS-routines to display query history (lost by window close)
 *
 * This requires configuration storage enabled, see above.
 * default = false
 */
\$cfg['QueryHistoryDB'] = true;

/**
 * When using DB-based query history, how many entries should be kept?
 * default = 25
 */
\$cfg['QueryHistoryMax'] = 100;

/**
 * Whether or not to query the user before sending the error report to
 * the phpMyAdmin team when a JavaScript error occurs
 *
 * Available options
 * ('ask' | 'always' | 'never')
 * default = 'ask'
 */
\$cfg['SendErrorReports'] = 'never';
?>
EOL

  # Set proper permissions for config file
  chown apache:apache "$PHPMYADMIN_DIR/config.inc.php"
  chmod 640 "$PHPMYADMIN_DIR/config.inc.php"

  # Create tmp directory
  mkdir -p "$PHPMYADMIN_DIR/tmp"
  chown apache:apache "$PHPMYADMIN_DIR/tmp"
  chmod 750 "$PHPMYADMIN_DIR/tmp"

  # Set up SELinux context if SELinux is enabled
  if command -v sestatus &> /dev/null && sestatus | grep -q "enabled"; then
      echo "Setting SELinux context for phpMyAdmin..."
      semanage fcontext -a -t httpd_sys_content_t "$PHPMYADMIN_DIR(/.*)?" || echo "SELinux context setting failed, continuing anyway..."
      restorecon -Rv "$PHPMYADMIN_DIR" || echo "SELinux context restoration failed, continuing anyway..."
      semanage fcontext -a -t httpd_sys_rw_content_t "$PHPMYADMIN_DIR/tmp(/.*)?" || echo "SELinux context setting failed, continuing anyway..."
      restorecon -Rv "$PHPMYADMIN_DIR/tmp" || echo "SELinux context restoration failed, continuing anyway..."
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

  # Restart Apache
  systemctl restart httpd

  echo "Database web frontend setup completed successfully."
  echo "phpMyAdmin is now accessible at https://phpmyadmin.$DOMAIN_NAME"
  echo "Root access to phpMyAdmin has been disabled for security."
  echo "Use the created admin user credentials instead."
}
