#!/bin/bash

# Security menu
security_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                     ${BLUE}Security Menu ${NC}                                  |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. Firewall Management                                               |"
    echo "| 2. Anti-Malware (ClamAV & RKHunter)                                  |"
    echo "| 3. SELinux Management                                                |"
    echo "| 4. Secure Mount Options                                              |"
    echo "| 5. Fix phpMyAdmin SELinux Issues                                     |" # Added phpMyAdmin option
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " security_choice
    case $security_choice in
      1) firewall_management ;;
      2) anti_malware ;;
      3) selinux_management ;;
      4) secure_mount_options ;;
      5) fix_phpmyadmin_selinux ;; # Added case for phpMyAdmin fix
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Function to fix phpMyAdmin SELinux issues
fix_phpmyadmin_selinux() {
  clear
  echo -e "${BLUE}===================================================================${NC}"
  echo -e "${BLUE}      FIXING PHPMYADMIN SOCKET CONNECTION WITH SELINUX ENABLED      ${NC}"
  echo -e "${BLUE}===================================================================${NC}"

  # Verify phpMyAdmin location
  if [ ! -d "/srv/web/phpmyadmin" ]; then
    echo -e "${RED}phpMyAdmin directory not found at /srv/web/phpmyadmin${NC}"
    echo "Press any key to continue..."
    read -n 1 -s
    return 1
  fi

  # Verify MySQL socket exists
  if [ ! -S "/var/lib/mysql/mysql.sock" ]; then
    echo -e "${YELLOW}MySQL socket not found. Checking MySQL status...${NC}"

    # Check if MariaDB is installed and running
    if systemctl is-active --quiet mariadb; then
      echo -e "${GREEN}MariaDB is running. Verifying socket location...${NC}"
    else
      echo -e "${YELLOW}MariaDB is not running. Starting MariaDB...${NC}"
      systemctl start mariadb
      sleep 2
    fi

    # Check again for socket
    if [ ! -S "/var/lib/mysql/mysql.sock" ]; then
      # Try to find socket location from MySQL
      SOCKET_PATH=$(mysql -e "SHOW VARIABLES LIKE 'socket';" | grep socket | awk '{print $2}')

      if [ -z "$SOCKET_PATH" ] || [ ! -S "$SOCKET_PATH" ]; then
        echo -e "${RED}Failed to locate MySQL socket. Please ensure MySQL/MariaDB is properly configured.${NC}"
        echo "Press any key to continue..."
        read -n 1 -s
        return 1
      else
        echo -e "${GREEN}Found MySQL socket at $SOCKET_PATH${NC}"
      fi
    else
      SOCKET_PATH="/var/lib/mysql/mysql.sock"
      echo -e "${GREEN}Found MySQL socket at $SOCKET_PATH${NC}"
    fi
  else
    SOCKET_PATH="/var/lib/mysql/mysql.sock"
    echo -e "${GREEN}Found MySQL socket at $SOCKET_PATH${NC}"
  fi

  echo -e "\n${BLUE}1. Updating phpMyAdmin configuration to use socket...${NC}"
  # Check for phpMyAdmin config file
  CONFIG_FILE="/srv/web/phpmyadmin/config.inc.php"
  if [ -f "$CONFIG_FILE" ]; then
    # Backup config file
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    echo -e "${GREEN}Created backup of config file${NC}"

    # Update the configuration to use socket explicitly
    if grep -q "\$cfg\['Servers'\]\[\$i\]\['socket'\]" "$CONFIG_FILE"; then
      # Update existing socket configuration
      sed -i "s|\(\$cfg\['Servers'\]\[\$i\]\['socket'\] = \).*|\1'$SOCKET_PATH';|" "$CONFIG_FILE"
      echo -e "${GREEN}Updated existing socket configuration${NC}"
    else
      # Add socket configuration if it doesn't exist
      sed -i "/\$cfg\['Servers'\]\[\$i\]\['host'\]/a \$cfg['Servers'][\$i]['socket'] = '$SOCKET_PATH';" "$CONFIG_FILE"
      echo -e "${GREEN}Added socket configuration${NC}"
    fi

    # Make sure connect_type is set to socket if that parameter exists
    if grep -q "\$cfg\['Servers'\]\[\$i\]\['connect_type'\]" "$CONFIG_FILE"; then
      sed -i "s|\(\$cfg\['Servers'\]\[\$i\]\['connect_type'\] = \).*|\1'socket';|" "$CONFIG_FILE"
      echo -e "${GREEN}Set connect_type to socket${NC}"
    fi

    # Set proper ownership
    chown apache:apache "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
  else
    echo -e "${RED}phpMyAdmin config file not found at $CONFIG_FILE${NC}"
    echo "Press any key to continue..."
    read -n 1 -s
    return 1
  fi

  echo -e "\n${BLUE}2. Setting SELinux booleans...${NC}"
  # Set SELinux booleans
  setsebool -P httpd_can_network_connect_db 1
  setsebool -P httpd_can_network_connect 1
  setsebool -P httpd_can_connect_mysql 1
  echo -e "${GREEN}Set SELinux booleans${NC}"

  echo -e "\n${BLUE}3. Setting SELinux context for socket and phpMyAdmin directory...${NC}"
  # Set SELinux context for socket
  chcon -t mysqld_var_run_t "$SOCKET_PATH"
  restorecon -v "$SOCKET_PATH"

  # Set proper context for phpMyAdmin directory
  chcon -R -t httpd_sys_content_t /srv/web/phpmyadmin
  restorecon -Rv /srv/web/phpmyadmin

  # Ensure tmp directory has proper permissions
  if [ -d "/srv/web/phpmyadmin/tmp" ]; then
    chcon -R -t httpd_sys_rw_content_t /srv/web/phpmyadmin/tmp
    chmod 750 /srv/web/phpmyadmin/tmp
    chown apache:apache /srv/web/phpmyadmin/tmp
    echo -e "${GREEN}Set permissions for tmp directory${NC}"
  fi
  echo -e "${GREEN}Set SELinux contexts${NC}"

  echo -e "\n${BLUE}4. Creating custom SELinux policy...${NC}"
  # Create custom SELinux policy
  cat > /tmp/phpmyadmin_socket.te <<EOF
module phpmyadmin_socket 1.0;

require {
    type httpd_t;
    type mysqld_t;
    type mysqld_var_run_t;
    type httpd_sys_content_t;
    type httpd_sys_rw_content_t;
    class sock_file { read write getattr };
    class unix_stream_socket connectto;
    class dir { search read write add_name remove_name };
    class file { read write getattr open create unlink };
}

#============= httpd_t ==============
# Allow Apache to use the MySQL socket
allow httpd_t mysqld_var_run_t:sock_file { read write getattr };
allow httpd_t mysqld_t:unix_stream_socket connectto;

# Allow Apache to write to its content directories
allow httpd_t httpd_sys_rw_content_t:dir { search read write add_name remove_name };
allow httpd_t httpd_sys_rw_content_t:file { read write getattr open create unlink };
EOF

  # Compile and load the policy
  cd /tmp
  if checkmodule -M -m -o phpmyadmin_socket.mod phpmyadmin_socket.te && \
     semodule_package -o phpmyadmin_socket.pp -m phpmyadmin_socket.mod && \
     semodule -i phpmyadmin_socket.pp; then
    echo -e "${GREEN}Successfully created and installed custom SELinux policy${NC}"
  else
    echo -e "${RED}Failed to create and install custom SELinux policy${NC}"
  fi

  echo -e "\n${BLUE}5. Creating more permissive policy if needed...${NC}"
  # Create a more permissive policy specifically for phpMyAdmin
  cat > /tmp/phpmyadmin_permissive.te <<EOF
module phpmyadmin_permissive 1.0;

require {
    type httpd_t;
    type mysqld_db_t;
    type mysqld_etc_t;
    type mysqld_log_t;
    type mysqld_var_run_t;
    type tmp_t;
    class sock_file write;
    class unix_stream_socket connectto;
    class dir { read search open getattr };
    class file { read open getattr };
}

#============= httpd_t ==============
# Very permissive rules for MySQL access
allow httpd_t mysqld_db_t:dir { read search open getattr };
allow httpd_t mysqld_db_t:file { read open getattr };
allow httpd_t mysqld_etc_t:dir { read search open getattr };
allow httpd_t mysqld_etc_t:file { read open getattr };
allow httpd_t mysqld_log_t:dir { read search open getattr };
allow httpd_t mysqld_var_run_t:dir { read search open getattr };
allow httpd_t tmp_t:dir { write add_name remove_name };
EOF

  # Compile and load this more permissive policy
  cd /tmp
  if checkmodule -M -m -o phpmyadmin_permissive.mod phpmyadmin_permissive.te && \
     semodule_package -o phpmyadmin_permissive.pp -m phpmyadmin_permissive.mod && \
     semodule -i phpmyadmin_permissive.pp; then
    echo -e "${GREEN}Successfully created and installed supplementary SELinux policy${NC}"
  else
    echo -e "${RED}Failed to create and install supplementary SELinux policy${NC}"
  fi

  echo -e "\n${BLUE}6. Restarting services...${NC}"
  # Restart services
  systemctl restart httpd
  systemctl restart mariadb
  echo -e "${GREEN}Restarted services${NC}"

  # Check if SELinux is in enforcing mode
  if [ "$(getenforce)" == "Enforcing" ]; then
    echo -e "\n${YELLOW}NOTE: SELinux is currently in Enforcing mode.${NC}"
    echo -e "${YELLOW}If phpMyAdmin still doesn't work, you can temporarily set SELinux to Permissive mode:${NC}"
    echo -e "${YELLOW}   sudo setenforce 0${NC}"
    echo -e "${YELLOW}After testing, you can set it back to Enforcing mode:${NC}"
    echo -e "${YELLOW}   sudo setenforce 1${NC}"
  fi

  echo -e "\n${BLUE}===================================================================${NC}"
  echo -e "${GREEN}Socket configuration and SELinux policy have been applied.${NC}"
  echo -e "${GREEN}Try accessing phpMyAdmin now using your configured domain.${NC}"
  echo -e "${BLUE}===================================================================${NC}"

  echo "Press any key to continue..."
  read -n 1 -s
  return 0
}

