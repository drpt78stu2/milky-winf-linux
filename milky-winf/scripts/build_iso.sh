#!/usr/bin/env bash
# build_iso.sh
#
# Run this FROM INSIDE your existing kernel source directory.

set -euo pipefail

# Resolve this script's directory as an absolute path up front, before
# anything below has a chance to cd elsewhere (e.g. into the initramfs
# staging dir) and break a relative invocation path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/test_iso.sh"

BUILD_MODE=""
THREADS="$(nproc)"
INCLUDE_DIR=""

for arg in "$@"; do
    if [ "$arg" = "fullfromscratch" ]; then
        BUILD_MODE="fullfromscratch"
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        THREADS="$arg"
    elif [[ "$arg" == includedir=* ]]; then
        INCLUDE_DIR="${arg#includedir=}"
    else
        echo "WARNING: unrecognized argument '$arg' — ignoring."
    fi
done

if [ -n "$INCLUDE_DIR" ] && [ ! -d "$INCLUDE_DIR" ]; then
    echo "ERROR: includedir path '$INCLUDE_DIR' does not exist or is not a directory."
    exit 1
fi

echo "==> Using $THREADS thread(s) for compilation"
START_TIME=$(date +%s)

if [ ! -f "Makefile" ] || [ ! -d "kernel" ] || [ ! -d "arch" ]; then
    echo "ERROR: This doesn't look like a Linux kernel source directory."
    exit 1
fi

SRC_DIR="$(pwd)"
WORKDIR="$HOME/kernel-build"
mkdir -p "$WORKDIR"

if [ "$BUILD_MODE" = "fullfromscratch" ]; then
    echo "==> Wiping build artifacts..."
    make mrproper
fi

echo "==> Installing build dependencies"
sudo pacman -Syu --needed --noconfirm \
    base-devel ncurses bison flex openssl libelf bc cpio \
    grub xorriso mtools busybox ccache squashfs-tools arch-install-scripts pv qemu-full

export PATH="/usr/lib/ccache/bin:$PATH"
export CCACHE_DIR="$HOME/.ccache"
ccache -M 2G >/dev/null

echo "==> Configuring kernel..."
if [ -f ".config" ]; then
    make olddefconfig
elif zcat /proc/config.gz > .config 2>/dev/null; then
    make olddefconfig
else
    make defconfig
fi

make localmodconfig

echo "==> Enforcing required filesystems, display drivers, storage, and wireless support..."
# Filesystem & Overlay support for Live ISO
scripts/config --enable CONFIG_SQUASHFS
scripts/config --enable CONFIG_SQUASHFS_ZLIB
scripts/config --enable CONFIG_SQUASHFS_XZ
scripts/config --enable CONFIG_ISO9660_FS
scripts/config --enable CONFIG_BLK_DEV_LOOP
scripts/config --enable CONFIG_OVERLAY_FS

# FAT / vFAT / exFAT USB Support
scripts/config --enable CONFIG_FAT_FS
scripts/config --enable CONFIG_VFAT_FS
scripts/config --enable CONFIG_EXFAT_FS
scripts/config --enable CONFIG_NLS_CODEPAGE_437
scripts/config --enable CONFIG_NLS_ISO8859_1

# Display / Framebuffer support
scripts/config --enable CONFIG_FB
scripts/config --enable CONFIG_FB_EFI
scripts/config --enable CONFIG_FB_VESA
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
scripts/config --enable CONFIG_DRM_FBDEV_EMULATION

# Core USB & SCSI drivers (CONFIG_USB_UAS for USB 3.0/3.2 drives)
scripts/config --enable CONFIG_USB
scripts/config --enable CONFIG_USB_SUPPORT
scripts/config --enable CONFIG_USB_XHCI_HCD
scripts/config --enable CONFIG_USB_EHCI_HCD
scripts/config --enable CONFIG_USB_OHCI_HCD
scripts/config --enable CONFIG_USB_STORAGE
scripts/config --enable CONFIG_USB_UAS
scripts/config --enable CONFIG_SCSI
scripts/config --enable CONFIG_BLK_DEV_SD
scripts/config --enable CONFIG_BLK_DEV_SR

