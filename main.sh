#!/bin/bash

# Include other script modules
source ./scripts/common.sh
source ./scripts/hardware.sh
source ./scripts/network.sh
source ./scripts/security.sh
source ./scripts/webservices.sh
source ./scripts/filesharing.sh
source ./scripts/usermanagement.sh
source ./scripts/monitoring.sh

# Check if running with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo"
  exit 1
fi

# Display the main menu
display_main_menu() {
  clear
  echo ""
  echo "|----------------------------------------------------------------------|"
  echo -e "|                 ${BLUE}Welcome to the server assistant ${NC}                     |"
  echo "|              Please select the tool you want to use                  |"
  echo "|----------------------------------------------------------------------|"
  echo "| 1. Hardware Management                                               |"
  echo "| 2. Network Services                                                  |"
  echo "| 3. Security                                                          |"
  echo "| 4. Web Services                                                      |"
  echo "| 5. File Sharing                                                      |"
  echo "| 6. User Management                                                   |"
  echo "| 7. Monitoring                                                        |"
  echo "|----------------------------------------------------------------------|"
  echo "| q. Quit                                                              |"
  echo "|----------------------------------------------------------------------|"
  echo ""
}

# Main function
main() {
  # Create scripts directory if it doesn't exist
  mkdir -p ./scripts

  # Run initial setup first
  initial_setup

  while true; do
    display_main_menu
    read -p "Enter your choice: " choice
    case $choice in
      1) hardware_menu ;;
      2) network_menu ;;
      3) security_menu ;;
      4) web_services_menu ;;
      5) file_sharing_menu ;;
      6) user_management_menu ;;
      7) monitoring_menu ;;
      q|Q) clear && echo "Exiting the server configuration wizard." && exit ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# Start the script
main