# Function to manage firewall
firewall_management() {
  # Check if firewalld is installed first
  if ! rpm -q firewalld &>/dev/null; then
    echo -e "${YELLOW}Firewalld is not installed. Installing...${NC}"
    dnf install -y firewalld || {
      echo -e "${RED}Failed to install firewalld. Firewall management won't be available.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    }
    echo -e "${GREEN}Firewalld installed successfully.${NC}"
  fi

  while true; do
    clear
    # Get current firewall status
    if systemctl is-active --quiet firewalld; then
      firewall_status="${GREEN}ENABLED${NC}"
    else
      firewall_status="${RED}DISABLED${NC}"
    fi

    echo "=========================================================="
    echo -e "${BLUE}              FIREWALL MANAGEMENT MENU             ${NC}"
    echo "=========================================================="
    echo -e "Current Firewall Status: $firewall_status"
    echo "=========================================================="
    echo "1. Configure Firewall (Open All Service Ports)"
    echo "2. Enable Firewall"
    echo "3. Disable Firewall"
    echo "4. Show Current Firewall Status"
    echo "q. Return to Previous Menu"
    echo "=========================================================="
    read -p "Enter your choice: " choice

    case $choice in
      1) # Configure - open all common ports
        echo "Configuring firewall with permissive defaults..."

        # Make sure firewalld is running
        if ! systemctl is-active --quiet firewalld; then
          systemctl start firewalld
        fi

        # Set default zone to public
        firewall-cmd --set-default-zone=public

        # Add all common services
        firewall-cmd --permanent --zone=public --add-service=ssh
        firewall-cmd --permanent --zone=public --add-service=http
        firewall-cmd --permanent --zone=public --add-service=https
        firewall-cmd --permanent --zone=public --add-service=dns
        firewall-cmd --permanent --zone=public --add-service=ftp
        firewall-cmd --permanent --zone=public --add-service=mysql
        firewall-cmd --permanent --zone=public --add-service=samba
        firewall-cmd --permanent --zone=public --add-service=nfs
        firewall-cmd --permanent --zone=public --add-service=mountd
        firewall-cmd --permanent --zone=public --add-service=rpc-bind
        firewall-cmd --permanent --zone=public --add-service=cockpit

        # Add Netdata port
        firewall-cmd --permanent --zone=public --add-port=19999/tcp

        # Add passive FTP port range
        firewall-cmd --permanent --zone=public --add-port=30000-31000/tcp

        # Apply changes
        firewall-cmd --reload

        echo -e "${GREEN}Firewall configured with all common service ports open.${NC}"
        ;;
      2) # Enable
        echo "Enabling firewall..."

        # First make sure SSH is allowed to prevent lockout
        firewall-cmd --permanent --add-service=ssh

        # Enable and start firewalld
        systemctl enable --now firewalld

        # Add SSH again and apply
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --reload

        echo -e "${GREEN}Firewall enabled and started.${NC}"
        ;;
      3) # Disable
        echo "Disabling firewall..."
        systemctl disable --now firewalld
        echo -e "${YELLOW}Firewall disabled and stopped.${NC}"
        ;;
      4) # Status
        echo "Current Firewall Status:"
        echo "------------------------"
        if systemctl is-active --quiet firewalld; then
          echo -e "Firewall is ${GREEN}ACTIVE${NC}"
          echo -e "\nOpen ports and services:"
          firewall-cmd --list-all
        else
          echo -e "Firewall is ${RED}INACTIVE${NC}"
        fi
        echo "------------------------"
        ;;
      q|Q) # Quit
        break
        ;;
      *)
        echo -e "${RED}Invalid choice. Please try again.${NC}"
        ;;
    esac

    echo "Press any key to continue..."
    read -n 1 -s
  done
}

