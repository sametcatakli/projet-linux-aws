#!/bin/bash

# Monitoring menu
monitoring_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                  ${BLUE}Monitoring Services Menu ${NC}                         |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. Netdata Server Installation                                       |"
    echo "| 2. Netdata Client Installation                                       |"
    echo "| 3. View System Logs                                                  |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " monitoring_choice
    case $monitoring_choice in
      1) install_netdata_server ;;
      2) install_netdata_client ;;
      3) logs ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Function to install Netdata Server
install_netdata_server() {
  clear
  echo "Installing Netdata Server..."

  # Install Netdata using the kickstart script
  bash <(curl -Ss https://my-netdata.io/kickstart.sh) --dont-wait

  # Configure firewall for Netdata
  if systemctl is-active --quiet firewalld; then
    echo "Opening firewall port for Netdata (19999)..."
    firewall-cmd --permanent --add-port=19999/tcp
    firewall-cmd --reload
  fi

  # Generate a random API key
  API_KEY=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)

  # Configure streaming
  echo "Configuring Netdata streaming..."
  cat <<EOL > /etc/netdata/stream.conf
[stream]
  enabled = yes
  api key = ${API_KEY}
  default memory mode = ram
  health enabled by default = auto
  allow from = *
EOL

  # Restart Netdata
  systemctl restart netdata

  # Get server IP
  SERVER_IP=$(hostname -I | awk '{print $1}')

  echo "========================================================"
  echo "Netdata Server Installation Complete!"
  echo "------------------------------------------------------"
  echo "Server IP: ${SERVER_IP}"
  echo "Netdata Port: 19999"
  echo "API Key: ${API_KEY}"
  echo "------------------------------------------------------"
  echo "You can access the Netdata dashboard at:"
  echo "http://${SERVER_IP}:19999"
  echo "------------------------------------------------------"
  echo "Use this API key when installing Netdata clients."
  echo "========================================================"
  echo ""

  echo "Press any key to continue..."
  read -n 1 -s
}

# Function to install Netdata Client
# Function to install Netdata Client
install_netdata_client() {
  clear
  echo "Installing Netdata Client..."

  # Ask for server IP:port and API key
  read -p "Enter the Netdata server IP and port (format: IP:port) : " ip_port
  read -p "Enter your API key for the client : " api_key
  read -p "Enter the name of hostname for the client : " hostname

  # Installation of Netdata on the client
  echo "Installation of Netdata on the client..."
  bash <(curl -SsL https://my-netdata.io/kickstart.sh) --dont-wait

  # Verify that Netdata was installed successfully
  if [ ! -d "/etc/netdata" ]; then
    echo -e "${RED}Error: Netdata installation failed. Directory /etc/netdata not found.${NC}"
    echo "Press any key to continue..."
    read -n 1 -s
    return 1
  fi

  # Adding stream configuration to /etc/netdata/stream.conf
  echo "Adding stream configuration to /etc/netdata/stream.conf..."
  sudo sed -i "/^\[stream\]/,/\[\/stream\]/d" /etc/netdata/stream.conf
  echo -e "[stream]\n  enabled = yes\n  destination = $ip_port\n  api key = $api_key\n" | sudo tee -a /etc/netdata/stream.conf

  # Configure hostname in /etc/netdata/netdata.conf
  echo "Configuring hostname in /etc/netdata/netdata.conf..."
  sudo sed -i "/^\[global\]/,/\[\/global\]/d" /etc/netdata/netdata.conf
  echo -e "[global]\n  hostname = $hostname\n" | sudo tee -a /etc/netdata/netdata.conf

  # Restart Netdata on the client
  echo "Restarting Netdata on the client..."
  sudo systemctl restart netdata

  # Verify that Netdata is running
  if ! systemctl is-active --quiet netdata; then
    echo -e "${RED}Warning: Netdata service didn't restart properly. Please check the service status.${NC}"
  else
    echo -e "${GREEN}Netdata service is running.${NC}"
  fi

  echo "========================================================"
  echo "Netdata Client Installation Complete!"
  echo "------------------------------------------------------"
  echo "Client is now streaming to: ${ip_port}"
  echo "Client hostname: ${hostname}"
  echo "------------------------------------------------------"
  echo "The server dashboard should now show data from this client."
  echo "========================================================"
  echo ""

  echo "Press any key to continue..."
  read -n 1 -s
}

# Logs menu
logs() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                ${BLUE}System Logs Dashboard ${NC}                           |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. View Apache access logs                                           |"
    echo "| 2. View Apache error logs                                            |"
    echo "| 3. View SSH login attempts                                           |"
    echo "| 4. View MariaDB logs                                                 |"
    echo "| 5. View System logs (journalctl)                                     |"
    echo "| 6. View Anti-Malware logs                                            |"
    echo "| 7. View FTP logs                                                     |"
    echo "| 8. View Firewall logs                                                |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back                                                              |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " log_choice
    case $log_choice in
        1) view_apache_access ;;
        2) view_apache_error ;;
        3) view_ssh_logs ;;
        4) view_mariadb_logs ;;
        5) view_system_logs ;;
        6) view_antimalware_logs ;;
        7) view_ftp_logs ;;
        8) view_firewall_logs ;;
        q|Q) clear && break ;;
        *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# View Apache access logs function
