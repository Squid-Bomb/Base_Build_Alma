#!/bin/bash

# ==============================================================================
# USB Imager
# Usage: sudo ./write-usb.sh
# ==============================================================================

ISO_FILE="almalinux-10-lab-server-auto.iso"

# 1. Root Check
if [[ $EUID -ne 0 ]]; then
   echo "❌ Error: This script must be run as root or with sudo."
   exit 1
fi

# 2. ISO Check
if [[ ! -f "$ISO_FILE" ]]; then
    echo "❌ Error: ISO file '$ISO_FILE' not found in the current directory."
    exit 1
fi

# 3. Discover USB Devices
echo "🔍 Scanning for removable USB drives..."
echo "------------------------------------------------------"
lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -i "usb"
if [ $? -ne 0 ]; then
    echo "⚠️  No USB drives detected by lsblk. Please plug one in and try again."
    exit 1
fi
echo "------------------------------------------------------"

# 4. Target Selection
read -p "🎯 Enter the target USB device name (e.g., sdb, sdc) OR press Ctrl+C to abort: " TARGET_DEV
TARGET_DEV="${TARGET_DEV,,}"
TARGET_PATH="/dev/$TARGET_DEV"

if [[ ! -b "$TARGET_PATH" ]]; then
    echo "❌ Error: Device $TARGET_PATH does not exist or is not a valid block device."
    exit 1
fi

# 5. Safety Failsafe (Prevent writing to NVMe/SATA)
DRIVE_TRAN=$(lsblk -n -d -o TRAN "$TARGET_PATH" 2>/dev/null)
if [[ "$DRIVE_TRAN" != "usb" ]]; then
    echo "❌ WARNING: $TARGET_PATH does not appear to be a USB drive (Transport: $DRIVE_TRAN)!"
    echo "Aborting for safety to prevent overwriting internal storage."
    exit 1
fi

# 6. Final Confirmation
echo "⚠️  WARNING: ALL DATA ON $TARGET_PATH WILL BE DESTROYED."
read -p "Type 'YES' to format and image this drive: " CONFIRM

if [[ "${CONFIRM^^}" != "YES" ]]; then
    echo "🚫 Aborted."
    exit 1
fi

# 7. Unmount and Write
echo "🧹 Unmounting any active partitions on $TARGET_PATH..."
umount ${TARGET_PATH}* 2>/dev/null

echo "💿 Writing $ISO_FILE to $TARGET_PATH..."
echo "⏳ This may take a few minutes depending on your USB write speed."

# Using oflag=sync ensures data is physically written before the command finishes
dd if="$ISO_FILE" of="$TARGET_PATH" bs=4M status=progress oflag=sync

echo "✅ Success! The USB drive is ready for bare-metal deployment."
