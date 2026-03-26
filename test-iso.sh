#!/bin/bash
set -euo pipefail

# ==============================================================================
# KVM ISO Test Script
# Usage: ./test-iso.sh [--headless]   (default: GUI via SPICE)
# ==============================================================================

ISO_FILE="almalinux-10-lab-server-auto.iso"
DISK_IMG="almalinux-test-disk.qcow2"
OVMF_VARS_COPY="ovmf-vars-copy.fd"
DISK_SIZE="40G"
RAM="4096"
CPUS="4"
SPICE_PORT="5930"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

die() { echo "❌ Error: $*" >&2; exit 1; }

find_file() {
    for path in "$@"; do [[ -f "$path" ]] && echo "$path" && return 0; done
    return 1
}

find_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || [[ -x "$cmd" ]] && echo "$cmd" && return 0
    done
    return 1
}

pkg_install() {
    if command -v dnf &>/dev/null; then
        sudo dnf install -y "$@"
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y "$@"
    else
        die "No supported package manager. Install manually: $*"
    fi
}

VIEWER_PID=""

cleanup() {
    echo -e "\n🛑 VM shutdown detected."
    echo "🧹 Deleting temporary files..."
    rm -f "$DISK_IMG" "$OVMF_VARS_COPY"
    [[ -n "$VIEWER_PID" ]] && kill "$VIEWER_PID" 2>/dev/null || true
    echo "✅ Test environment cleared."
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Mode
# ------------------------------------------------------------------------------

if [[ "${1:-}" == "--headless" ]]; then
    DISPLAY_ARGS=(-nographic -serial stdio)
    GUI_MODE=false
    echo "⚙️  Mode: HEADLESS (Ctrl+A then X to quit)"
else
    DISPLAY_ARGS=(-display none -vga std -spice port=${SPICE_PORT},disable-ticketing=on)
    GUI_MODE=true
    echo "⚙️  Mode: GUI via SPICE — auto-launching viewer on port ${SPICE_PORT}"
fi

echo "🚀 Starting test environment..."

# ------------------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------------------

[[ -e /dev/kvm ]]          || die "/dev/kvm not found. Load KVM modules: modprobe kvm_intel (or kvm_amd)"
[[ -r /dev/kvm && -w /dev/kvm ]] || die "/dev/kvm not accessible. Run: sudo usermod -aG kvm \$USER"

if ! QEMU_CMD=$(find_cmd qemu-kvm /usr/libexec/qemu-kvm qemu-system-x86_64); then
    echo "📦 Installing QEMU..."
    pkg_install qemu-kvm qemu-img edk2-ovmf
    QEMU_CMD=$(find_cmd qemu-kvm /usr/libexec/qemu-kvm qemu-system-x86_64) \
        || die "QEMU binary not found after install."
fi
[[ "$QEMU_CMD" == *qemu-system-x86_64* ]] && EXTRA_KVM=(-enable-kvm) || EXTRA_KVM=()
echo "🔧 QEMU: $QEMU_CMD"

OVMF_PATHS=(
    /usr/share/edk2/ovmf/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
)
if ! OVMF_CODE=$(find_file "${OVMF_PATHS[@]}"); then
    echo "📦 Installing OVMF..."
    pkg_install edk2-ovmf
    OVMF_CODE=$(find_file "${OVMF_PATHS[@]}") || die "OVMF_CODE.fd not found after install."
fi

OVMF_VARS_PATHS=(
    /usr/share/edk2/ovmf/OVMF_VARS.fd
    /usr/share/OVMF/OVMF_VARS.fd
    /usr/share/edk2-ovmf/x64/OVMF_VARS.fd
)
if OVMF_VARS_TEMPLATE=$(find_file "${OVMF_VARS_PATHS[@]}"); then
    cp "$OVMF_VARS_TEMPLATE" "$OVMF_VARS_COPY"
    PFLASH_ARGS=(
        -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}"
        -drive "if=pflash,format=raw,file=${OVMF_VARS_COPY}"
    )
else
    echo "⚠️  OVMF_VARS.fd not found — UEFI variables will not persist."
    OVMF_VARS_COPY=""
    PFLASH_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}")
fi

[[ -f "$ISO_FILE" ]] || die "ISO not found: $ISO_FILE"

# ------------------------------------------------------------------------------
# Run
# ------------------------------------------------------------------------------

echo "💾 Creating ${DISK_SIZE} disk image (${DISK_IMG})..."
qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE"

if [[ "$GUI_MODE" == true ]]; then
    (sleep 2 && remote-viewer "spice://localhost:${SPICE_PORT}") &
    VIEWER_PID=$!
fi

"$QEMU_CMD" \
    -machine q35 \
    "${EXTRA_KVM[@]}" \
    -cpu host \
    -m "$RAM" \
    -smp "$CPUS" \
    "${PFLASH_ARGS[@]}" \
    -cdrom "$ISO_FILE" \
    -drive "file=${DISK_IMG},format=qcow2,if=none,id=DISK0" \
    -device virtio-blk-pci,drive=DISK0 \
    -boot once=d \
    "${DISPLAY_ARGS[@]}" \
    -netdev "user,id=net0,hostfwd=tcp::2222-:22" \
    -device virtio-net-pci,netdev=net0