view_apache_access() {
  echo "Recent Apache access logs:"
  echo "-------------------------"
  if [ -f /var/log/httpd/access_log ]; then
      tail -n 50 /var/log/httpd/access_log
  else
      echo "Apache access log not found at /var/log/httpd/access_log"
  fi
  echo "Press any key to continue..."
  read -n 1 -s key
}

# View Apache error logs function
view_apache_error() {
  echo "Recent Apache error logs:"
  echo "------------------------"
  if [ -f /var/log/httpd/error_log ]; then
      tail -n 50 /var/log/httpd/error_log
  else
      echo "Apache error log not found at /var/log/httpd/error_log"
  fi
  echo "Press any key to continue..."
  read -n 1 -s key
}

# View SSH logs function
# View SSH logs function
view_ssh_logs() {
  echo "Recent SSH login attempts:"
  echo "-------------------------"
  if [ -f /var/log/secure ]; then
      grep "sshd" /var/log/secure | tail -n 50
  elif [ -f /var/log/auth.log ]; then
      grep "sshd" /var/log/auth.log | tail -n 50
  else
      echo "SSH logs not found in standard locations. Checking journal..."
      journalctl -u sshd --no-pager -n 50
  fi
  echo "Press any key to continue..."
  read -n 1 -s key
}

# View MariaDB logs function
view_mariadb_logs() {
  echo "Recent MariaDB logs:"
  echo "------------------"
  if [ -f /var/log/mariadb/mariadb.log ]; then
      tail -n 50 /var/log/mariadb/mariadb.log
  else
      echo "MariaDB log not found at /var/log/mariadb/mariadb.log"
      echo "Checking alternative locations..."
      journalctl -u mariadb --no-pager -n 50
  fi
  echo "Press any key to continue..."
  read -n 1 -s key
}

# View system logs function
view_system_logs() {
  echo "Recent system logs:"
  echo "------------------"
  journalctl -n 50 --no-pager
  echo "Press any key to continue..."
  read -n 1 -s key
}

# View anti-malware logs function
view_antimalware_logs() {
  echo "Recent Anti-Malware logs:"
  echo "------------------------"
  echo "1. ClamAV logs:"
  if [ -d /var/log/clamav ]; then
      ls -l /var/log/clamav
      for log in /var/log/clamav/*; do
          echo "--- $log ---"
          tail -n 20 "$log"
          echo ""
      done
  else
      echo "ClamAV logs directory not found at /var/log/clamav"
  fi

  echo "2. RKHunter logs:"
  if [ -d /var/log/rkhunter ]; then
      ls -l /var/log/rkhunter
      for log in /var/log/rkhunter/*; do
          echo "--- $log ---"
          tail -n 20 "$log"
          echo ""
      done
  else
      echo "RKHunter logs directory not found at /var/log/rkhunter"
  fi
      echo "Press any key to continue..."
      read -n 1 -s key
  }

  # View FTP logs function
  view_ftp_logs() {
    echo "Recent FTP logs:"
    echo "---------------"
    if [ -f /var/log/vsftpd.log ]; then
        tail -n 50 /var/log/vsftpd.log
    else
        echo "FTP log not found at /var/log/vsftpd.log"
    fi
    echo "Press any key to continue..."
    read -n 1 -s key
  }

  # View firewall logs function
  view_firewall_logs() {
    echo "Recent Firewall logs:"
    echo "--------------------"
    journalctl -u firewalld --no-pager -n 50
    echo "Press any key to continue..."
    read -n 1 -s key
  }
