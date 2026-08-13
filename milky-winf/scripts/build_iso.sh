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
#   ./build_iso.sh includedir=/path/to/dir     # also copies that directory into /root/Code in the live system
#   (all arguments can be combined, order doesn't matter)
#
# Always trims the KERNEL config to your currently-loaded modules (localmodconfig)
# for a faster build, but force-enables squashfs/iso9660/loop support since the
# live boot process needs them regardless of what's loaded right now.
#
set -euo pipefail

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
        echo "Valid arguments: 'fullfromscratch', a number of threads (e.g. 4), or 'includedir=/path'."
    fi
done

if [ -n "$INCLUDE_DIR" ] && [ ! -d "$INCLUDE_DIR" ]; then
    echo "ERROR: includedir path '$INCLUDE_DIR' does not exist or is not a directory."
    exit 1
fi

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
    grub xorriso mtools busybox ccache squashfs-tools arch-install-scripts pv qemu-full

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
scripts/config --enable CONFIG_SQUASHFS_ZLIB
scripts/config --enable CONFIG_SQUASHFS_XZ
scripts/config --enable CONFIG_ISO9660_FS
scripts/config --enable CONFIG_BLK_DEV_LOOP
scripts/config --enable CONFIG_OVERLAY_FS

echo "==> Force-enabling USB/storage drivers as BUILT-IN (not modules)"
echo "    This is critical: localmodconfig may have set these as loadable modules (=m),"
echo "    but the BusyBox initramfs has no way to load kernel modules — so without this,"
echo "    the USB drive never appears as a device at all during boot."
scripts/config --enable CONFIG_USB
scripts/config --enable CONFIG_USB_SUPPORT
scripts/config --enable CONFIG_USB_XHCI_HCD
scripts/config --enable CONFIG_USB_EHCI_HCD
scripts/config --enable CONFIG_USB_OHCI_HCD
scripts/config --enable CONFIG_USB_STORAGE
scripts/config --enable CONFIG_SCSI
scripts/config --enable CONFIG_BLK_DEV_SD
scripts/config --enable CONFIG_BLK_DEV_SR
# NOTE: CONFIG_ATA caused a hard hang during hardware probing on real laptop
# hardware (never showed up in QEMU). It isn't needed for booting off a USB stick
# — USB_STORAGE + SCSI + xHCI cover that path. Merely not force-ENABLING it wasn't
# enough because it was already =y from the base config we seeded — so it must be
# explicitly DISABLED here to actually turn it off.
scripts/config --disable CONFIG_ATA
scripts/config --enable CONFIG_DEVTMPFS
scripts/config --enable CONFIG_DEVTMPFS_MOUNT

echo "==> Disabling debug info to shrink vmlinux.o (reduces peak RAM needed at the link step)"
scripts/config --disable CONFIG_DEBUG_INFO
scripts/config --disable CONFIG_DEBUG_INFO_DWARF5

make olddefconfig

# ---- Set up swap if none exists, so the linker doesn't get OOM-killed on low-RAM systems ----
# The final LD vmlinux.o step is single-threaded and can spike to several GB regardless of
# -j/thread count — swap is what actually prevents Error 137 (OOM kill) at that step.
CURRENT_SWAP=$(free -m | awk '/^Swap:/{print $2}')
if [ "$CURRENT_SWAP" -lt 4096 ]; then
    SWAPFILE="$HOME/kernel-build-swapfile"
    if [ ! -f "$SWAPFILE" ]; then
        echo "==> Less than 4GB swap detected — creating an 8GB swapfile to prevent OOM during linking"
        sudo fallocate -l 8G "$SWAPFILE"
        sudo chmod 600 "$SWAPFILE"
        sudo mkswap "$SWAPFILE"
    fi
    sudo swapon "$SWAPFILE" 2>/dev/null || echo "    (swapfile already active)"
    echo "    Swap now active: $(free -h | awk '/^Swap:/{print $2}')"
else
    echo "==> Sufficient swap already present ($(( CURRENT_SWAP / 1024 ))GB) — skipping swapfile creation"
fi

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

sudo pacstrap -c "$ROOTFS_DIR" base gcc boost boost-libs git nano sudo fastfetch