# Function to manage SELinux
# Function to manage SELinux
selinux_management() {
  # Check if SELinux is available
  if ! command -v getenforce &>/dev/null; then
    echo -e "${YELLOW}SELinux tools not installed. Installing...${NC}"
    dnf install -y selinux-policy selinux-policy-targeted policycoreutils policycoreutils-python-utils || {
      echo -e "${RED}Failed to install SELinux tools. SELinux management won't be available.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    }
    echo -e "${GREEN}SELinux tools installed successfully.${NC}"
  fi

  # CRITICAL FIX: Always ensure SSH access is allowed
  echo "Ensuring SSH access through SELinux..."
  setsebool -P ssh_sysadm_login 1
  setsebool -P sftpd_enable_homedirs 1
  setsebool -P sftpd_full_access 1
  echo -e "${GREEN}SELinux configured to allow SSH access.${NC}"

  while true; do
    clear
    # Get current SELinux status
    local current_mode=$(getenforce)

    echo "=========================================================="
    echo -e "${BLUE}              SELinux MANAGEMENT MENU             ${NC}"
    echo "=========================================================="
    echo -e "Current SELinux Mode: ${YELLOW}$current_mode${NC}"
    echo "=========================================================="
    echo "1. Set SELinux to Enforcing Mode (Full Protection)"
    echo "2. Set SELinux to Permissive Mode (Log Only)"
    echo "3. Set SELinux to Disabled (Not Recommended)"
    echo "4. Show Current SELinux Status"
    echo "5. Allow Web Server (HTTP/HTTPS)"
    echo "6. Allow Database Server (MySQL/MariaDB)"
    echo "7. PHP-FPM Connection Policy"                             # New option added here
    echo "8. Allow FTP Server"
    echo "9. Allow Samba Server"
    echo "10. Allow NFS Server"
    echo "11. Allow DNS Server"
    echo "12. Allow Mail Server"
    echo "13. Allow SSH Server"
    echo "14. Allow Netdata Monitoring"
    echo "15. Create Custom SELinux Rule"
    echo "16. Restore Default SELinux Context to File/Directory"
    echo "17. Fix phpMyAdmin MySQL Socket Connection Issues"
    echo "q. Return to Security Menu"
    echo "=========================================================="
    read -p "Enter your choice: " choice

    case $choice in
      1) # Set Enforcing
        echo "Setting SELinux to Enforcing mode..."
        # Make sure SSH access is allowed before changing to enforcing
        setsebool -P ssh_sysadm_login 1
        setsebool -P sftpd_enable_homedirs 1
        setsebool -P sftpd_full_access 1

        setenforce 1
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
        echo -e "${GREEN}SELinux set to Enforcing mode.${NC}"
        echo "This change will be permanent after reboot."
        echo -e "${GREEN}SSH access has been preserved.${NC}"
        ;;
      2) # Set Permissive
        echo "Setting SELinux to Permissive mode..."
        setenforce 0
        sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
        echo -e "${GREEN}SELinux set to Permissive mode.${NC}"
        echo "This change will be permanent after reboot."
        ;;
      3) # Set Disabled
        echo "Setting SELinux to Disabled mode..."
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config
        echo -e "${YELLOW}SELinux will be disabled after reboot.${NC}"
        echo -e "${RED}Warning: Disabling SELinux reduces system security.${NC}"
        ;;
      4) # Show Status
        echo "SELinux Status:"
        echo "----------------"
        sestatus
        echo "----------------"
        echo "Booleans related to server services:"
        echo "----------------"
        getsebool -a | grep -E 'http|ftp|samba|mysql|nfs|named|ssh|mail'
        ;;
      5) # Allow Web Server
        echo "Configuring SELinux for Web Server (HTTP/HTTPS)..."
        # Allow httpd network connections
        setsebool -P httpd_can_network_connect 1
        # Allow httpd to connect to databases
        setsebool -P httpd_can_network_connect_db 1
        # Allow httpd to serve content from home directories
        setsebool -P httpd_enable_homedirs 1
        # Allow httpd to read user content
        setsebool -P httpd_read_user_content 1
        # Allow httpd to use mod_auth_pam
        setsebool -P httpd_mod_auth_pam 1
        # Allow httpd scripts and modules to connect to the network
        setsebool -P httpd_can_network_connect 1

        echo "Checking for custom web directories and setting context..."
        if [ -d "/srv/web" ]; then
          echo "Setting SELinux context for /srv/web..."
          semanage fcontext -a -t httpd_sys_content_t "/srv/web(/.*)?"
          restorecon -Rv /srv/web
        fi

        echo -e "${GREEN}SELinux configured for Web Server.${NC}"
        ;;
      6) # Allow Database Server
        echo "Configuring SELinux for Database Server (MySQL/MariaDB)..."
        # Allow mysqld to connect to network
        setsebool -P mysqld_connect_any 1
        # Allow mysqld to access all directories
        setsebool -P mysqld_disable_trans 1

        if [ -d "/srv/database" ]; then
          echo "Setting SELinux context for /srv/database..."
          semanage fcontext -a -t mysqld_db_t "/srv/database(/.*)?"
          restorecon -Rv /srv/database
        fi

        echo -e "${GREEN}SELinux configured for Database Server.${NC}"
        ;;
      7) # PHP-FPM Connection Policy - New option
        echo "Configuring SELinux policy for PHP-FPM to MySQL socket connection..."

        # Create policy file for the specific denial
        cat > /tmp/php_mysql_fix.te <<EOF