# Storage controllers for modern laptops
scripts/config --enable CONFIG_ATA
scripts/config --enable CONFIG_SATA_AHCI
scripts/config --enable CONFIG_BLK_DEV_NVME

# Legacy IDE controller (e.g. QEMU's default machine type, older hardware)
scripts/config --enable CONFIG_ATA_PIIX

# Serial console support (for capturing boot logs during testing)
scripts/config --enable CONFIG_SERIAL_8250
scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
scripts/config --enable CONFIG_SERIAL_8250_PCI

# Wireless (Wi-Fi) Kernel Subsystems
scripts/config --enable CONFIG_NET
scripts/config --enable CONFIG_WIRELESS
scripts/config --enable CONFIG_CFG80211
scripts/config --enable CONFIG_MAC80211

# Kernel crypto API support required by iwd (WPA/EAP handshake crypto)
scripts/config --enable CONFIG_CRYPTO_USER_API_HASH
scripts/config --enable CONFIG_CRYPTO_USER_API_SKCIPHER
scripts/config --enable CONFIG_CRYPTO_ECB
scripts/config --enable CONFIG_CRYPTO_CBC
scripts/config --enable CONFIG_CRYPTO_MD5
scripts/config --enable CONFIG_CRYPTO_SHA1
scripts/config --enable CONFIG_CRYPTO_SHA256
scripts/config --enable CONFIG_CRYPTO_SHA512
scripts/config --enable CONFIG_CRYPTO_AES
scripts/config --enable CONFIG_CRYPTO_DES
scripts/config --enable CONFIG_CRYPTO_CMAC
scripts/config --enable CONFIG_CRYPTO_HMAC
# Optimized x86 implementations of the above, if available for this kernel version
scripts/config --enable CONFIG_CRYPTO_SHA1_SSSE3
scripts/config --enable CONFIG_CRYPTO_SHA256_SSSE3
scripts/config --enable CONFIG_CRYPTO_SHA512_SSSE3
scripts/config --enable CONFIG_CRYPTO_AES_NI_INTEL
scripts/config --enable CONFIG_CRYPTO_AES_X86_64
scripts/config --enable CONFIG_CRYPTO_DES3_EDE_X86_64

# Devtmpfs for boot initialization
scripts/config --enable CONFIG_DEVTMPFS
scripts/config --enable CONFIG_DEVTMPFS_MOUNT

# Disable heavy debug info for fast linking
scripts/config --disable CONFIG_DEBUG_INFO
scripts/config --disable CONFIG_DEBUG_INFO_DWARF5

make olddefconfig

CURRENT_SWAP=$(free -m | awk '/^Swap:/{print $2}')
if [ "$CURRENT_SWAP" -lt 4096 ]; then
    SWAPFILE="$HOME/kernel-build-swapfile"
    if [ ! -f "$SWAPFILE" ]; then
        sudo fallocate -l 8G "$SWAPFILE"
        sudo chmod 600 "$SWAPFILE"
        sudo mkswap "$SWAPFILE"
    fi
    sudo swapon "$SWAPFILE" 2>/dev/null || true
fi

echo "==> Compiling kernel..."
make CC="ccache gcc" -j"$THREADS"

KVER="$(make -s kernelrelease)"
ISO_NAME="custom-linux-${KVER}.iso"
ISO_LABEL="MYLINUXISO"

ROOTFS_DIR="$WORKDIR/rootfs"
sudo rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

echo "==> Installing Base OS + Wi-Fi & System Tools via pacstrap"
sudo pacstrap -c "$ROOTFS_DIR" \
    base linux-firmware \
    gcc boost boost-libs git nano sudo fastfetch \
    iwd networkmanager wpa_supplicant wireless-regdb iw \
    dosfstools exfatprogs

