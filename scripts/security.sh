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
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " security_choice
    case $security_choice in
      1) firewall_management ;;
      2) anti_malware ;;
      3) selinux_management ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
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
        setenforce 1
        sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
        echo -e "${GREEN}SELinux set to Enforcing mode.${NC}"
        echo "This change will be permanent after reboot."
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

# Rest of the file remains the same as before
# ...
