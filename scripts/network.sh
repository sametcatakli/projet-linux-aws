#!/bin/bash

# Network services menu
network_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                 ${BLUE}Network Services Menu ${NC}                              |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. Set Server Hostname                                               |"
    echo "| 2. SSH Configuration                                                 |"
    echo "| 3. DNS Server Configuration                                          |"
    echo "| 4. NTP Time Server                                                   |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " network_choice
    case $network_choice in
      1) set_hostname ;;
      2) ssh_setup ;;
      3) basic_dns_setup ;;
      4) ntp ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Set hostname function
set_hostname() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                     ${BLUE}Hostname Configuration Menu ${NC}                     |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. Set hostname                                                      |"
    echo "| 2. Display current hostname                                          |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back                                                              |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " hostname_choice
    case $hostname_choice in
      1) read -p "Enter the new hostname: " new_hostname
         hostnamectl set-hostname $new_hostname
         echo "Hostname set to $new_hostname"
         echo "Press any key to continue..."
         read -n 1 -s key
         clear
         ;;
      2) current_hostname=$(hostnamectl --static)
         echo "Current hostname: $current_hostname"
         echo "Press any key to continue..."
         read -n 1 -s key
         clear
         ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# SSH Configuration function
ssh_setup() {
  clear
  echo "Starting ssh with enhanced security..."
  sudo systemctl enable --now sshd
  sudo systemctl start sshd
  sudo firewall-cmd --permanent --add-service=ssh
  sudo firewall-cmd --reload

  # Generate SSH key pair
  ssh-keygen -t rsa -b 4096

  # Copy public key to authorized_keys file
  mkdir -p ~/.ssh
  cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

  # Set permissions for SSH files
  chmod 700 ~/.ssh
  chmod 600 ~/.ssh/id_rsa
  chmod 644 ~/.ssh/id_rsa.pub
  chmod 644 ~/.ssh/authorized_keys

  # Configure SSH to disable root login and password authentication
  echo "Configuring SSH for improved security..."

  # Backup original sshd_config
  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

  # Update SSH configuration
  sed -i 's/#PermitRootLogin yes/PermitRootLogin no/' /etc/ssh/sshd_config
  sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config

  # Enable SSH logging
  sed -i 's/#LogLevel INFO/LogLevel VERBOSE/' /etc/ssh/sshd_config

  echo "SSH configured for key-based authentication only, root login disabled, and logging enabled."

  # Restart SSH service
  sudo systemctl restart sshd

  echo "SSH service restarted. Key-based authentication is now required."
  echo "IMPORTANT: Make sure you have SSH key access before logging out!"
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Basic DNS setup function
basic_dns_setup() {
  clear
  echo "Setting up DNS server..."

  read -p "Enter the IP address : " IP_ADDRESS
  read -p "Enter the server domain name (e.g., test.toto) : " DOMAIN_NAME

  basic_dns "$IP_ADDRESS" "$DOMAIN_NAME"
  echo "DNS configuration complete."
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Basic DNS function
basic_dns() {
  echo "Setting up DNS server..."

  # Install necessary packages first
  dnf -y install bind bind-utils

  # Configure firewall for DNS
  if systemctl is-active --quiet firewalld; then
      firewall-cmd --add-service=dns --permanent || echo "Firewall rule addition failed, continuing anyway..."
      firewall-cmd --reload || echo "Firewall reload failed, continuing anyway..."
  else
      echo "Firewalld not running. DNS firewall rules not applied."
  fi

  IP_ADDRESS=$1
  DOMAIN_NAME=$2
  NETWORK=$(echo $IP_ADDRESS | cut -d"." -f1-3).0/24
  REVERSE_ZONE=$(echo $IP_ADDRESS | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')
  REVERSE_IP=$(echo $IP_ADDRESS | awk -F. '{print $4}')

  # Create or back up named.conf
  if [ -f "/etc/named.conf" ]; then
      TIMESTAMP=$(date +"%Y%m%d%H%M%S")
      BACKUP_FILE="/etc/named.conf.bak.$TIMESTAMP"
      cp "/etc/named.conf" "$BACKUP_FILE"
      echo "Successfully backed up /etc/named.conf to $BACKUP_FILE"
  else
      echo "Creating new /etc/named.conf file"
      mkdir -p /var/named/data
  fi

  # Make sure /var/named exists
  mkdir -p /var/named

  # Create named.ca if it doesn't exist
  if [ ! -f "/var/named/named.ca" ]; then
      echo "Downloading named.ca file..."
      curl -o /var/named/named.ca https://www.internic.net/domain/named.root
  fi

cat <<EOL > /etc/named.conf
options {
    listen-on port 53 { any; };
    directory "/var/named";
    dump-file "/var/named/data/cache_dump.db";
    statistics-file "/var/named/data/named_stats.txt";
    memstatistics-file "/var/named/data/named_mem_stats.txt";
    recursion yes;
    allow-query { any; };
    allow-transfer { none; };

    dnssec-validation auto;
    managed-keys-directory "/var/named/dynamic";
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

zone "." IN {
    type hint;
    file "named.ca";
};

zone "$DOMAIN_NAME" IN {
    type master;
    file "forward.$DOMAIN_NAME";
    allow-update { none; };
};

zone "$REVERSE_ZONE" IN {
    type master;
    file "reverse.$DOMAIN_NAME";
    allow-update { none; };
};
EOL

cat <<EOL > /var/named/forward.$DOMAIN_NAME
\$TTL 86400
@   IN  SOA     ns.$DOMAIN_NAME. root.$DOMAIN_NAME. (
            2024052101 ; Serial
            3600       ; Refresh
            1800       ; Retry
            604800     ; Expire
            86400 )    ; Minimum TTL
;
@       IN  NS      ns.$DOMAIN_NAME.
ns      IN  A       $IP_ADDRESS
@       IN  A       $IP_ADDRESS
*       IN  A       $IP_ADDRESS
EOL

cat <<EOL > /var/named/reverse.$DOMAIN_NAME
\$TTL 86400
@   IN  SOA     ns.$DOMAIN_NAME. root.$DOMAIN_NAME. (
            2024052101 ; Serial
            3600       ; Refresh
            1800       ; Retry
            604800     ; Expire
            86400 )    ; Minimum TTL
;
@       IN  NS      ns.$DOMAIN_NAME.
$REVERSE_IP       IN  PTR     $DOMAIN_NAME.
EOL

  # Set proper permissions
  chmod 640 /etc/named.conf
  chown root:named /etc/named.conf
  chown named:named /var/named/forward.$DOMAIN_NAME
  chown named:named /var/named/reverse.$DOMAIN_NAME
  chmod 640 /var/named/forward.$DOMAIN_NAME
  chmod 640 /var/named/reverse.$DOMAIN_NAME

echo 'OPTIONS="-4"' > /etc/sysconfig/named

cat <<EOL > /etc/hosts
$IP_ADDRESS $DOMAIN_NAME
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
EOL

cat <<EOL > /etc/hostname
$DOMAIN_NAME
EOL

  # Stop and disable systemd-resolved if it's running (can conflict with named)
  if systemctl is-active --quiet systemd-resolved; then
      echo "Stopping systemd-resolved as it conflicts with named..."
      systemctl disable --now systemd-resolved
  fi

  # Start and enable named
  systemctl enable named
  systemctl restart named

  # Verify named is running
  if ! systemctl is-active --quiet named; then
      echo "Warning: Named service failed to start. Checking logs..."
      journalctl -u named --no-pager -n 20
  else
      echo "Named service started successfully."
  fi

  # Create a backup of the original resolv.conf
  cp /etc/resolv.conf /etc/resolv.conf.bak

  # Configure local DNS resolution
cat <<EOL > /etc/resolv.conf
nameserver 127.0.0.1
nameserver 8.8.8.8
options edns0
search $DOMAIN_NAME
EOL

  echo "DNS configuration complete. Testing resolution..."
  nslookup $DOMAIN_NAME 127.0.0.1 || echo "DNS resolution test failed. Check named configuration."
}

# NTP function (main)
ntp() {
  while true; do
    clear
    echo "|-------------------------------------------|"
    echo -e "|            ${GREEN}NTP server wizard${NC}              |"
    echo "|-------------------------------------------|"
    echo "|         What do you want to do?           |"
    echo "|-------------------------------------------|"
    echo "| 1. Setup the NTP (defaults to Eu/Bx)      |"
    echo "| 2. Choose a timezone                      |"
    echo "| 3. Show NTP statuses                      |"
    echo "|-------------------------------------------|"
    echo "| q. Back                                   |"
    echo "|-------------------------------------------|"
    echo ""
    read -p "Enter your choice: " choice
    case $choice in
        1) setup_ntp ;;
        2) timezone_choice ;;
        3) timezone_display ;;
        q|Q) clear && break ;;
        *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Setup NTP function
setup_ntp() {
  clear

  ip_server=$(hostname -I | sed 's/ *$//')/16
  ntp_pool="server 0.pool.ntp.org iburst\\nserver 1.pool.ntp.org iburst\\nserver 2.pool.ntp.org iburst\\nserver 3.pool.ntp.org iburst"
  dnf install chrony -y
  systemctl enable --now chronyd
  timedatectl set-timezone Europe/Brussels
  echo "Time zone set to Europe/Brussels"
  timedatectl set-ntp yes
  sed -i "s|#allow 192.168.0.0/16|allow $ip_server|g" /etc/chrony.conf
  sed -i "s/pool 2.almalinux.pool.ntp.org iburst/$ntp_pool/g" /etc/chrony.conf
  systemctl restart chronyd
  echo "Chrony restarted"

  echo "Press any key to continue..."
  read -n 1 -s key
}

# Timezone choice function
timezone_choice() {
  clear

  timezones=$(timedatectl list-timezones)
  echo "Available timezones:"
  PS3="Please select a timezone by number: "

  select timezone in $timezones; do
  if [[ -n $timezone ]]; then
      echo "You selected $timezone"
      break
  else
      echo "Invalid selection. Please try again."
  fi
  done

  echo "Changing timezone to $timezone..."
  timedatectl set-timezone "$timezone"

  echo -e "\nTimezone changed successfully. Current timezone is now:"
  timedatectl | grep "Time zone"

  echo "Press any key to exit..."
  read -n 1 -s key
}

# Display timezone function
timezone_display() {
  clear

  echo "System Time and Date Information"
  echo "--------------------------------"

  echo -e "\nCurrent System Date and Time:"
  date

  echo -e "\nHardware Clock (RTC) Time:"
  hwclock

  echo -e "\nCurrent Timezone:"
  timedatectl | grep "Time zone"

  echo -e "\nTimedatectl Status:"
  timedatectl status

  echo -e "\nNTP Synchronization Status (timedatectl):"
  timedatectl show-timesync --all

  if command -v chronyc &> /dev/null; then
      echo -e "\nChrony Tracking Information:"
      chronyc tracking

      echo -e "\nChrony Sources:"
      chronyc sources

      echo -e "\nChrony Source Statistics:"
      chronyc sourcestats

      echo -e "\nChrony NTP Data:"
      chronyc ntpdata
  else
      echo -e "\nChrony is not installed or not found. Skipping chrony information."
  fi

  echo "--------------------------------"
  echo "All time and date information displayed successfully."

  echo "Press any key to exit..."
  read -n 1 -s key
}