echo "root:live" | sudo arch-chroot "$ROOTFS_DIR" chpasswd

sudo mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d"
sudo tee "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" > /dev/null <<'AUTOLOGIN_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN_EOF

sudo systemctl --root="$ROOTFS_DIR" mask systemd-logind.service systemd-logind.socket systemd-logind-varlink.socket
sudo ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-logind.service"
sudo ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-logind.socket"
sudo ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-logind-varlink.socket"

# Enable NetworkManager and iwd services for quick wireless access
sudo systemctl --root="$ROOTFS_DIR" enable NetworkManager.service
sudo systemctl --root="$ROOTFS_DIR" enable iwd.service

# Boot diagnostics: after normal boot finishes, dump full status of any
# failed unit to the serial console (ttyS0), which test_iso.sh already
# captures to <iso>.bootlog.txt and scans for failures after QEMU exits.
# This surfaces the real error (not just systemd's one-line "[FAILED]")
# without needing to log into the running VM by hand.
sudo tee "$ROOTFS_DIR/usr/local/bin/boot-diagnostics.sh" > /dev/null <<'DIAG_EOF'
#!/bin/bash
{
    echo "===================================================="
    echo " Boot diagnostics"
    echo "===================================================="

    echo "---- systemctl --failed (as of now) ----"
    FAILED_UNITS="$(systemctl --failed --no-legend --plain | awk '{print $1}')"
    if [ -z "$FAILED_UNITS" ]; then
        echo "No units currently in failed state."
    else
        for u in $FAILED_UNITS; do
            echo "-- $u --"
            systemctl status "$u" --no-pager -l
        done
    fi

    echo
    echo "---- Full boot journal (unfiltered) ----"
    echo "     (kept unfiltered so no root-cause line is dropped before"
    echo "      it's captured; test_iso.sh greps the saved log for"
    echo "      fail/error after QEMU exits, but the raw file has"
    echo "      everything if that grep misses something)"
    journalctl -b --no-pager

    echo "===================================================="
} > /dev/ttyS0 2>&1
DIAG_EOF
sudo chmod +x "$ROOTFS_DIR/usr/local/bin/boot-diagnostics.sh"

sudo tee "$ROOTFS_DIR/etc/systemd/system/boot-diagnostics.service" > /dev/null <<'DIAGUNIT_EOF'
[Unit]
Description=Dump failed-unit diagnostics to serial console
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/boot-diagnostics.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
DIAGUNIT_EOF
sudo systemctl --root="$ROOTFS_DIR" enable boot-diagnostics.service

sudo mkdir -p "$ROOTFS_DIR/root/Code"
if [ -n "$INCLUDE_DIR" ]; then
    INCLUDE_NAME="$(basename "$INCLUDE_DIR")"
    sudo cp -a "$INCLUDE_DIR" "$ROOTFS_DIR/root/Code/$INCLUDE_NAME"
fi

rm -f "$WORKDIR/airootfs.sfs"
sudo mksquashfs "$ROOTFS_DIR" "$WORKDIR/airootfs.sfs" -comp gzip -noappend

INITRD_DIR="$WORKDIR/initramfs"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,sbin,etc,proc,sys,dev,mnt/cdrom,mnt/test,newroot,usr/bin,usr/sbin}
cp "$(command -v busybox)" "$INITRD_DIR/bin/busybox"

cd "$INITRD_DIR"
for cmd in sh ls mount switch_root cat mkdir blkid losetup mknod sleep seq grep cut head; do
    ln -sf busybox "bin/$cmd"
done

cat > init <<'INIT_EOF'
#!/bin/busybox sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || mdev -s

echo "=================================================="
echo "  Boot init starting — looking for live media"
echo "=================================================="

