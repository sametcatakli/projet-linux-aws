#!/bin/bash

# Check if dnf is available (for compatibility with newer systems)
if command -v dnf &> /dev/null; then
    PACKAGE_MANAGER="dnf"
else
    echo "dnf is not available on your system. This script requires dnf to work."
    exit 1
fi

# Update the system
echo "Updating the system..."
sudo $PACKAGE_MANAGER update -y

# Install necessary packages (Samba and related dependencies)
echo "Installing Samba and required packages..."
sudo $PACKAGE_MANAGER install -y samba samba-client samba-common

# Start and enable Samba services
echo "Starting and enabling Samba services..."
sudo systemctl start smb
sudo systemctl start nmb
sudo systemctl enable smb
sudo systemctl enable nmb

# Create a directory to share via Samba
echo "Creating the Samba share directory..."
sudo mkdir -p /srv/samba/share
sudo chmod -R 0777 /srv/samba/share

# Add a Samba user (replace 'sambauser' with the desired username)
echo "Adding a Samba user..."
sudo useradd sambauser
echo "Set password for sambauser:"
sudo smbpasswd -a sambauser
sudo smbpasswd -e sambauser

# Configure Samba (adding a new share)
echo "Configuring Samba share..."
echo "[sambashare]
path = /srv/samba/share
valid users = sambauser
read only = no
browsable = yes" | sudo tee -a /etc/samba/smb.conf

# Restart Samba services to apply changes
echo "Restarting Samba services..."
sudo systemctl restart smb
sudo systemctl restart nmb

# Display Samba status
echo "Samba server is set up successfully!"
sudo systemctl status smb
sudo systemctl status nmb

# Confirm the Samba share is accessible
echo "The Samba share is accessible at: smb://<your-server-ip>/sambashare"