echo "==> Setting root password and enabling auto-login (fresh pacstrap accounts have no valid password)"
echo "root:live" | sudo arch-chroot "$ROOTFS_DIR" chpasswd
echo "    Root password set to: live"

# Auto-login on tty1 so you land straight at a shell without needing the password at all
sudo mkdir -p "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d"
sudo tee "$ROOTFS_DIR/etc/systemd/system/getty@tty1.service.d/autologin.conf" > /dev/null <<'AUTOLOGIN_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN_EOF
echo "    Auto-login enabled on tty1 — should boot straight to a root shell, no password needed"

echo "==> Masking systemd-logind (not needed for a single-shell live image, was causing restart-loop spam)"
sudo systemctl --root="$ROOTFS_DIR" mask systemd-logind.service systemd-logind.socket systemd-logind-varlink.socket
# Belt-and-suspenders: create the mask symlinks directly too, in case systemctl --root
# didn't fully suppress activation via socket/dbus triggers in this minimal image.
sudo ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-logind.service"
sudo ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-logind.socket"
sudo ln -sf /dev/null "$ROOTFS_DIR/etc/systemd/system/systemd-logind-varlink.socket"

echo "==> Preparing /root/Code directory"
sudo mkdir -p "$ROOTFS_DIR/root/Code"

if [ -n "$INCLUDE_DIR" ]; then
    INCLUDE_NAME="$(basename "$INCLUDE_DIR")"
    echo "==> Copying $INCLUDE_DIR into /root/Code/$INCLUDE_NAME in the live system"
    sudo cp -a "$INCLUDE_DIR" "$ROOTFS_DIR/root/Code/$INCLUDE_NAME"
fi

echo "==> Squashing root filesystem (this can take a few minutes)"
rm -f "$WORKDIR/airootfs.sfs"
# Using gzip (zlib) compression instead of xz — zlib support is effectively always
# present whenever CONFIG_SQUASHFS=y, whereas xz decompression needs a separate
# kernel config option (CONFIG_SQUASHFS_XZ) that may not be enabled. Larger output
# file than xz, but guaranteed to actually mount with your current kernel.
sudo mksquashfs "$ROOTFS_DIR" "$WORKDIR/airootfs.sfs" -comp gzip -noappend

# ---- Build a small BusyBox initramfs whose only job is to find and boot the squashfs ----
echo "==> Building boot initramfs (mounts the ISO, loop-mounts the squashfs, switches root)"
INITRD_DIR="$WORKDIR/initramfs"
rm -rf "$INITRD_DIR"
mkdir -p "$INITRD_DIR"/{bin,sbin,etc,proc,sys,dev,mnt/cdrom,mnt/test,newroot,usr/bin,usr/sbin}
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

# Redirect this script's own output (and input) to the serial console explicitly,
# but ONLY if that device actually exists. On QEMU, /dev/ttyS0 is always present,
# so this makes boot logs capturable via -serial stdio. On REAL hardware without a
# serial port, /dev/ttyS0 doesn't exist — and since 'exec' is a shell special
# builtin, a FAILED redirection on it terminates the shell immediately. That shell
# is PID 1 here, so it would crash the kernel with "Attempted to kill init!" the
# instant this ran. Guarding with a device check avoids that entirely.
if [ -c /dev/ttyS0 ]; then
    exec 0</dev/ttyS0 1>/dev/ttyS0 2>&1
fi

echo "=================================================="
echo "  Boot init starting — looking for live media"
echo "=================================================="

# Safety net: PID 1 must never exit, or the kernel panics ("Attempted to kill init!").
# This can happen on real hardware if a fallback rescue shell hits EOF on stdin
# (console/keyboard timing can differ from QEMU). Instead of 'exec /bin/sh' directly,
# every fallback below calls this function, which respawns the shell in a loop
# rather than letting it actually terminate PID 1.
respawn_shell() {
    while true; do
        /bin/sh
        echo "Shell exited (stdin EOF or similar) — respawning in 2s to avoid a kernel panic."
        echo "If this loops repeatedly, the console/keyboard isn't being read correctly."
        sleep 2
    done
}

