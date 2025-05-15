#!/bin/bash

# Hardware management menu
hardware_menu() {
  while true; do
    clear
    echo ""
    echo "|----------------------------------------------------------------------|"
    echo -e "|                 ${BLUE}Hardware Management Menu ${NC}                           |"
    echo "|----------------------------------------------------------------------|"
    echo "| 1. RAID Configuration                                                |"
    echo "| 2. Backup to S3                                          |"
    echo "|----------------------------------------------------------------------|"
    echo "| q. Back to Main Menu                                                 |"
    echo "|----------------------------------------------------------------------|"
    echo ""
    read -p "Enter your choice: " hardware_choice
    case $hardware_choice in
      1) raid ;;
      2) backup ;;
      q|Q) clear && break ;;
      *) clear && echo "Invalid choice. Please enter a valid option." ;;
    esac
  done
}

# RAID Configuration function
raid() {
  clear
  echo "=== Starting RAID 1 + LVM Setup ==="

  # Verify root privileges
  if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
  fi

  # Package Installation
  echo "--- Installing required packages ---"
  dnf install -y mdadm lvm2 gdisk

  # Disk Preparation
  # List of disks to use for RAID
  DISKS=("/dev/nvme1n1" "/dev/nvme2n1")

  echo "--- Verifying disks ---"
  for disk in "${DISKS[@]}"; do
    if [ ! -b "$disk" ]; then
      echo "ERROR: Disk $disk not found!"
      echo "Available disks:"
      lsblk
      echo "Please press any key to continue with available disks or Ctrl+C to abort"
      read -n 1
      # If specified disks aren't available, try to use standard ones
      DISKS=("/dev/sdb" "/dev/sdc")
      break
    fi
  done

  echo "--- Wiping disks ---"
  for disk in "${DISKS[@]}"; do
    echo "Cleaning $disk:"
    # Remove existing RAID signatures
    echo " - Removing RAID signatures"
    mdadm --zero-superblock $disk 2>/dev/null || true
    # Zap GPT and MBR partitions
    echo " - Zapping partition tables"
    sgdisk --zap-all $disk || true
    dd if=/dev/zero of=$disk bs=1M count=10 status=none || true
    # Wipe filesystem signatures
    echo " - Wiping filesystems"
    wipefs -a $disk || true
  done

  # RAID Configuration
  echo "--- Creating RAID 1 array ---"
  mdadm --create --verbose /dev/md0 \
    --level=1 \
    --raid-devices=2 \
    --metadata=1.2 \
    --bitmap=internal \
    --force \
    "${DISKS[@]}"

  echo "--- Monitoring RAID sync ---"
  echo "Waiting for RAID to initialize..."
  sleep 5

  # Persist RAID config
  echo "--- Saving RAID configuration ---"
  mkdir -p /etc/mdadm
  echo "DEVICE partitions" > /etc/mdadm/mdadm.conf
  mdadm --detail --scan >> /etc/mdadm/mdadm.conf

  # LVM Configuration
  echo "--- Setting up LVM ---"
  # Create physical volume
  pvcreate --zero y /dev/md0
  # Create volume group
  vgcreate vg_raid /dev/md0

  # Create logical volumes for share and web
  echo "--- Creating logical volumes ---"
  # Determine the size of the VG (in extents)
  VG_SIZE=$(vgdisplay vg_raid | grep "Total PE" | awk '{print $3}')
  # Allocate 40% to share and 40% to web (leaving 20% free space)
  SHARE_SIZE=$((VG_SIZE * 40 / 100))
  WEB_SIZE=$((VG_SIZE * 40 / 100))

  lvcreate -l $SHARE_SIZE -n share vg_raid
  lvcreate -l $WEB_SIZE -n web vg_raid

  # Format filesystems
  echo "--- Creating filesystems ---"
  mkfs.ext4 -O quota,project -j /dev/vg_raid/share
  mkfs.ext4 -O quota,project -j /dev/vg_raid/web

  # Mount Configuration
  echo "--- Configuring mount points ---"
  mkdir -p /srv/share
  mkdir -p /srv/web

  mount -o usrquota,grpquota /dev/vg_raid/share /srv/share
  mount -o usrquota,grpquota /dev/vg_raid/web /srv/web

  # Modify fstab for persistence
  echo "--- Configuring fstab ---"
  # Remove existing entries for these mount points
  sed -i '/\/srv\/share/d' /etc/fstab
  sed -i '/\/srv\/web/d' /etc/fstab

  # Add new entries
  echo "# RAID array mounts" >> /etc/fstab
  echo "/dev/vg_raid/share /srv/share ext4 defaults,usrquota,grpquota,nofail 0 2" >> /etc/fstab
  echo "/dev/vg_raid/web /srv/web ext4 defaults,usrquota,grpquota,nofail 0 2" >> /etc/fstab

  # Create symlinks to maintain compatibility with the rest of the script
  ln -sf /srv/share /mnt/raid5_share
  ln -sf /srv/web /mnt/raid5_web

  # Initialize quota on the mounted filesystems
  echo "--- Initializing quotas ---"
  quotacheck -cugm /srv/share
  quotacheck -cugm /srv/web
  quotaon -v /srv/share
  quotaon -v /srv/web

  # Verification
  echo "--- Verification ---"
  echo "1. RAID Status:"
  mdadm --detail /dev/md0

  echo "2. LVM Status:"
  lvs

  echo "3. Mount Status:"
  df -h | grep /srv

  echo "=== RAID 1 Setup Complete ==="
  echo "Press any key to continue..."
  read -n 1 -s key
}

# Backup function
backup(){


}