respawn_shell() {
    while true; do
        /bin/sh
        sleep 2
    done
}

echo "Waiting for USB storage devices to settle..."
sleep 3
mdev -s 2>/dev/null || true

DEV=""
for i in $(seq 1 15); do
    DEV=$(blkid 2>/dev/null | grep 'TYPE="iso9660"' | cut -d: -f1 | head -n1)
    [ -n "$DEV" ] && echo "Found media: $DEV" && break
    sleep 1
done

if [ -z "$DEV" ]; then
    for candidate in /dev/sr0 /dev/sr1 /dev/sda /dev/sdb /dev/sdc /dev/sdd \
                      /dev/nvme0n1 /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1; do
        if [ -b "$candidate" ]; then
            mkdir -p /mnt/test
            if mount -t iso9660 -o ro "$candidate" /mnt/test 2>/dev/null; then
                if [ -f /mnt/test/LiveOS/airootfs.sfs ]; then
                    DEV="$candidate"
                    umount /mnt/test
                    break
                fi
                umount /mnt/test
            fi
        fi
    done
fi

if [ -z "$DEV" ]; then
    echo "ERROR: Live media not found."
    respawn_shell
fi

mount -t iso9660 -o ro "$DEV" /mnt/cdrom || respawn_shell

mkdir -p /mnt/squashfs-ro
mount -t squashfs -o loop,ro /mnt/cdrom/LiveOS/airootfs.sfs /mnt/squashfs-ro || respawn_shell

mkdir -p /mnt/overlay /newroot
mount -t tmpfs tmpfs /mnt/overlay || respawn_shell

mkdir -p /mnt/overlay/upper /mnt/overlay/work

mount -t overlay overlay -o lowerdir=/mnt/squashfs-ro,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work /newroot || respawn_shell

exec switch_root /newroot /sbin/init 2>/dev/null || exec switch_root /newroot /bin/bash 2>/dev/null || exec switch_root /newroot /bin/sh
respawn_shell
INIT_EOF
chmod +x init

find . | cpio -o -H newc | gzip > "$WORKDIR/initramfs.img"

ISO_DIR="$WORKDIR/isoroot"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/grub" "$ISO_DIR/LiveOS"

cp "$SRC_DIR/arch/x86/boot/bzImage" "$ISO_DIR/boot/vmlinuz"
cp "$WORKDIR/initramfs.img" "$ISO_DIR/boot/initramfs.img"
cp "$WORKDIR/airootfs.sfs" "$ISO_DIR/LiveOS/airootfs.sfs"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<GRUB_EOF
set timeout=5
set default=0

menuentry "Custom Linux ${KVER} (Verbose Boot)" {
    set gfxpayload=text
    linux /boot/vmlinuz nomodeset keep_bootcon loglevel=7 console=tty0 console=ttyS0,115200n8
    initrd /boot/initramfs.img
}
GRUB_EOF

grub-mkrescue -volid "$ISO_LABEL" -o "$WORKDIR/$ISO_NAME" "$ISO_DIR"

echo "==> ISO created successfully at: $WORKDIR/$ISO_NAME"

TEST_ANSWER="n"
if [ -t 0 ]; then
    read -r -p "==> Do you want to test the ISO now? [y/N] " TEST_ANSWER || TEST_ANSWER="n"
else
    echo "==> Non-interactive shell detected, skipping test prompt."
fi

case "$TEST_ANSWER" in
    [Yy]|[Yy][Ee][Ss])
        if [ ! -f "$TEST_SCRIPT" ]; then
            echo "ERROR: test_iso.sh not found next to build_iso.sh ($TEST_SCRIPT)"
            exit 1
        fi
        bash "$TEST_SCRIPT" "$WORKDIR/$ISO_NAME"
        ;;
    *)
        echo "==> Skipping test. You can test it later with:"
        echo "      $TEST_SCRIPT \"$WORKDIR/$ISO_NAME\""
        ;;
esac