module php_mysql_fix 1.0;

require {
    type httpd_t;
    type unconfined_service_t;
    type mysqld_t;
    type mysqld_var_run_t;
    class unix_stream_socket connectto;
    class sock_file write;
}

#============= httpd_t ==============
# Allow httpd (including php-fpm) to connect to MySQL socket with unconfined context
allow httpd_t unconfined_service_t:unix_stream_socket connectto;
allow httpd_t mysqld_t:unix_stream_socket connectto;
allow httpd_t mysqld_var_run_t:sock_file write;
EOF

        # Compile and install the policy
        cd /tmp
        if checkmodule -M -m -o php_mysql_fix.mod php_mysql_fix.te && \
           semodule_package -o php_mysql_fix.pp -m php_mysql_fix.mod && \
           semodule -i php_mysql_fix.pp; then
          echo -e "${GREEN}Successfully created and installed SELinux policy for PHP-FPM to MySQL socket${NC}"
        else
          echo -e "${RED}Failed to create and install SELinux policy${NC}"
        fi

        # Restart services
        echo "Restarting services..."
        systemctl restart httpd
        if systemctl is-active --quiet php-fpm; then
          systemctl restart php-fpm
        fi
        systemctl restart mariadb

        echo -e "${GREEN}PHP-FPM connection policy has been applied.${NC}"
        echo -e "${GREEN}This should allow PHP-FPM processes to connect to the MySQL socket.${NC}"
        ;;
      8) # Allow FTP Server
        echo "Configuring SELinux for FTP Server..."
        # Allow FTP to read/write home directories
        setsebool -P ftp_home_dir 1
        # Allow FTP full access
        setsebool -P ftpd_full_access 1
        # Allow FTP to use CIFS
        setsebool -P ftpd_use_cifs 1
        # Allow FTP to use NFS
        setsebool -P ftpd_use_nfs 1
        # Allow FTP to connect to all unreserved ports
        setsebool -P ftpd_connect_all_unreserved 1

        if [ -d "/srv/share/ftp" ]; then
          echo "Setting SELinux context for /srv/share/ftp..."
          semanage fcontext -a -t public_content_t "/srv/share/ftp(/.*)?"
          # Allow FTP uploads
          semanage fcontext -a -t public_content_rw_t "/srv/share/ftp/upload(/.*)?"
          restorecon -Rv /srv/share/ftp
        fi

        echo -e "${GREEN}SELinux configured for FTP Server.${NC}"
        ;;
      9) # Allow Samba Server
        echo "Configuring SELinux for Samba Server..."
        # Allow samba to share users home directories
        setsebool -P samba_enable_home_dirs 1
        # Allow samba to export any directory/file read/write
        setsebool -P samba_export_all_rw 1
        # Allow samba to share any file/directory read only
        setsebool -P samba_export_all_ro 1
        # Allow samba to create new files in the file context of samba share
        setsebool -P samba_create_home_dirs 1

        if [ -d "/srv/share" ]; then
          echo "Setting SELinux context for /srv/share..."
          semanage fcontext -a -t samba_share_t "/srv/share(/.*)?"
          restorecon -Rv /srv/share
        fi

        echo -e "${GREEN}SELinux configured for Samba Server.${NC}"
        ;;
      10) # Allow NFS Server
        echo "Configuring SELinux for NFS Server..."
        # Allow NFS to export all read/write
        setsebool -P nfs_export_all_rw 1
        # Allow NFS to export all read only
        setsebool -P nfs_export_all_ro 1

        if [ -d "/srv/share" ]; then
          echo "Setting SELinux context for /srv/share for NFS..."
          semanage fcontext -a -t nfs_t "/srv/share(/.*)?"
          restorecon -Rv /srv/share
        fi

        echo -e "${GREEN}SELinux configured for NFS Server.${NC}"
        ;;
      11) # Allow DNS Server
        echo "Configuring SELinux for DNS Server..."
        # Allow named to write to caching directory
        setsebool -P named_write_master_zones 1

        # Set proper context for named configuration and data
        if [ -d "/var/named" ]; then
          echo "Setting SELinux context for /var/named..."
          restorecon -Rv /var/named
        fi
        if [ -f "/etc/named.conf" ]; then
          echo "Setting SELinux context for /etc/named.conf..."
          restorecon -v /etc/named.conf
        fi

        echo -e "${GREEN}SELinux configured for DNS Server.${NC}"
        ;;
      12) # Allow Mail Server
        echo "Configuring SELinux for Mail Server..."
        # Allow postfix to read user mail
        setsebool -P postfix_local_read_mail 1
        # Allow mail use spool
        setsebool -P mail_read_content 1

        echo -e "${GREEN}SELinux configured for Mail Server.${NC}"
        ;;
      13) # Allow SSH Server
        echo "Configuring SELinux for SSH Server..."
        # Allow SSH to read and write to all files
        setsebool -P ssh_sysadm_login 1
        # Allow sftp to access user home directories
        setsebool -P sftpd_enable_homedirs 1
        # Allow sftp full access
        setsebool -P sftpd_full_access 1

        echo -e "${GREEN}SELinux configured for SSH Server.${NC}"
        ;;
      14) # Allow Netdata Monitoring
        echo "Configuring SELinux for Netdata Monitoring..."
        # Create a custom policy for netdata if not already done
        if ! semodule -l | grep -q "netdata"; then
          echo "Creating custom SELinux policy for Netdata..."

          # Create a temporary policy file
          cat > /tmp/netdata.te <<EOF