echo "Available block devices:"
ls -la /dev/sd* /dev/sr* 2>/dev/null
echo "--------------------------------------------------"

DEV=""

# Method 1: parse plain `blkid` output and match by filesystem TYPE, not label.
# BusyBox's blkid doesn't reliably support -L (label search), and grub-mkrescue's
# hybrid ISOs can have multiple partitions sharing the same label (e.g. an hfsplus
# partition for Mac boot support) — so we match specifically on TYPE="iso9660"
# to get the real data partition, not a decoy.
echo "Scanning blkid output for an iso9660 filesystem..."
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    DEV=\$(blkid 2>/dev/null | grep 'TYPE="iso9660"' | cut -d: -f1 | head -n1)
    [ -n "\$DEV" ] && echo "Found via blkid TYPE match: \$DEV" && break
    echo "  attempt \$i: not found yet, current /dev/sd*: \$(ls /dev/sd* 2>/dev/null || echo none)"
    sleep 1
done

# Method 2: fall back to scanning likely candidates directly if blkid parsing failed.
# Includes WHOLE-DISK devices (/dev/sda, not just /dev/sda1) since grub-mkrescue
# hybrid ISOs put the iso9660 filesystem on the raw disk device, not a partition.
if [ -z "\$DEV" ]; then
    echo "blkid parsing failed — scanning whole-disk and partition devices directly..."
    for candidate in /dev/sr0 /dev/sr1 /dev/sda /dev/sdb /dev/sdc /dev/sdd \\
                      /dev/sda1 /dev/sdb1 /dev/sdc1 /dev/sdd1; do
        if [ -b "\$candidate" ]; then
            mkdir -p /mnt/test
            if mount -t iso9660 -o ro "\$candidate" /mnt/test 2>/dev/null; then
                if [ -f /mnt/test/LiveOS/airootfs.sfs ]; then
                    echo "Found valid live media at: \$candidate"
                    DEV="\$candidate"
                    umount /mnt/test
                    break
                fi
                umount /mnt/test
            fi
        fi
    done
fi

if [ -z "\$DEV" ]; then
    echo "=================================================="
    echo "ERROR: could not find boot media by label or by scanning."
    echo "Diagnostic info — actual device labels found:"
    blkid
    echo "Dropping to a BusyBox rescue shell — git/gcc will NOT be available here."
    echo "Run 'blkid' and 'ls /dev' manually to investigate, then 'mount' by hand."
    echo "=================================================="
    respawn_shell
fi

echo "Mounting \$DEV as ISO..."
mount -t iso9660 -o ro "\$DEV" /mnt/cdrom || {
    echo "ERROR: failed to mount \$DEV as iso9660. Dropping to rescue shell."
    respawn_shell
}

if [ ! -f /mnt/cdrom/LiveOS/airootfs.sfs ]; then
    echo "ERROR: /mnt/cdrom/LiveOS/airootfs.sfs not found on mounted media."
    echo "Contents of /mnt/cdrom:"
    ls -la /mnt/cdrom
    echo "Dropping to rescue shell."
    respawn_shell
fi

echo "Loop-mounting the squashfs root filesystem (read-only lower layer)..."
mkdir -p /mnt/squashfs-ro
mount -t squashfs -o loop,ro /mnt/cdrom/LiveOS/airootfs.sfs /mnt/squashfs-ro || {
    echo "ERROR: failed to mount squashfs. Dropping to rescue shell."
    respawn_shell
}

echo "Setting up a writable overlay (tmpfs, RAM-backed) on top of the read-only rootfs..."
echo "NOTE: writes (like g++ output) now work, but are lost on reboot since it's RAM-backed."
mkdir -p /mnt/overlay
mount -t tmpfs tmpfs /mnt/overlay || {
    echo "ERROR: failed to mount tmpfs for overlay. Dropping to rescue shell."
    respawn_shell
}
mkdir -p /mnt/overlay/upper /mnt/overlay/work

mount -t overlay overlay -o lowerdir=/mnt/squashfs-ro,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work /newroot || {
    echo "ERROR: failed to mount overlay filesystem. Dropping to rescue shell."
    respawn_shell
}

