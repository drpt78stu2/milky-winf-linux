#!/usr/bin/env bash
# build_iso.sh
#
# Run this FROM INSIDE your existing kernel source directory
# (the one containing the Makefile, arch/, drivers/, etc).
#
# Compiles whatever source is already there, builds a minimal
# BusyBox initramfs, and packages a bootable GRUB ISO.
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
# Always trims the config to your currently-loaded modules (localmodconfig)
# for a faster build. See note below if you need broader hardware support.
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
    grub xorriso mtools busybox ccache

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
echo "    NOTE: the resulting kernel will only support hardware/features active right now."
echo "    If you need broader hardware support later, edit this script and comment out"
echo "    the 'make localmodconfig' line below to build the full config instead."
make localmodconfig

echo "==> Compiling kernel with ccache (this will take a while on first build; much faster on rebuilds)"
make CC="ccache gcc" -j"$THREADS"

echo "ccache stats after build:"
ccache -s

# Figure out the version string of what we just built, for naming things
KVER="$(make -s kernelrelease)"
ISO_NAME="custom-linux-${KVER}.iso"
echo "==> Kernel build complete: $(pwd)/arch/x86/boot/bzImage (version ${KVER})"

# ---- Build a minimal initramfs with BusyBox ----
echo "==> Building minimal initramfs"
INITRD_DIR="$WORKDIR/initramfs"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin}
cp "$(command -v busybox)" "$INITRD_DIR/bin/busybox"

cd "$INITRD_DIR"
for cmd in sh ls mount switch_root cat mkdir; do
    ln -sf busybox "bin/$cmd"
done

cat > init <<'EOF'
#!/bin/busybox sh
mount -t proc none /proc
mount -t sysfs none /sys
echo "Custom kernel booted successfully!"
exec /bin/sh
EOF
chmod +x init

find . | cpio -o -H newc | gzip > "$WORKDIR/initramfs.img"

# ---- Assemble bootable ISO with GRUB ----
echo "==> Assembling ISO"
ISO_DIR="$WORKDIR/isoroot"
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/grub"

cp "$SRC_DIR/arch/x86/boot/bzImage" "$ISO_DIR/boot/vmlinuz"
cp "$WORKDIR/initramfs.img" "$ISO_DIR/boot/initramfs.img"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "Custom Linux ${KVER}" {
    linux /boot/vmlinuz console=ttyS0 console=tty0
    initrd /boot/initramfs.img
}
EOF

grub-mkrescue -o "$WORKDIR/$ISO_NAME" "$ISO_DIR"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
ELAPSED_MIN=$((ELAPSED / 60))
ELAPSED_SEC=$((ELAPSED % 60))

echo "==> Build started at:  $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S')"
echo "==> Build finished at: $(date -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S')"
echo "==> Total time: ${ELAPSED_MIN}m ${ELAPSED_SEC}s"
echo "==> Done. ISO created at: $WORKDIR/$ISO_NAME"
echo
echo "Test it first in a VM before touching a real USB drive:"
echo "  sudo pacman -S --needed qemu-full"
echo "  qemu-system-x86_64 -cdrom $WORKDIR/$ISO_NAME -m 512"
echo
echo "To write it to a USB drive (THIS ERASES THE DRIVE):"
echo "  1. Find the device: lsblk"
echo "  2. sudo dd if=$WORKDIR/$ISO_NAME of=/dev/sdX bs=4M status=progress oflag=sync"
echo "     (replace /dev/sdX with your actual USB device, NOT a partition like /dev/sdX1)"
echo
echo "Next time you rebuild after code changes, ccache will make it much faster automatically."
