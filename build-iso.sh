#!/bin/bash
set -euo pipefail

# ==============================================================================
# AlmaLinux 10 ISO Auto-Builder
# Usage: ./build-iso.sh [--headless]   (default: GUI installer)
# Note:  Output ISO is written to the directory you invoke this script from.
# ==============================================================================

ORIGINAL_ISO="AlmaLinux-10-latest-x86_64-dvd.iso"
ALMA_DOWNLOAD_URL="https://repo.almalinux.org/almalinux/10/isos/x86_64/AlmaLinux-10-latest-x86_64-dvd.iso"
ALMA_CHECKSUM_URL="https://repo.almalinux.org/almalinux/10/isos/x86_64/CHECKSUM"
KICKSTART_FILE="ks.cfg"
NEW_ISO="almalinux-10-lab-server-auto.iso"
VOL_LABEL="ALMA-10-AUTO"
OUTPUT_DIR=$(pwd)
WORKING_DIR="./tmp/alma-iso-build"
MOUNT_DIR=""

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

die() { echo "❌ Error: $*" >&2; exit 1; }

cleanup() {
    if [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount "$MOUNT_DIR"
    fi
    [[ -n "$MOUNT_DIR" ]] && rm -rf "$MOUNT_DIR"
    rm -rf "$WORKING_DIR"
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Mode
# ------------------------------------------------------------------------------

if [[ "${1:-}" == "--headless" ]]; then
    BOOT_APPEND="inst.ks=hd:LABEL=$VOL_LABEL:/ks.cfg console=ttyS0,115200 inst.text"
    echo "⚙️  Build Mode: HEADLESS (Serial Console)"
else
    BOOT_APPEND="inst.ks=hd:LABEL=$VOL_LABEL:/ks.cfg"
    echo "⚙️  Build Mode: GUI (Graphical Installer)"
fi

[[ $EUID -eq 0 ]] || die "This script must be run as root or with sudo."

# ------------------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------------------

if ! command -v xorriso &>/dev/null || ! command -v implantisomd5 &>/dev/null || ! command -v rsync &>/dev/null; then
    echo "📦 Installing prerequisites..."
    if command -v dnf &>/dev/null; then
        dnf install -y xorriso rsync isomd5sum
    elif command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y xorriso rsync isomd5sum
    else
        die "No supported package manager found. Install xorriso, rsync, and isomd5sum manually."
    fi
fi

# ------------------------------------------------------------------------------
# Source ISO
# ------------------------------------------------------------------------------

if [[ ! -f "$ORIGINAL_ISO" ]]; then
    echo "📥 Downloading AlmaLinux 10 ISO..."
    if command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$ORIGINAL_ISO" "$ALMA_DOWNLOAD_URL"
    elif command -v wget &>/dev/null; then
        wget --progress=bar:force -O "$ORIGINAL_ISO" "$ALMA_DOWNLOAD_URL"
    else
        die "Neither curl nor wget found. Cannot download ISO."
    fi
    [[ -f "$ORIGINAL_ISO" ]] || die "Download produced no file."
    echo "✅ Download complete: $ORIGINAL_ISO"
fi

echo "🔒 Verifying ISO checksum..."
CHECKSUM_FILE=$(mktemp)
if command -v curl &>/dev/null; then
    curl -sL -o "$CHECKSUM_FILE" "$ALMA_CHECKSUM_URL"
else
    wget -q -O "$CHECKSUM_FILE" "$ALMA_CHECKSUM_URL"
fi
# AlmaLinux CHECKSUM files use BSD format: SHA256 (filename) = hash
if grep -q "$ORIGINAL_ISO" "$CHECKSUM_FILE"; then
    EXPECTED=$(grep "SHA256.*$ORIGINAL_ISO" "$CHECKSUM_FILE" | awk '{print $NF}')
    ACTUAL=$(sha256sum "$ORIGINAL_ISO" | awk '{print $1}')
    [[ "$EXPECTED" == "$ACTUAL" ]] || die "Checksum mismatch — re-download the ISO and try again."
    echo "✅ Checksum verified."
else
    echo "⚠️  No checksum entry found for $ORIGINAL_ISO — skipping verification."
fi
rm -f "$CHECKSUM_FILE"

# ------------------------------------------------------------------------------
# Extract ISO
# ------------------------------------------------------------------------------

[[ -f "$KICKSTART_FILE" ]] || die "$KICKSTART_FILE not found."

rm -rf "$WORKING_DIR"
mkdir -p "$WORKING_DIR"
MOUNT_DIR=$(mktemp -d)

echo "💿 Mounting and extracting original ISO..."
mount -o loop,ro "$ORIGINAL_ISO" "$MOUNT_DIR" || die "Failed to mount $ORIGINAL_ISO."
rsync -a "$MOUNT_DIR/" "$WORKING_DIR/"
umount "$MOUNT_DIR"
rm -rf "$MOUNT_DIR"
MOUNT_DIR=""

# ------------------------------------------------------------------------------
# Inject kickstart
# ------------------------------------------------------------------------------

echo "📄 Injecting kickstart file..."
cp "$KICKSTART_FILE" "$WORKING_DIR/ks.cfg"

# ------------------------------------------------------------------------------
# Patch boot menus
# ------------------------------------------------------------------------------

echo "🔧 Patching boot menus..."

# Legacy BIOS (ISOLINUX)
if [[ -f "$WORKING_DIR/isolinux/isolinux.cfg" ]]; then
    sed -E -i "s|inst\.stage2=[^ ]+|inst.stage2=hd:LABEL=$VOL_LABEL|g" "$WORKING_DIR/isolinux/isolinux.cfg"
    sed -i "s|inst.stage2=hd:LABEL=$VOL_LABEL|inst.stage2=hd:LABEL=$VOL_LABEL $BOOT_APPEND|g" "$WORKING_DIR/isolinux/isolinux.cfg"
    sed -i 's/^timeout [0-9]*/timeout 5/' "$WORKING_DIR/isolinux/isolinux.cfg"
    sed -i '/menu default/d' "$WORKING_DIR/isolinux/isolinux.cfg"
    sed -i '/label linux/a \  menu default' "$WORKING_DIR/isolinux/isolinux.cfg"
fi

# UEFI (GRUB)
if [[ -f "$WORKING_DIR/EFI/BOOT/grub.cfg" ]]; then
    sed -E -i "s|inst\.stage2=[^ ]+|inst.stage2=hd:LABEL=$VOL_LABEL|g" "$WORKING_DIR/EFI/BOOT/grub.cfg"
    sed -i "s|inst.stage2=hd:LABEL=$VOL_LABEL|inst.stage2=hd:LABEL=$VOL_LABEL $BOOT_APPEND|g" "$WORKING_DIR/EFI/BOOT/grub.cfg"
    sed -i 's/^set timeout=[0-9]*/set timeout=5/' "$WORKING_DIR/EFI/BOOT/grub.cfg"
    sed -E -i 's/^set default="?[0-9]+"?$/set default=0/' "$WORKING_DIR/EFI/BOOT/grub.cfg"
fi

# ------------------------------------------------------------------------------
# Rebuild ISO
# ------------------------------------------------------------------------------

echo "🏗️  Rebuilding hybrid ISO..."

XORRISO_ARGS=(-as mkisofs -o "$OUTPUT_DIR/$NEW_ISO" -V "$VOL_LABEL" -J -R)
if [[ -f "$WORKING_DIR/isolinux/isolinux.bin" ]]; then
    XORRISO_ARGS+=(-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table)
fi
if [[ -f "$WORKING_DIR/images/efiboot.img" ]]; then
    [[ -f "$WORKING_DIR/isolinux/isolinux.bin" ]] && XORRISO_ARGS+=(-eltorito-alt-boot)
    XORRISO_ARGS+=(-e images/efiboot.img -no-emul-boot -isohybrid-gpt-basdat)
fi

xorriso "${XORRISO_ARGS[@]}" "$WORKING_DIR"

echo "🔒 Implanting MD5 checksum..."
implantisomd5 "$OUTPUT_DIR/$NEW_ISO"

echo "✅ Success! ISO is ready: $OUTPUT_DIR/$NEW_ISO"