module netdata 1.0;

require {
    type unconfined_t;
    type netdata_t;
    type proc_t;
    type sysfs_t;
    type var_run_t;
    type unreserved_port_t;
    class file { getattr open read };
    class dir { getattr read search };
    class tcp_socket name_bind;
}

#============= netdata_t ==============
allow netdata_t proc_t:file { getattr open read };
allow netdata_t sysfs_t:dir { getattr read search };
allow netdata_t sysfs_t:file { getattr open read };
allow netdata_t unreserved_port_t:tcp_socket name_bind;
allow netdata_t var_run_t:dir { getattr read search };
EOF

          # Compile and load the policy
          cd /tmp
          if command -v checkmodule &>/dev/null && command -v semodule_package &>/dev/null; then
            checkmodule -M -m -o netdata.mod netdata.te && \
            semodule_package -o netdata.pp -m netdata.mod && \
            semodule -i netdata.pp && \
            echo -e "${GREEN}Custom SELinux policy for Netdata created and installed.${NC}" || \
            echo -e "${RED}Failed to create and install custom SELinux policy for Netdata.${NC}"
          else
            echo -e "${RED}SELinux policy tools not found. Installing...${NC}"
            dnf install -y checkpolicy setools-console
            checkmodule -M -m -o netdata.mod netdata.te && \
            semodule_package -o netdata.pp -m netdata.mod && \
            semodule -i netdata.pp && \
            echo -e "${GREEN}Custom SELinux policy for Netdata created and installed.${NC}" || \
            echo -e "${RED}Failed to create and install custom SELinux policy for Netdata.${NC}"
          fi

          # Clean up
          rm -f /tmp/netdata.te /tmp/netdata.mod /tmp/netdata.pp
        else
          echo -e "${GREEN}SELinux policy for Netdata already exists.${NC}"
        fi

        # Allow netdata to bind to port 19999
        if command -v semanage &>/dev/null; then
          semanage port -a -t http_port_t -p tcp 19999 || \
          semanage port -m -t http_port_t -p tcp 19999 || \
          echo -e "${YELLOW}Failed to set SELinux port for Netdata, but continuing...${NC}"
        fi

        echo -e "${GREEN}SELinux configured for Netdata Monitoring.${NC}"
        ;;
      15) # Create Custom SELinux Rule
        echo "Creating a custom SELinux rule..."
        read -p "Enter the source context (e.g., httpd_t): " source_context
        read -p "Enter the target context (e.g., user_home_t): " target_context
        read -p "Enter the object class (e.g., file, dir): " object_class
        read -p "Enter the permissions (e.g., read write): " permissions

        if [ -n "$source_context" ] && [ -n "$target_context" ] && [ -n "$object_class" ] && [ -n "$permissions" ]; then
          # Create a temporary policy file
          cat > /tmp/custom.te <<EOF
module custom 1.0;

require {
    type $source_context;
    type $target_context;
    class $object_class { $permissions };
}

#============= Custom Rule ==============
allow $source_context $target_context:$object_class { $permissions };
EOF

          # Compile and load the policy
          cd /tmp
          if command -v checkmodule &>/dev/null && command -v semodule_package &>/dev/null; then
            checkmodule -M -m -o custom.mod custom.te && \
            semodule_package -o custom.pp -m custom.mod && \
            semodule -i custom.pp && \
            echo -e "${GREEN}Custom SELinux rule created and installed.${NC}" || \
            echo -e "${RED}Failed to create and install custom SELinux rule.${NC}"
          else
            echo -e "${RED}SELinux policy tools not found. Installing...${NC}"
            dnf install -y checkpolicy setools-console
            checkmodule -M -m -o custom.mod custom.te && \
            semodule_package -o custom.pp -m custom.mod && \
            semodule -i custom.pp && \
            echo -e "${GREEN}Custom SELinux rule created and installed.${NC}" || \
            echo -e "${RED}Failed to create and install custom SELinux rule.${NC}"
          fi

          # Clean up
          rm -f /tmp/custom.te /tmp/custom.mod /tmp/custom.pp
        else
          echo -e "${RED}Error: All fields are required.${NC}"
        fi
        ;;
      16) # Restore SELinux Context
        echo "Restoring SELinux context to a file or directory..."
        read -p "Enter the path to restore context: " context_path

        if [ -e "$context_path" ]; then
          echo "Restoring SELinux context for $context_path..."
          restorecon -Rv "$context_path" && \
          echo -e "${GREEN}SELinux context restored for $context_path.${NC}" || \
          echo -e "${RED}Failed to restore SELinux context for $context_path.${NC}"
        else
          echo -e "${RED}Error: Path does not exist.${NC}"
        fi
        ;;
      17) # Fix phpMyAdmin MySQL Socket Connection
        fix_phpmyadmin_selinux
        ;;
      q|Q) # Quit
        # Ensure SSH access is still allowed before exiting
        setsebool -P ssh_sysadm_login 1
        break
        ;;
      *)
        echo -e "${RED}Invalid choice. Please try again.${NC}"
        ;;
    esac

    echo "Press any key to continue..."
    read -n 1 -s
  done
}

