#!/usr/bin/env bash
# build_iso.sh
#
# Run this FROM INSIDE your existing kernel source directory
# (the one containing the Makefile, arch/, drivers/, etc).
#
# Compiles whatever source is already there, builds a REAL root filesystem
# (via pacstrap, including g++, Boost, and git), squashes it onto the ISO,
# and packages a bootable GRUB ISO around your custom kernel.
#
# Usage:
#   cd /path/to/your/linux-source
#   chmod +x build_iso.sh
#   ./build_iso.sh                            # normal build, uses all CPU threads
#   ./build_iso.sh fullfromscratch             # wipes ALL build artifacts and .config, rebuilds everything
#   ./build_iso.sh 4                           # normal build, limited to 4 threads
#   ./build_iso.sh fullfromscratch 4           # clean rebuild, limited to 4 threads
#   (order of the two arguments doesn't matter)
#
# Always trims the KERNEL config to your currently-loaded modules (localmodconfig)
# for a faster build, but force-enables squashfs/iso9660/loop support since the
# live boot process needs them regardless of what's loaded right now.
#
set -euo pipefail

BUILD_MODE=""
THREADS="$(nproc)"

for arg in "$@"; do
    if [ "$arg" = "fullfromscratch" ]; then
        BUILD_MODE="fullfromscratch"
    elif [[ "$arg" =~ ^[0-9]+$ ]]; then
        THREADS="$arg"
    else
        echo "WARNING: unrecognized argument '$arg' — ignoring."
        echo "Valid arguments: 'fullfromscratch' and/or a number of threads (e.g. 4)."
    fi
done

echo "==> Using $THREADS thread(s) for compilation (system has $(nproc) available)"

START_TIME=$(date +%s)
echo "==> Build started at: $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S')"

# Sanity check: make sure we're actually in a kernel source tree
if [ ! -f "Makefile" ] || [ ! -d "kernel" ] || [ ! -d "arch" ]; then
    echo "ERROR: This doesn't look like a Linux kernel source directory."
    echo "cd into the directory containing the kernel's Makefile, arch/, kernel/, etc, then re-run."
    exit 1
fi

SRC_DIR="$(pwd)"
WORKDIR="$HOME/kernel-build"
mkdir -p "$WORKDIR"

if [ "$BUILD_MODE" = "fullfromscratch" ]; then
    echo "==> fullfromscratch requested: wiping all build artifacts and existing .config"
    echo "    (this removes .config, all compiled .o files, and generated headers —"
    echo "     ccache's own cache is left intact, so file-level compiles can still hit it)"
    make mrproper
fi

echo "==> Installing build dependencies"
sudo pacman -Syu --needed --noconfirm \
    base-devel ncurses bison flex openssl libelf bc cpio \
    grub xorriso mtools busybox ccache squashfs-tools arch-install-scripts

echo "==> Enabling ccache for this build (speeds up rebuilds significantly)"
export PATH="/usr/lib/ccache/bin:$PATH"
export CCACHE_DIR="$HOME/.ccache"
ccache -M 10G >/dev/null   # cap ccache size at 10GB, adjust if you want more/less
echo "ccache stats before build:"
ccache -s

echo "==> Configuring kernel (using existing .config if present, else current running kernel's config)"
if [ -f ".config" ]; then
    echo "Found existing .config in this source tree — using it."
    make olddefconfig
elif zcat /proc/config.gz > .config 2>/dev/null; then
    echo "No .config found — seeded from your currently running kernel."
    make olddefconfig
else
    echo "No .config found and /proc/config.gz unavailable — falling back to defconfig."
    make defconfig
fi

echo "==> Trimming config to only modules currently loaded on this system (much faster build)"
make localmodconfig

echo "==> Force-enabling filesystem/loop support needed to boot a squashfs-based live ISO"
echo "    (these might not be in your trimmed config if you're not currently using them)"
scripts/config --enable CONFIG_SQUASHFS
scripts/config --enable CONFIG_ISO9660_FS
scripts/config --enable CONFIG_BLK_DEV_LOOP
scripts/config --enable CONFIG_OVERLAY_FS
make olddefconfig

echo "==> Compiling kernel with ccache (this will take a while on first build; much faster on rebuilds)"
make CC="ccache gcc" -j"$THREADS"

echo "ccache stats after build:"
ccache -s

# Figure out the version string of what we just built, for naming things
KVER="$(make -s kernelrelease)"
ISO_NAME="custom-linux-${KVER}.iso"
ISO_LABEL="MYLINUXISO"
echo "==> Kernel build complete: $(pwd)/arch/x86/boot/bzImage (version ${KVER})"

