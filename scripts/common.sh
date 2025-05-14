#!/bin/bash

# Color definitions
RED='\033[0;31m'
BLUE='\e[38;5;33m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Function to check and install package if not present
install_if_missing() {
  local package=$1
  if ! rpm -q "$package" &>/dev/null; then
    echo -e "${YELLOW}$package is not installed. Installing...${NC}"
    dnf install -y "$package" || {
      echo -e "${RED}Failed to install $package. Please check your internet connection and repositories.${NC}"
      return 1
    }
    echo -e "${GREEN}$package installed successfully.${NC}"
  else
    echo -e "${GREEN}$package is already installed.${NC}"
  fi
  return 0
}

# Function to backup a file
backup_file() {
  ORIGINAL_FILE=$1
  if [ ! -f "$ORIGINAL_FILE" ]; then
      echo "Note: $ORIGINAL_FILE does not exist. Will create a new file."
      touch "$ORIGINAL_FILE" || {
          echo "Error: Failed to create $ORIGINAL_FILE"
          return 1
      }
      return 0
  fi

  TIMESTAMP=$(date +"%Y%m%d%H%M%S")
  BACKUP_FILE="${ORIGINAL_FILE}.bak.$TIMESTAMP"
  cp "$ORIGINAL_FILE" "$BACKUP_FILE" || {
      echo "Error: Failed to back up $ORIGINAL_FILE"
      return 1
  }

  echo "Successfully backed up $ORIGINAL_FILE to $BACKUP_FILE"
  return 0
}

# Function for initial setup
initial_setup() {
  echo -e "${BLUE}Performing initial setup...${NC}"

  # Enable quotas
  enable_quotas

  # Install other required packages
  echo "Installing required packages..."
  for pkg in bind bind-utils nfs-utils samba chrony rsync clamav clamd clamav-update httpd php mod_ssl; do
    install_if_missing "$pkg"
  done

  # Enable Cockpit if available
  if command -v cockpit &>/dev/null; then
    systemctl enable --now cockpit.socket
  fi

  # Configure permissive firewall defaults if firewalld is active
  if systemctl is-active --quiet firewalld; then
    echo "Configuring firewall with permissive defaults..."
    firewall-cmd --set-default-zone=public
    firewall-cmd --permanent --zone=public --add-service=ssh
    firewall-cmd --permanent --zone=public --add-service=http
    firewall-cmd --permanent --zone=public --add-service=https
    firewall-cmd --permanent --zone=public --add-service=ftp
    firewall-cmd --reload
  fi

  echo -e "${GREEN}Initial setup completed.${NC}"
  echo "Press any key to continue..."
  read -n 1 -s
}

# Function to enable disk quotas
enable_quotas() {
  echo -e "${BLUE}Enabling disk quotas...${NC}"

  # Install quota packages
  install_if_missing quota

  # Check if we have any active file systems where we can enable quotas
  if [ -f "/etc/fstab" ]; then
    # Backup fstab before modifying
    cp /etc/fstab /etc/fstab.bak

    # Add quota options to mount points in fstab
    # First check if /home is a separate partition
    if grep -q " /home " /etc/fstab; then
      sed -i 's|\( /home .*defaults\)|\1,usrquota,grpquota|' /etc/fstab
    else
      echo "No separate /home partition found, adding quota to root partition"
      # If /home is not a separate partition, add quota to the root partition
      sed -i 's|\( / .*defaults\)|\1,usrquota,grpquota|' /etc/fstab
    fi

    # Add quota options to /srv if it exists as a separate partition
    if grep -q " /srv " /etc/fstab; then
      sed -i 's|\( /srv .*defaults\)|\1,usrquota,grpquota|' /etc/fstab
    else
      echo "No separate /srv partition found, quotas for /srv will use root partition"
    fi

    echo "Modified /etc/fstab to enable quotas"
  else
    echo -e "${RED}Error: /etc/fstab not found. Cannot configure quotas.${NC}"
    echo "Press any key to continue..."
    read -n 1 -s
    return 1
  fi

  # Remount file systems with quota options
  echo "Remounting file systems with quota options..."
  mount -o remount /
  if grep -q " /home " /etc/fstab; then
    mount -o remount /home
  fi
  if grep -q " /srv " /etc/fstab; then
    mount -o remount /srv
  fi

  # Create quota files
  echo "Creating quota database files..."
  quotacheck -cugm / 2>/dev/null || echo "Warning: quotacheck on / returned non-zero exit code"
  if grep -q " /home " /etc/fstab; then
    quotacheck -cugm /home 2>/dev/null || echo "Warning: quotacheck on /home returned non-zero exit code"
  fi
  if grep -q " /srv " /etc/fstab; then
    quotacheck -cugm /srv 2>/dev/null || echo "Warning: quotacheck on /srv returned non-zero exit code"
  fi

  # Turn on quotas
  echo "Turning on quotas..."
  quotaon -v / 2>/dev/null || echo "Warning: quotaon on / returned non-zero exit code"
  if grep -q " /home " /etc/fstab; then
    quotaon -v /home 2>/dev/null || echo "Warning: quotaon on /home returned non-zero exit code"
  fi
  if grep -q " /srv " /etc/fstab; then
    quotaon -v /srv 2>/dev/null || echo "Warning: quotaon on /srv returned non-zero exit code"
  fi

  echo -e "${GREEN}Disk quotas enabled.${NC}"
  echo "Press any key to continue..."
  read -n 1 -s
}