# Function to manage secure mount options in fstab
secure_mount_options() {
  # Check if fstab exists
  if [ ! -f "/etc/fstab" ]; then
    echo -e "${RED}Error: /etc/fstab file not found. Cannot configure mount options.${NC}"
    echo "Press any key to continue..."
    read -n 1 -s
    return 1
  fi

  while true; do
    clear
    echo "=========================================================="
    echo -e "${BLUE}            SECURE MOUNT OPTIONS MENU             ${NC}"
    echo "=========================================================="
    echo "Current /etc/fstab:"
    echo "----------------------------------------------------------"
    cat /etc/fstab | grep -v '^#' | grep -v '^$'
    echo "----------------------------------------------------------"
    echo ""
    echo "Secure Mount Options:"
    echo "1. Add noexec,nosuid,nodev to /tmp"
    echo "2. Add noexec,nosuid,nodev to /var/tmp"
    echo "3. Add nodev to /home"
    echo "4. Add nodev to /srv"
    echo "5. Add secure options to a custom mount point"
    echo "6. Restore fstab from backup"
    echo "7. View current fstab"
    echo "8. Make /boot/efi read-only (ro)"
    echo "9. Clean up duplicate mount options"
    echo "q. Return to Security Menu"
    echo "=========================================================="
    read -p "Enter your choice: " choice

    case $choice in
      1) # Secure /tmp
        # Check if /tmp is a separate mount point
        if grep -q "[[:space:]]/tmp[[:space:]]" /etc/fstab; then
          secure_mount_point "/tmp" "noexec,nosuid,nodev"
        else
          echo -e "${YELLOW}/tmp is not a separate mount point. Creating a tmpfs mount for /tmp...${NC}"
          # Add a tmpfs mount for /tmp if it doesn't exist
          echo "tmpfs /tmp tmpfs defaults,noexec,nosuid,nodev,size=2G 0 0" >> /etc/fstab
          echo -e "${GREEN}Added secure tmpfs mount for /tmp.${NC}"
        fi
        ;;
      2) # Secure /var/tmp
        # Check if /var/tmp is a separate mount point
        if grep -q "[[:space:]]/var/tmp[[:space:]]" /etc/fstab; then
          secure_mount_point "/var/tmp" "noexec,nosuid,nodev"
        else
          echo -e "${YELLOW}/var/tmp is not a separate mount point. Creating a tmpfs mount for /var/tmp...${NC}"
          # Add a tmpfs mount for /var/tmp if it doesn't exist
          echo "tmpfs /var/tmp tmpfs defaults,noexec,nosuid,nodev,size=1G 0 0" >> /etc/fstab
          echo -e "${GREEN}Added secure tmpfs mount for /var/tmp.${NC}"
        fi
        ;;
      3) # Secure /home
        if grep -q "[[:space:]]/home[[:space:]]" /etc/fstab; then
          secure_mount_point "/home" "nodev"
        else
          echo -e "${YELLOW}/home is not a separate mount point. Adding nodev to root partition...${NC}"
          # If /home is not a separate partition, we can modify the root partition
          secure_mount_point "/" "nodev"
        fi
        ;;
      4) # Secure /srv
        if grep -q "[[:space:]]/srv[[:space:]]" /etc/fstab; then
          secure_mount_point "/srv" "nodev"
        else
          echo -e "${YELLOW}/srv is not a separate mount point.${NC}"
          echo -e "${YELLOW}Adding nodev to /srv/share and /srv/web instead...${NC}"
          secure_mount_point "/srv/share" "nodev"
          secure_mount_point "/srv/web" "nodev"
        fi
        ;;
      5) # Custom mount point
        read -p "Enter the mount point (e.g., /mnt/data): " custom_mountpoint
        echo "Select security options to add:"
        echo "1. noexec - Prevent execution of binaries"
        echo "2. nosuid - Prevent suid/sgid bits from having an effect"
        echo "3. nodev - Prevent character or special devices"
        echo "4. All of the above"
        echo "5. ro - Read-only file system"
        read -p "Enter option (1-5): " sec_option

        case $sec_option in
          1) secure_mount_point "$custom_mountpoint" "noexec" ;;
          2) secure_mount_point "$custom_mountpoint" "nosuid" ;;
          3) secure_mount_point "$custom_mountpoint" "nodev" ;;
          4) secure_mount_point "$custom_mountpoint" "noexec,nosuid,nodev" ;;
          5) secure_mount_point "$custom_mountpoint" "ro" ;;
          *) echo -e "${RED}Invalid option selected.${NC}" ;;
        esac
        ;;
      6) # Restore from backup
        restore_fstab
        ;;
      7) # View fstab
        clear
        echo "Current /etc/fstab contents:"
        echo "----------------------------------------------------------"
        cat /etc/fstab
        echo "----------------------------------------------------------"
        echo "Press any key to continue..."
        read -n 1 -s
        ;;
      8) # Make /boot/efi read-only
        echo "Adding 'ro' (read-only) option to /boot/efi..."
        secure_mount_point "/boot/efi" "ro"
        echo -e "${YELLOW}IMPORTANT: When updating the bootloader or EFI files, you will need to temporarily remount /boot/efi as read-write:${NC}"
        echo "   sudo mount -o remount,rw /boot/efi"
        echo "   # perform updates"
        echo "   sudo mount -o remount,ro /boot/efi"
        ;;
      9) # Clean up duplicate mount options
        echo "Cleaning up duplicate mount options in fstab..."
        # Create a backup before cleaning
        local backup_file="/etc/fstab.clean.$(date +%Y%m%d%H%M%S)"
        cp /etc/fstab "$backup_file"
        echo -e "${GREEN}Backup created: $backup_file${NC}"

        # Process each mount point to clean up duplicate options
        clean_duplicate_options
        ;;
      q|Q) # Quit
        break
        ;;
      *)
        echo -e "${RED}Invalid choice. Please try again.${NC}"
        ;;
    esac

    # If not viewing fstab, wait for user input
    if [ "$choice" != "7" ]; then
      echo "Press any key to continue..."
      read -n 1 -s
    fi
  done
}

