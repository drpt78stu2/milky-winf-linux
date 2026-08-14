#!/usr/bin/env bash
# test_iso.sh
#
# Test a previously built ISO, either by booting it in QEMU or by
# writing it to a physical USB drive.
#
# Usage:
#   ./test_iso.sh <path-to-iso> [qemu|usb] [extra args...]
#
# Modes:
#   qemu   Boot the ISO in QEMU. Any extra args are passed straight
#          through to qemu-system-x86_64.
#            ./test_iso.sh image.iso qemu -m 4096
#
#   usb    Burn the ISO to a USB block device. Optionally pass the
#          device as the next arg; otherwise you'll be prompted.
#            ./test_iso.sh image.iso usb /dev/sdb
#
# If no mode is given and the shell is interactive, you'll be asked
# which one to use. In a non-interactive shell with no mode given,
# it defaults to qemu.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <path-to-iso> [qemu|usb] [extra args...]"
    exit 1
fi

ISO_PATH="$1"
shift

if [ ! -f "$ISO_PATH" ]; then
    echo "ERROR: ISO file not found: $ISO_PATH"
    exit 1
fi

MODE=""
if [ $# -ge 1 ] && { [ "$1" = "qemu" ] || [ "$1" = "usb" ]; }; then
    MODE="$1"
    shift
fi

if [ -z "$MODE" ]; then
    if [ -t 0 ]; then
        read -r -p "==> Test via [Q]EMU or burn to [U]SB? [Q/u] " MODE_ANSWER || MODE_ANSWER=""
        case "$MODE_ANSWER" in
            [Uu]|[Uu][Ss][Bb]) MODE="usb" ;;
            *) MODE="qemu" ;;
        esac
    else
        echo "==> Non-interactive shell and no mode specified — defaulting to qemu."
        MODE="qemu"
    fi
fi

run_qemu() {
    if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
        echo "ERROR: qemu-system-x86_64 not found. Install the 'qemu-full' package first."
        exit 1
    fi

    local ram_mb=2048
    local cpus=2
    local kvm_args=()
    local boot_log="${ISO_PATH}.bootlog.txt"

    if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        kvm_args=(-enable-kvm -cpu host)
    else
        echo "==> /dev/kvm not available or not accessible — falling back to software emulation (slower)."
    fi

    echo "==> Booting '$ISO_PATH' in QEMU (${ram_mb}MB RAM, ${cpus} CPUs)..."
    echo "==> Full boot log (kernel + init) will be saved to: $boot_log"
    qemu-system-x86_64 \
        -machine q35 \
        -m "$ram_mb" \
        -smp "$cpus" \
        "${kvm_args[@]}" \
        -cdrom "$ISO_PATH" \
        -boot d \
        -serial "file:$boot_log" \
        "$@"

    echo "==> QEMU exited. Boot log saved to: $boot_log"

    echo "==> Scanning boot log for failures/errors..."
    if grep -i -E 'fail|error' "$boot_log"; then
        echo "==> ^ found in: $boot_log"
    else
        echo "==> No 'fail'/'error' lines found in $boot_log"
    fi
}

run_usb_burn() {
    local device="${1:-}"

    if [ -z "$device" ]; then
        if [ -t 0 ]; then
            read -r -p "Enter target USB device (e.g. /dev/sdb) — ALL DATA ON IT WILL BE ERASED: " device
        else
            echo "ERROR: usb mode requires a device path when running non-interactively."
            exit 1
        fi
    fi

    if [ ! -b "$device" ]; then
        echo "ERROR: '$device' is not a block device."
        exit 1
    fi

    echo "WARNING: this will ERASE ALL DATA on $device."
    read -r -p "Type 'yes' to confirm: " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 1
    fi

    echo "==> Writing '$ISO_PATH' to $device ..."
    sudo dd if="$ISO_PATH" of="$device" bs=4M status=progress oflag=sync
    sync
    echo "==> Done. You can now boot from $device."
}

case "$MODE" in
    qemu)
        run_qemu "$@"
        ;;
    usb)
        run_usb_burn "$@"
        ;;
    *)
        echo "ERROR: unknown mode '$MODE' (expected qemu or usb)."
        exit 1
        ;;
esac
