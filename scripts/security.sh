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
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Function to manage firewall
firewall_management() {
  local choice

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

  # CRITICAL FIX: Always ensure SSH is allowed BEFORE starting firewalld
  # This way even if firewalld is being enabled for the first time, SSH won't be blocked
  echo "Ensuring SSH access remains available..."
  firewall-cmd --permanent --add-service=ssh

  # Ensure firewalld is running
  if ! systemctl is-active --quiet firewalld; then
    echo -e "${YELLOW}Firewalld is not running. Starting...${NC}"
    systemctl enable firewalld

    # Apply the SSH rule before starting firewalld to prevent lockout
    echo "Applying SSH rule before starting firewall..."
    firewall-cmd --permanent --add-service=ssh

    systemctl start firewalld

    if ! systemctl is-active --quiet firewalld; then
      echo -e "${RED}Failed to start firewalld. Firewall management won't be available.${NC}"
      echo "Press any key to continue..."
      read -n 1 -s
      return 1
    fi
    echo -e "${GREEN}Firewalld started successfully with SSH access preserved.${NC}"
  fi

  # CRITICAL FIX: Double-check SSH is allowed and apply changes
  echo "Verifying SSH access is permitted in firewall..."
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --reload

  # Configure firewall to allow external connections for common services
  configure_firewall_defaults() {
    echo -e "${YELLOW}Configuring firewall defaults to allow external connections...${NC}"

    # Set default zone to public
    firewall-cmd --set-default-zone=public

    # CRITICAL: Make sure SSH comes first and is always included
    firewall-cmd --permanent --zone=public --add-service=ssh

    # Add other services to public zone
    firewall-cmd --permanent --zone=public --add-service=http
    firewall-cmd --permanent --zone=public --add-service=https
    firewall-cmd --permanent --zone=public --add-service=dns
    firewall-cmd --permanent --zone=public --add-service=ftp

    # Allow passive FTP port range
    firewall-cmd --permanent --zone=public --add-port=30000-31000/tcp

    # Apply changes
    firewall-cmd --reload

    # Final verification that SSH is allowed
    echo "Final verification of SSH access..."
    if firewall-cmd --list-services | grep -q ssh; then
      echo -e "${GREEN}SSH access confirmed in firewall.${NC}"
    else
      echo -e "${RED}ERROR: SSH service not found in firewall! Adding it now...${NC}"
      firewall-cmd --permanent --add-service=ssh
      firewall-cmd --reload
    fi

    echo -e "${GREEN}Firewall configured with permissive defaults.${NC}"
  }

  while true; do
    clear
    echo "=========================================================="
    echo -e "${BLUE}              FIREWALL MANAGEMENT MENU             ${NC}"
    echo "=========================================================="
    echo "1. Open DNS Port (53)"
    echo "2. Open HTTP Port (80)"
    echo "3. Open HTTPS Port (443)"
    echo "4. Open SSH Port (22)"
    echo "5. Open MariaDB/MySQL Port (3306)"
    echo "6. Open Samba Ports (137-139, 445)"
    echo "7. Open NFS Ports (111, 2049, 4045)"
    echo "8. Open FTP Ports (20, 21)"
    echo "9. Open Cockpit Port (9090)"
    echo "10. Show Current Firewall Status"
    echo "11. Allow a Custom Port"
    echo "12. Block All Ports (except opened ones)"
    echo "13. Reset Firewall to Default"
    echo "14. Enable Firewall"
    echo "15. Disable Firewall"
    echo "16. Netdata"
    echo "17. Configure Permissive Defaults (Allow External Access)"
    echo "q. Return to Previous Menu"
    echo "=========================================================="
    read -p "Enter your choice: " choice

    case $choice in
      1) # DNS
        firewall-cmd --permanent --add-service=dns
        echo -e "${GREEN}DNS port opened.${NC}"
        ;;
      2) # HTTP
        firewall-cmd --permanent --add-service=http
        echo -e "${GREEN}HTTP port opened.${NC}"
        ;;
      3) # HTTPS
        firewall-cmd --permanent --add-service=https
        echo -e "${GREEN}HTTPS port opened.${NC}"
        ;;
      4) # SSH
        firewall-cmd --permanent --add-service=ssh
        echo -e "${GREEN}SSH port opened.${NC}"
        ;;
      5) # MariaDB
        firewall-cmd --permanent --add-service=mysql
        echo -e "${GREEN}MariaDB/MySQL port opened.${NC}"
        ;;
      6) # Samba
        firewall-cmd --permanent --add-service=samba
        echo -e "${GREEN}Samba ports opened.${NC}"
        ;;
      7) # NFS
        firewall-cmd --permanent --add-service=nfs
        firewall-cmd --permanent --add-service=rpc-bind
        firewall-cmd --permanent --add-service=mountd
        echo -e "${GREEN}NFS ports opened.${NC}"
        ;;
      8) # FTP
        firewall-cmd --permanent --add-service=ftp
        firewall-cmd --permanent --add-port=30000-31000/tcp
        echo -e "${GREEN}FTP ports opened (including passive range).${NC}"
        ;;
      9) # Cockpit
        firewall-cmd --permanent --add-service=cockpit
        echo -e "${GREEN}Cockpit port opened.${NC}"
        ;;
      10) # Status
        echo "Current Firewall Status:"
        echo "------------------------"
        firewall-cmd --list-all
        echo "------------------------"
        ;;
      11) # Custom port
        read -p "Enter port number to open: " port
        read -p "Enter protocol (tcp/udp): " protocol
        if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$protocol" =~ ^(tcp|udp)$ ]]; then
          firewall-cmd --permanent --add-port=${port}/${protocol}
          echo -e "${GREEN}Port ${port}/${protocol} opened.${NC}"
        else
          echo -e "${RED}Invalid input. Please enter a valid port number and protocol.${NC}"
        fi
        ;;
      12) # Block all except opened
        # Make sure SSH is added first
        firewall-cmd --permanent --add-service=ssh

        # Set default zone to drop
        firewall-cmd --set-default-zone=drop

        # But make sure established connections work
        firewall-cmd --permanent --direct --add-rule ipv4 filter INPUT 0 -m state --state ESTABLISHED,RELATED -j ACCEPT

        # Double-check SSH access
        firewall-cmd --permanent --add-service=ssh

        echo -e "${GREEN}Firewall set to block all traffic except for opened ports.${NC}"
        echo -e "${GREEN}SSH access has been preserved.${NC}"
        ;;
      13) # Reset
        # Make sure SSH is allowed before resetting
        firewall-cmd --permanent --add-service=ssh

        firewall-cmd --permanent --set-default-zone=public
        firewall-cmd --permanent --zone=public --remove-port=1-65535/tcp
        firewall-cmd --permanent --zone=public --remove-port=1-65535/udp

        # Add SSH again after reset
        firewall-cmd --permanent --add-service=ssh

        echo -e "${GREEN}Firewall reset to default configuration with SSH access preserved.${NC}"
        ;;
      14) # Enable
        # Make sure SSH is allowed before enabling
        firewall-cmd --permanent --add-service=ssh

        systemctl enable --now firewalld

        # Verify SSH is still allowed after enabling
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --reload

        echo -e "${GREEN}Firewall enabled and started with SSH access preserved.${NC}"
        ;;
      15) # Disable
        systemctl disable --now firewalld
        echo -e "${YELLOW}Firewall disabled and stopped.${NC}"
        ;;
      16) # Netdata
        firewall-cmd --permanent --add-port=19999/tcp
        echo -e "${YELLOW}Netdata port authorized.${NC}"
        ;;
      17) # Configure permissive defaults
        configure_firewall_defaults
        ;;
      q|Q) # Quit
        # Apply all changes

        # Make sure SSH is still allowed before final apply
        firewall-cmd --permanent --add-service=ssh
        firewall-cmd --reload

        echo -e "${GREEN}Firewall changes applied with SSH access preserved.${NC}"
        break
        ;;
      *)
        echo -e "${RED}Invalid choice. Please try again.${NC}"
        ;;
    esac

    # Always ensure SSH access after any action
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload

    echo "Press any key to continue..."
    read -n 1 -s
  done
}

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
    echo "7. Allow FTP Server"
    echo "8. Allow Samba Server"
    echo "9. Allow NFS Server"
    echo "10. Allow DNS Server"
    echo "11. Allow Mail Server"
    echo "12. Allow SSH Server"
    echo "13. Allow Netdata Monitoring"
    echo "14. Create Custom SELinux Rule"
    echo "15. Restore Default SELinux Context to File/Directory"
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
      7) # Allow FTP Server
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
      8) # Allow Samba Server
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
      9) # Allow NFS Server
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
      10) # Allow DNS Server
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
      11) # Allow Mail Server
        echo "Configuring SELinux for Mail Server..."
        # Allow postfix to read user mail
        setsebool -P postfix_local_read_mail 1
        # Allow mail use spool
        setsebool -P mail_read_content 1

        echo -e "${GREEN}SELinux configured for Mail Server.${NC}"
        ;;
      12) # Allow SSH Server
        echo "Configuring SELinux for SSH Server..."
        # Allow SSH to read and write to all files
        setsebool -P ssh_sysadm_login 1
        # Allow sftp to access user home directories
        setsebool -P sftpd_enable_homedirs 1
        # Allow sftp full access
        setsebool -P sftpd_full_access 1

        echo -e "${GREEN}SELinux configured for SSH Server.${NC}"
        ;;
      13) # Allow Netdata Monitoring
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
      14) # Create Custom SELinux Rule
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
      15) # Restore SELinux Context
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
    echo "8. Make /boot read-only (ro)"
    echo "q. Return to Security Menu"
    echo "=========================================================="
    read -p "Enter your choice: " choice

    case $choice in
      1) # Secure /tmp
        secure_mount_point "/tmp" "noexec,nosuid,nodev"
        ;;
      2) # Secure /var/tmp
        secure_mount_point "/var/tmp" "noexec,nosuid,nodev"
        ;;
      3) # Secure /home
        secure_mount_point "/home" "nodev"
        ;;
      4) # Secure /srv
        secure_mount_point "/srv" "nodev"
        ;;
      5) # Custom mount point
        read -p "Enter the mount point (e.g., /mnt/data): " custom_mountpoint
        echo "Select security options to add:"
        echo "1. noexec - Prevent execution of binaries"
        echo "2. nosuid - Prevent suid/sgid bits from having an effect"
        echo "3. nodev - Prevent character or special devices"
        echo "4. All of the above"
        read -p "Enter option (1-4): " sec_option

        case $sec_option in
          1) secure_mount_point "$custom_mountpoint" "noexec" ;;
          2) secure_mount_point "$custom_mountpoint" "nosuid" ;;
          3) secure_mount_point "$custom_mountpoint" "nodev" ;;
          4) secure_mount_point "$custom_mountpoint" "noexec,nosuid,nodev" ;;
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
      8) # Make /boot read-only
        echo "Adding 'ro' (read-only) option to /boot..."
        secure_mount_point "/boot" "ro"
        echo -e "${YELLOW}IMPORTANT: When updating the kernel or bootloader, you will need to temporarily remount /boot as read-write:${NC}"
        echo "   sudo mount -o remount,rw /boot"
        echo "   # perform updates"
        echo "   sudo mount -o remount,ro /boot"
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
  new_options=$(echo "$new_options" | sed 's/,\+/,/g' | sed 's/^,//;s/,$//')

  # Create the new line
  local new_line="$device $mount_point $fs_type $new_options $dump_flag $fsck_order"

  # Replace the old line with the new line
  sed -i "s|^.*[[:space:]]${mount_point}[[:space:]].*\$|$new_line|" /etc/fstab

  # Verify the change was made correctly
  if grep -q "^$new_line$" /etc/fstab; then
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

# Configure Fail2Ban function
configure_fail2ban() {
  echo "Installing and configuring Fail2Ban..."
  # Install Fail2Ban
  dnf install fail2ban -y

  # Configure Fail2Ban for SSH
  cat <<EOL > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOL

  # Configure Fail2Ban for Fedora Cockpit
  cat <<EOL > /etc/fail2ban/jail.d/cockpit.local
[cockpit]
enabled = true
port = http,https
filter = cockpit
logpath = /var/log/secure
maxretry = 3
bantime = 3600
EOL

  # Restart Fail2Ban service
  systemctl enable --now fail2ban

  echo "Fail2Ban configured for SSH and Fedora Cockpit."
}