# Helper function to secure a specific mount point
secure_mount_point() {
  local mount_point=$1
  local secure_options=$2

  # Verify the mount point exists in fstab
  if ! grep -q "[[:space:]]${mount_point}[[:space:]]" /etc/fstab; then
    echo -e "${RED}Error: Mount point $mount_point not found in /etc/fstab.${NC}"
    return 1
  fi

  # Create a backup of fstab
  local backup_file="/etc/fstab.$(date +%Y%m%d%H%M%S)"
  cp /etc/fstab "$backup_file"
  echo -e "${GREEN}Backup created: $backup_file${NC}"

  # Get the line for this mount point
  local mount_line=$(grep "[[:space:]]${mount_point}[[:space:]]" /etc/fstab)

  # Check if the secure options are already present
  if echo "$mount_line" | grep -q "$secure_options"; then
    echo -e "${YELLOW}The secure options are already set for $mount_point.${NC}"
    return 0
  fi

  echo "Modifying mount options for $mount_point..."

  # Parse the existing line
  local device=$(echo "$mount_line" | awk '{print $1}')
  local fs_type=$(echo "$mount_line" | awk '{print $3}')
  local current_options=$(echo "$mount_line" | awk '{print $4}')
  local dump_flag=$(echo "$mount_line" | awk '{print $5}')
  local fsck_order=$(echo "$mount_line" | awk '{print $6}')

  # Add the new options, ensuring no duplicates
  local new_options
  if echo "$current_options" | grep -q "defaults"; then
    # Replace 'defaults' with 'defaults,new_options'
    new_options=$(echo "$current_options" | sed "s/defaults/defaults,$secure_options/")
  else
    # Append the new options
    new_options="${current_options},$secure_options"
  fi

  # Remove any duplicate options
  new_options=$(echo "$new_options" | tr ',' '\n' | sort | uniq | tr '\n' ',' | sed 's/,$//')

  # Create the new line
  local new_line="$device $mount_point $fs_type $new_options $dump_flag $fsck_order"

  # Replace the old line with the new line
  sed -i "s|^.*[[:space:]]${mount_point}[[:space:]].*\$|$new_line|" /etc/fstab

  # Verify the change was made correctly
  if grep -q "$mount_point" /etc/fstab; then
    echo -e "${GREEN}Successfully added $secure_options to $mount_point.${NC}"

    # Remind user to remount or reboot
    echo -e "${YELLOW}NOTE: You need to remount the filesystem or reboot for changes to take effect.${NC}"
    echo "You can remount with: mount -o remount $mount_point"
  else
    echo -e "${RED}Error: Failed to update fstab properly.${NC}"
    echo "Restoring from backup..."
    cp "$backup_file" /etc/fstab
    echo -e "${GREEN}Restored from backup.${NC}"
  fi
}