# ---- Build a REAL root filesystem with pacstrap ----
# This replaces the old BusyBox-only initramfs approach — g++, Boost, and git
# need actual shared libraries and a package manager, which BusyBox can't provide.
echo "==> Building root filesystem with pacstrap (this includes gcc/g++, Boost, and git)"
ROOTFS_DIR="$WORKDIR/rootfs"
sudo rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"

sudo pacstrap -c "$ROOTFS_DIR" base gcc boost boost-libs git nano

echo "==> Squashing root filesystem (this can take a few minutes)"
rm -f "$WORKDIR/airootfs.sfs"
sudo mksquashfs "$ROOTFS_DIR" "$WORKDIR/airootfs.sfs" -comp xz -noappend

# ---- Build a small BusyBox initramfs whose only job is to find and boot the squashfs ----
echo "==> Building boot initramfs (mounts the ISO, loop-mounts the squashfs, switches root)"
INITRD_DIR="$WORKDIR/initramfs"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,sbin,etc,proc,sys,dev,mnt/cdrom,newroot,usr/bin,usr/sbin}
cp "$(command -v busybox)" "$INITRD_DIR/bin/busybox"

cd "$INITRD_DIR"
for cmd in sh ls mount switch_root cat mkdir blkid losetup mknod sleep; do
    ln -sf busybox "bin/$cmd"
done

cat > init <<EOF
#!/bin/busybox sh
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev 2>/dev/null || mdev -s

echo "Looking for boot media labeled ${ISO_LABEL}..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    DEV=\$(blkid -L "${ISO_LABEL}" 2>/dev/null)
    [ -n "\$DEV" ] && break
    sleep 1
done

if [ -z "\$DEV" ]; then
    echo "ERROR: could not find device labeled ${ISO_LABEL}. Dropping to shell."
    exec /bin/sh
fi

mount -t iso9660 -o ro "\$DEV" /mnt/cdrom
mount -t squashfs -o loop,ro /mnt/cdrom/LiveOS/airootfs.sfs /newroot

echo "Booting into full root filesystem..."
exec switch_root /newroot /sbin/init 2>/dev/null || exec switch_root /newroot /bin/sh
EOF
chmod +x init

find . | cpio -o -H newc | gzip > "$WORKDIR/initramfs.img"

# ---- Assemble bootable ISO with GRUB ----
echo "==> Assembling ISO"
ISO_DIR="$WORKDIR/isoroot"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/grub" "$ISO_DIR/LiveOS"

cp "$SRC_DIR/arch/x86/boot/bzImage" "$ISO_DIR/boot/vmlinuz"
cp "$WORKDIR/initramfs.img" "$ISO_DIR/boot/initramfs.img"
cp "$WORKDIR/airootfs.sfs" "$ISO_DIR/LiveOS/airootfs.sfs"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "Custom Linux ${KVER} (full rootfs: g++, Boost, git)" {
    linux /boot/vmlinuz console=ttyS0 console=tty0
    initrd /boot/initramfs.img
}
EOF

grub-mkrescue -volid "$ISO_LABEL" -o "$WORKDIR/$ISO_NAME" "$ISO_DIR"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo "==> Build started at:  $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S')"
echo "==> Build finished at: $(date -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S')"
echo "==> Total time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo "==> Done. ISO created at: $WORKDIR/$ISO_NAME"
echo
echo "This ISO now boots into a real root filesystem with g++, Boost, and git installed."
echo "Once booted, verify with:"
echo "  g++ --version"
echo "  git --version"
echo "  pacman -Qi boost boost-libs"
echo
echo "Test it first in a VM before touching a real USB drive:"
echo "  sudo pacman -S --needed qemu-full"
echo "  qemu-system-x86_64 -cdrom $WORKDIR/$ISO_NAME -m 2048"
echo "  (bumped to 2048MB RAM here since the full rootfs needs more than the old BusyBox image did)"
echo
echo "To write it to a USB drive (THIS ERASES THE DRIVE):"
echo "  1. Find the device: lsblk"
echo "  2. sudo dd if=$WORKDIR/$ISO_NAME of=/dev/sdX bs=4M status=progress oflag=sync"
echo "     (replace /dev/sdX with your actual USB device, NOT a partition like /dev/sdX1)"
echo
echo "Next time you rebuild after code changes, ccache will make it much faster automatically."
