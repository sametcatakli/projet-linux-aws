#!/bin/bash

# Check if dnf is available (for compatibility with newer systems)
if command -v dnf &> /dev/null; then
    PACKAGE_MANAGER="dnf"
else
    PACKAGE_MANAGER="yum"
fi

# Install firewalld if not already installed using dnf or yum
sudo $PACKAGE_MANAGER install -y firewalld

# Start and enable firewalld service
sudo systemctl start firewalld
sudo systemctl enable firewalld

# Set default zone to drop all incoming traffic (this blocks all ports by default)
sudo firewall-cmd --set-default-zone=drop

# Allow SSH (port 22)
sudo firewall-cmd --zone=public --add-port=22/tcp --permanent

# Allow HTTP (port 80)
sudo firewall-cmd --zone=public --add-port=80/tcp --permanent

# Allow HTTPS (port 443)
sudo firewall-cmd --zone=public --add-port=443/tcp --permanent

# Allow Samba (ports 137-139, 445)
sudo firewall-cmd --zone=public --add-port=137/udp --permanent
sudo firewall-cmd --zone=public --add-port=138/udp --permanent
sudo firewall-cmd --zone=public --add-port=139/tcp --permanent
sudo firewall-cmd --zone=public --add-port=445/tcp --permanent

# Allow DNS (port 53)
sudo firewall-cmd --zone=public --add-port=53/tcp --permanent
sudo firewall-cmd --zone=public --add-port=53/udp --permanent

# Allow NTP (port 123)
sudo firewall-cmd --zone=public --add-port=123/udp --permanent

# Allow Cockpit (port 9090)
sudo firewall-cmd --zone=public --add-port=9090/tcp --permanent

# Allow NFS (ports 2049, 111, 20048, and 4045)
sudo firewall-cmd --zone=public --add-port=2049/tcp --permanent
sudo firewall-cmd --zone=public --add-port=2049/udp --permanent
sudo firewall-cmd --zone=public --add-port=111/tcp --permanent
sudo firewall-cmd --zone=public --add-port=111/udp --permanent
sudo firewall-cmd --zone=public --add-port=20048/tcp --permanent
sudo firewall-cmd --zone=public --add-port=20048/udp --permanent
sudo firewall-cmd --zone=public --add-port=4045/tcp --permanent
sudo firewall-cmd --zone=public --add-port=4045/udp --permanent

# Allow FTP (port 21)
sudo firewall-cmd --zone=public --add-port=21/tcp --permanent

# Allow port 8000
sudo firewall-cmd --zone=public --add-port=8000/tcp --permanent

# Reload the firewall to apply changes
sudo firewall-cmd --reload

# Confirm the active firewall rules
sudo firewall-cmd --list-all