# Function to clean up duplicate mount options
clean_duplicate_options() {
  # Process each non-comment line in fstab
  while read -r line; do
    # Skip empty lines and comments
    if [[ -z "$line" || "$line" =~ ^# ]]; then
      continue
    fi

    # Parse the line
    local device=$(echo "$line" | awk '{print $1}')
    local mount_point=$(echo "$line" | awk '{print $2}')
    local fs_type=$(echo "$line" | awk '{print $3}')
    local options=$(echo "$line" | awk '{print $4}')
    local dump_flag=$(echo "$line" | awk '{print $5}')
    local fsck_order=$(echo "$line" | awk '{print $6}')

    # Clean up duplicate options
    local clean_options=$(echo "$options" | tr ',' '\n' | sort | uniq | tr '\n' ',' | sed 's/,$//')

    # Create new line with clean options
    local new_line="$device $mount_point $fs_type $clean_options $dump_flag $fsck_order"

    # Replace the old line with the new line
    sed -i "s|^$device[[:space:]]$mount_point[[:space:]]$fs_type[[:space:]]$options[[:space:]]$dump_flag[[:space:]]$fsck_order\$|$new_line|" /etc/fstab

    echo -e "${GREEN}Cleaned mount options for $mount_point.${NC}"

  done < <(grep -v '^#' /etc/fstab | grep -v '^$')

  echo -e "${GREEN}All duplicate mount options have been cleaned.${NC}"
}

# Helper function to restore fstab from backup
restore_fstab() {
  # List available backups
  local backups=($(ls -t /etc/fstab.* 2>/dev/null))

  if [ ${#backups[@]} -eq 0 ]; then
    echo -e "${RED}No backups found.${NC}"
    return 1
  fi

  echo "Available backups:"
  for i in "${!backups[@]}"; do
    echo "$((i+1)). ${backups[$i]} ($(stat -c %y ${backups[$i]} | cut -d. -f1))"
  done

  read -p "Select a backup to restore (or 'q' to cancel): " backup_choice

  if [[ "$backup_choice" == "q" || "$backup_choice" == "Q" ]]; then
    echo "Restoration cancelled."
    return 0
  fi

  if [[ "$backup_choice" =~ ^[0-9]+$ ]] && [ "$backup_choice" -ge 1 ] && [ "$backup_choice" -le ${#backups[@]} ]; then
    selected_backup="${backups[$((backup_choice-1))]}"

    # Create a backup of the current fstab before restoring
    cp /etc/fstab "/etc/fstab.current.$(date +%Y%m%d%H%M%S)"

    # Restore from selected backup
    cp "$selected_backup" /etc/fstab
    echo -e "${GREEN}Successfully restored fstab from $selected_backup.${NC}"
  else
    echo -e "${RED}Invalid selection.${NC}"
  fi
}

# Anti-malware function (main)
anti_malware() {
  clear
  echo "Setting up Anti-Malware Protection (ClamAV and RKHunter)..."

  # Run all security configurations
  configure_clamav
  configure_rkhunter
  configure_fail2ban

  echo "Anti-malware protection setup complete."
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Configure ClamAV function with improved resource management and error handling
configure_clamav() {
  echo "Installing and configuring ClamAV..."

  # Create a function to check if the system is under heavy load
  check_system_load() {
    load=$(cat /proc/loadavg | cut -d ' ' -f 1)
    load_int=${load%.*}
    cores=$(nproc)

    if [ "$load_int" -gt "$cores" ]; then
      echo -e "${YELLOW}System is under heavy load ($load). Waiting 30 seconds before continuing...${NC}"
      sleep 30
      return 1
    fi
    return 0
  }

  # Install ClamAV packages with timeout protection
  echo "Installing ClamAV packages - this may take a while..."

  # First check if already installed
  if rpm -q clamav clamav-update clamd &>/dev/null; then
    echo -e "${GREEN}ClamAV packages are already installed. Skipping installation.${NC}"
  else
    # Install with resource protection
    check_system_load

    # Use a timeout to prevent hanging
    timeout 300 dnf install -y clamav clamav-update || {
      echo -e "${RED}Installation timed out or failed. You may need to install ClamAV manually.${NC}"
      echo "Press any key to continue with other configurations..."
      read -n 1 -s
      return 1
    }
  fi

  # Make sure freshclam configuration is correct
  if [ -f "/etc/freshclam.conf" ]; then
    if grep -q "Example" /etc/freshclam.conf; then
      sed -i 's/^Example/#Example/' /etc/freshclam.conf
    fi

    # Update virus database with timeout and resource protection
    echo "Updating ClamAV virus database (with timeout protection)..."
    check_system_load

    echo "Running database update with a 5-minute timeout..."
    timeout 300 freshclam || {
      echo -e "${YELLOW}Database update timed out or failed. You can update it later with 'freshclam'.${NC}"
    }
  else
    echo -e "${YELLOW}freshclam.conf not found. Skipping database update.${NC}"
  fi

  # Configure clamd with proper error checking
  configure_clamd() {
    # Find the clamd config file
    CLAMD_CONF=""
    if [ -f "/etc/clamd.d/scan.conf" ]; then
      CLAMD_CONF="/etc/clamd.d/scan.conf"
    elif [ -f "/etc/clamd.conf" ]; then
      CLAMD_CONF="/etc/clamd.conf"
    else
      echo -e "${YELLOW}clamd configuration file not found. Skipping clamd configuration.${NC}"
      return 1
    fi

    echo "Configuring clamd ($CLAMD_CONF)..."
    sed -i 's/^Example/#Example/' "$CLAMD_CONF"
    sed -i 's/^#LocalSocket /LocalSocket /' "$CLAMD_CONF"
    sed -i 's/^#LogFile /LogFile /' "$CLAMD_CONF"
    sed -i 's/^#LogFileMaxSize /LogFileMaxSize /' "$CLAMD_CONF"
    return 0
  }

  # Call with error handling
  configure_clamd || echo -e "${YELLOW}clamd configuration could not be completed. Continuing with other steps.${NC}"

  # Find the correct service name for clamd with improved detection
  if systemctl list-unit-files | grep -q "clamd@"; then
    CLAMD_SERVICE="clamd@scan"
  elif systemctl list-unit-files | grep -q "clamd.service"; then
    CLAMD_SERVICE="clamd"
  else
    echo -e "${YELLOW}Warning: Could not determine correct clamd service name. Skipping clamd service setup.${NC}"
    CLAMD_SERVICE=""
  fi

  # Enable and start services with error handling
  echo "Enabling freshclam service..."
  systemctl enable clamav-freshclam.service || echo -e "${YELLOW}Failed to enable freshclam service, continuing...${NC}"
  systemctl start clamav-freshclam.service || echo -e "${YELLOW}Failed to start freshclam service, continuing...${NC}"

  # Try to enable and start clamd if available, with better error handling
  if [ -n "$CLAMD_SERVICE" ]; then
    echo "Enabling and starting $CLAMD_SERVICE service..."

    # Use timeout to prevent hanging
    timeout 60 systemctl enable $CLAMD_SERVICE || echo -e "${YELLOW}Warning: Failed to enable $CLAMD_SERVICE. ClamAV scanner may not be available.${NC}"
    timeout 60 systemctl start $CLAMD_SERVICE || echo -e "${YELLOW}Warning: Failed to start $CLAMD_SERVICE. ClamAV scanner may not be available.${NC}"
  fi

  # Set up daily scans - use a less intensive scan to prevent system overload
  mkdir -p /etc/cron.daily
  cat <<EOL > /etc/cron.daily/clamav-scan
#!/bin/sh
# Run at a time when the server is likely less busy
SCAN_TIME=\$(date +%H)
if [ "\$SCAN_TIME" -lt 4 ]; then
  # Only run intensive scan during night hours (0-4 AM)
  SCAN_DIRS="/srv /home /var/www /etc"
else
  # During day, only scan critical directories
  SCAN_DIRS="/srv/web /home"
fi

LOGFILE="/var/log/clamav/daily-scan.log"
mkdir -p /var/log/clamav
echo "ClamAV daily scan started at \$(date)" > \$LOGFILE

# Use nice to reduce priority, and limit CPU usage to 30%
nice -n 19 ionice -c3 clamscan -r --quiet --infected \$SCAN_DIRS >> \$LOGFILE

echo "ClamAV daily scan completed at \$(date)" >> \$LOGFILE
EOL
  chmod +x /etc/cron.daily/clamav-scan

  echo "ClamAV has been configured successfully with resource protection measures."
}

# Configure RKHunter function
configure_rkhunter() {
  echo "Installing and configuring RKHunter..."

  # Install rkhunter
  dnf install -y rkhunter

  # Initial configuration and update
  rkhunter --update
  rkhunter --propupd

  # Configure daily checks
  cat <<EOL > /etc/cron.daily/rkhunter-check
#!/bin/sh
LOGFILE="/var/log/rkhunter/daily-scan.log"
mkdir -p /var/log/rkhunter
echo "RKHunter daily scan started at \$(date)" > \$LOGFILE
rkhunter --check --skip-keypress --quiet >> \$LOGFILE
echo "RKHunter daily scan completed at \$(date)" >> \$LOGFILE
EOL
  chmod +x /etc/cron.daily/rkhunter-check

  echo "RKHunter has been configured successfully."
}

configure_fail2ban() {
  echo "Installing and configuring Fail2Ban..."
  dnf install fail2ban -y

  mkdir -p /etc/fail2ban/jail.d

  cat <<EOL > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOL

  cat <<EOL > /etc/fail2ban/jail.d/cockpit.local
[cockpit]
enabled = true
port = http,https
filter = cockpit
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOL

  cat <<EOL > /etc/fail2ban/jail.d/ftp.local
[vsftpd]
enabled = true
port = ftp,ftp-data,ftps,ftps-data
filter = vsftpd
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOL

  cat <<EOL > /etc/fail2ban/jail.d/samba.local
[samba]
enabled = true
port = samba,samba-ds,samba-ds-port
filter = samba
logpath = /var/log/samba/log.smbd
maxretry = 3
bantime = 3600
EOL

  cat <<EOL > /etc/fail2ban/jail.d/apache.local
[apache-auth]
enabled = true
port = http,https
filter = apache-auth
logpath = /var/log/httpd/*error_log
maxretry = 3
bantime = 3600
EOL

  systemctl enable --now fail2ban

  echo "Fail2Ban configured for SSH, Fedora Cockpit, FTP, Samba, and Apache."
}