if [ ! -x /newroot/sbin/init ] && [ ! -x /newroot/usr/lib/systemd/systemd ]; then
    echo "WARNING: no /sbin/init or systemd found in root filesystem."
    echo "Contents of /newroot:"
    ls -la /newroot
fi

echo "Switching to full, WRITABLE root filesystem (g++, Boost, git should be available after this)..."
exec switch_root /newroot /sbin/init 2>/dev/null || exec switch_root /newroot /bin/bash 2>/dev/null || exec switch_root /newroot /bin/sh
echo "ERROR: switch_root itself could not be launched at all — this should be rare."
respawn_shell
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
echo "Next time you rebuild after code changes, ccache will make it much faster automatically."

# ---- Interactive: test the ISO in QEMU before touching real hardware/USB ----
echo
echo "=================================================================="
echo " Quick VM test (recommended before writing to USB or real hardware)"
echo "=================================================================="
read -r -p "Boot this ISO in QEMU now to test it? [y/N]: " RUN_QEMU

if [ "$RUN_QEMU" = "y" ] || [ "$RUN_QEMU" = "Y" ]; then
    QEMU_LOG="$WORKDIR/qemu-boot.log"
    echo "==> Launching QEMU (close the QEMU window, or Ctrl+C here, to stop the test)"
    echo "    Booting as a USB mass-storage device (matches how a real USB stick behaves)"
    echo "    with 2048MB RAM. Boot output is also being saved as plain text to: $QEMU_LOG"
    echo "    ISO path: $WORKDIR/$ISO_NAME"
    qemu-system-x86_64 -m 2048 \
        -device qemu-xhci \
        -drive if=none,id=stick,format=raw,file="$WORKDIR/$ISO_NAME" \
        -device usb-storage,drive=stick \
        -serial stdio | tee "$QEMU_LOG"
    echo "==> QEMU session ended."
    echo "    Full boot log saved at: $QEMU_LOG"
    echo "    (open it with 'cat $QEMU_LOG' or copy/paste sections of it to share for troubleshooting)"
else
    echo "Skipping QEMU test. You can run it manually anytime with:"
    echo "  qemu-system-x86_64 -m 2048 -device qemu-xhci -drive if=none,id=stick,format=raw,file=$WORKDIR/$ISO_NAME -device usb-storage,drive=stick -serial stdio | tee $WORKDIR/qemu-boot.log"
fi

# ---- Interactive: choose a USB device to burn the ISO to ----
echo
echo "=================================================================="
echo " Available disks/devices on this system:"
echo "=================================================================="
lsblk -d -o NAME,SIZE,MODEL,TRAN,TYPE | grep -E "disk|NAME"
echo "=================================================================="
echo
echo "Which device do you want to write the ISO to?"
echo "Enter the device name only (e.g. sdb) — NOT a partition (e.g. sdb1) — or leave blank to skip."
read -r -p "Device: " TARGET_DEV

if [ -z "$TARGET_DEV" ]; then
    echo "No device entered — skipping USB write. Your ISO is still available at:"
    echo "  $WORKDIR/$ISO_NAME"
else
    TARGET_PATH="/dev/${TARGET_DEV#/dev/}"

    if [ ! -b "$TARGET_PATH" ]; then
        echo "ERROR: $TARGET_PATH does not look like a valid block device. Aborting write."
        echo "Your ISO is still available at: $WORKDIR/$ISO_NAME"
    else
        echo
        echo "WARNING: this will PERMANENTLY ERASE all data on $TARGET_PATH."
        lsblk "$TARGET_PATH"
        echo
        read -r -p "Type YES (all caps) to confirm writing to $TARGET_PATH: " CONFIRM

        if [ "$CONFIRM" = "YES" ]; then
            echo "==> Writing $ISO_NAME to $TARGET_PATH ..."
            pv "$WORKDIR/$ISO_NAME" | sudo dd of="$TARGET_PATH" bs=4M oflag=sync
            sync
            echo "==> Done writing to $TARGET_PATH."
        else
            echo "Confirmation not received — skipping USB write. Your ISO is still available at:"
            echo "  $WORKDIR/$ISO_NAME"
        fi
    fi
fi
