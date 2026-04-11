#!/bin/sh
# Build Gershwin in a Tiny Core Linux 16.x chroot.
#
# x86_64 : uses corepure64.gz (cpio initramfs) as the chroot base.
# aarch64 : uses piCore64-16.0.0.img.gz — the rootfs lives on partition 2
#            (ext4) of the Pi disk image; we mount it via loopback and copy
#            it into the chroot directory.
#
# Both architectures then install TCZ packages and run the Gershwin Makefile
# inside the chroot.  Run the aarch64 variant on an ubuntu-24.04-arm runner
# so the chroot can be entered without QEMU.

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TCE_VERSION="16.x"
TCE_ARCH="${TCE_ARCH:-x86_64}"
TCE_BASE_URL="http://www.tinycorelinux.net/${TCE_VERSION}/${TCE_ARCH}"
TCE_TCZ_URL="${TCE_BASE_URL}/tcz"

# x86_64 base rootfs (cpio initramfs)
TCE_CORE_URL="${TCE_BASE_URL}/release/distribution_files/corepure64.gz"

# aarch64 base rootfs (Pi disk image — partition 2 is the ext4 rootfs)
PI_IMG_URL="http://www.tinycorelinux.net/${TCE_VERSION}/aarch64/release/RPi/piCore64-16.0.0.img.gz"

CHROOT_DIR="${CHROOT_DIR:-/tmp/tce-chroot}"
CACHE_DIR="${CACHE_DIR:-/tmp/tce-cache}"
BUILD_DIR="${BUILD_DIR:-$(pwd)}"

# ---------------------------------------------------------------------------
# Host prerequisites
# ---------------------------------------------------------------------------
install_host_deps() {
    echo "[host] installing host prerequisites"
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        cpio squashfs-tools wget xz-utils git util-linux e2fsprogs
}

# ---------------------------------------------------------------------------
# TCZ installer — resolves .tcz.dep recursively then unsquashfs into chroot
# ---------------------------------------------------------------------------
_installed_pkgs=""

install_tcz() {
    local pkg
    pkg="${1%.tcz}"

    # Skip if already done in this session
    case " ${_installed_pkgs} " in
        *" ${pkg} "*) return 0 ;;
    esac
    # Mark immediately to break dependency cycles
    _installed_pkgs="${_installed_pkgs} ${pkg}"

    echo "[tce] ${pkg}"

    # Resolve and install dependencies first
    local deps
    deps=$(wget -qO- "${TCE_TCZ_URL}/${pkg}.tcz.dep" 2>/dev/null | tr -d '\r' || true)
    for dep in ${deps}; do
        dep="${dep%.tcz}"
        [ -n "${dep}" ] && install_tcz "${dep}"
    done

    # Download the TCZ (cache it across runs)
    local tcz="${CACHE_DIR}/${pkg}.tcz"
    mkdir -p "${CACHE_DIR}"
    if [ ! -s "${tcz}" ]; then
        if ! wget -q -O "${tcz}" "${TCE_TCZ_URL}/${pkg}.tcz"; then
            echo "  WARNING: could not download ${pkg}.tcz — skipping"
            rm -f "${tcz}"
            return 0
        fi
    fi

    # Extract squashfs into chroot root
    sudo unsquashfs -f -d "${CHROOT_DIR}" "${tcz}" > /dev/null 2>&1 || {
        echo "  WARNING: unsquashfs failed for ${pkg}.tcz — skipping"
        return 0
    }
}

# ---------------------------------------------------------------------------
# Set up the TCE 16.x chroot  (x86_64 path)
# ---------------------------------------------------------------------------
setup_chroot_x86_64() {
    echo "[setup] creating TCE ${TCE_VERSION} x86_64 chroot at ${CHROOT_DIR}"
    mkdir -p "${CHROOT_DIR}"

    # Download base root filesystem
    local gz="/tmp/corepure64.gz"
    if [ ! -s "${gz}" ]; then
        wget -q "${TCE_CORE_URL}" -O "${gz}"
    fi

    # Extract cpio initramfs
    cd "${CHROOT_DIR}"
    zcat "${gz}" | sudo cpio -idm 2>/dev/null || true
    cd -

    # Create /lib64 -> /lib symlink.
    # clang on x86_64 embeds interpreter /lib64/ld-linux-x86-64.so.2, but
    # TCE's initramfs only has /lib/ld-linux-x86-64.so.2 (no /lib64 dir).
    # Without this the kernel cannot exec any compiled binary.
    sudo ln -sfn lib "${CHROOT_DIR}/lib64"
}

# ---------------------------------------------------------------------------
# Set up the TCE 16.x chroot  (aarch64 path — Pi disk image)
# ---------------------------------------------------------------------------
setup_chroot_aarch64() {
    echo "[setup] creating TCE ${TCE_VERSION} aarch64 chroot at ${CHROOT_DIR}"
    mkdir -p "${CHROOT_DIR}"

    # Download the Pi disk image (cached as picore64.img.gz)
    local img_gz="/tmp/picore64.img.gz"
    local img="/tmp/picore64.img"

    if [ ! -s "${img_gz}" ]; then
        echo "[setup] downloading piCore64 disk image ..."
        wget -q "${PI_IMG_URL}" -O "${img_gz}"
    fi

    # Decompress the disk image
    if [ ! -s "${img}" ]; then
        echo "[setup] decompressing piCore64 disk image ..."
        zcat "${img_gz}" > "${img}"
    fi

    # Attach the image as a loop device with partition scanning.
    # Partition layout:  p1 = FAT32 (boot files + rootfs cpio)
    #                    p2 = ext4  (persistent TCE storage, not the OS rootfs)
    local loop
    loop=$(sudo losetup -Pf --show "${img}")
    echo "[setup] loop device: ${loop}"

    # Mount the FAT boot partition and extract the cpio rootfs from it.
    # The rootfs cpio is named rootfs-piCore64-16.0.gz on partition 1.
    local fat_mnt="/tmp/pi-fat-mnt"
    sudo mkdir -p "${fat_mnt}"
    sudo mount -o ro "${loop}p1" "${fat_mnt}"

    echo "[setup] extracting cpio rootfs from Pi FAT partition ..."
    local rootfs_cpio
    rootfs_cpio=$(find "${fat_mnt}" -maxdepth 1 -name "rootfs*.gz" | head -1)
    echo "[setup] rootfs cpio: ${rootfs_cpio}"

    cd "${CHROOT_DIR}"
    zcat "${rootfs_cpio}" | sudo cpio -idm 2>/dev/null || true
    cd -

    sudo umount "${fat_mnt}"
    sudo losetup -d "${loop}"
    echo "[setup] aarch64 rootfs extracted"
}

# ---------------------------------------------------------------------------
# Common chroot post-setup (both architectures)
# ---------------------------------------------------------------------------
setup_chroot_common() {
    # Make /usr/local tree available inside the chroot
    sudo mkdir -p \
        "${CHROOT_DIR}/usr/local/bin" \
        "${CHROOT_DIR}/usr/local/lib" \
        "${CHROOT_DIR}/usr/local/include" \
        "${CHROOT_DIR}/usr/local/lib/pkgconfig"

    # Ensure /tmp exists (do NOT pre-create /System — the Gershwin Makefile
    # checks for /System and skips the entire build if it already exists)
    sudo mkdir -p "${CHROOT_DIR}/tmp"

    # DNS resolution
    sudo cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

    # CA certificates — TCE git/curl look for certs at /usr/local/etc/ssl/certs/
    # (x86_64) or /usr/local/etc/pki/certs/ (aarch64 piCore build).
    sudo mkdir -p "${CHROOT_DIR}/usr/local/etc/ssl/certs"
    sudo cp /etc/ssl/certs/ca-certificates.crt \
        "${CHROOT_DIR}/usr/local/etc/ssl/certs/ca-certificates.crt"
    sudo mkdir -p "${CHROOT_DIR}/usr/local/etc/pki/certs"
    sudo cp /etc/ssl/certs/ca-certificates.crt \
        "${CHROOT_DIR}/usr/local/etc/pki/certs/ca-bundle.crt"
    sudo mkdir -p "${CHROOT_DIR}/etc/ssl/certs"
    sudo cp /etc/ssl/certs/ca-certificates.crt \
        "${CHROOT_DIR}/etc/ssl/certs/ca-certificates.crt"

    # Make /usr/local/lib and /usr/lib visible to the dynamic linker.
    # /usr/lib is where the TCE rootfs installs libgcc_s.so.1 and libstdc++.so.6.
    sudo mkdir -p "${CHROOT_DIR}/etc/ld.so.conf.d"
    echo "/usr/local/lib" | sudo tee "${CHROOT_DIR}/etc/ld.so.conf.d/usr-local.conf" > /dev/null
    echo "/usr/lib"       | sudo tee "${CHROOT_DIR}/etc/ld.so.conf.d/usr-lib.conf"   > /dev/null

    # Bind-mount pseudo-filesystems
    sudo mount -t proc   none "${CHROOT_DIR}/proc"    2>/dev/null || true
    sudo mount -t sysfs  none "${CHROOT_DIR}/sys"     2>/dev/null || true
    sudo mount -o bind   /dev "${CHROOT_DIR}/dev"     2>/dev/null || true
    sudo mount -o bind   /dev/pts "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
}

setup_chroot() {
    case "${TCE_ARCH}" in
        aarch64) setup_chroot_aarch64 ;;
        *)       setup_chroot_x86_64  ;;
    esac
    setup_chroot_common
}

# ---------------------------------------------------------------------------
# Install all build + runtime dependencies from the TCE repository
# ---------------------------------------------------------------------------
install_build_deps() {
    echo "[deps] installing build dependencies from TCE ${TCE_VERSION}/${TCE_ARCH}"

    # GNU tar and full xz — BusyBox tar/xz lack flags needed by gnustep-make install rules
    install_tcz tar
    install_tcz xz

    # Core build toolchain (gcc 14.2.0, binutils, make, etc.)
    install_tcz compiletc

    # clang 19.1.0 from TCE — pulls in llvm19-dev and compiletc
    install_tcz clang

    # Build system
    install_tcz cmake
    install_tcz ninja

    # Source control / autotools
    install_tcz git
    install_tcz autoconf
    install_tcz automake
    install_tcz libtool
    install_tcz pkg-config

    # libs-base deps — package names differ between x86_64 and aarch64 TCE repos
    if [ "${TCE_ARCH}" = "aarch64" ]; then
        install_tcz gnutls-dev        # TLS library (aarch64 name)
        install_tcz icu73-dev         # Unicode / ICU (aarch64 has icu73, not icu74)
        install_tcz libffi_base-dev   # FFI (aarch64 name)
    else
        install_tcz gnutls38-dev      # TLS library (x86_64 name)
        install_tcz icu74-dev         # Unicode / ICU (x86_64 name)
        install_tcz libffi-dev        # FFI (x86_64 name)
    fi
    install_tcz libxml2-dev       # XML
    install_tcz libxslt-dev       # XSLT
    install_tcz openssl-dev       # SSL
    install_tcz curl-dev          # libcurl
    install_tcz libunistring-dev  # Unicode strings
    install_tcz nettle-dev        # Crypto (gnutls dep)
    install_tcz avahi-dev         # Zeroconf / NSNetServices

    # libs-gui / libs-back deps
    install_tcz libX11-dev
    install_tcz libXft-dev        # Font rendering
    install_tcz libXt-dev         # X Toolkit
    install_tcz cairo-dev         # Cairo graphics
    install_tcz libjpeg-turbo-dev # JPEG
    install_tcz libpng-dev        # PNG
    install_tcz tiff-dev          # TIFF
    install_tcz libtiff            # TIFF runtime

    # gershwin-developer extra build deps
    install_tcz libxcb-dev        # XCB (gershwin-windowmanager / XCBKit)
    install_tcz libXrandr-dev     # RandR extension
    install_tcz libXcomposite-dev # Composite extension
    install_tcz libXfixes-dev     # Xfixes (needed by WindowManager / Xcomposite header chain)
    install_tcz libXext-dev       # X extensions
    install_tcz cups-dev          # CUPS (gershwin-components/Printers)
    install_tcz dbus-dev          # D-Bus
    install_tcz linux-pam-dev     # PAM (LoginWindow)
    install_tcz portaudio-dev     # PortAudio (Sound component)
    install_tcz coreutils         # nproc (needed by Functions.sh NPROC_CMD)
    if [ "${TCE_ARCH}" != "aarch64" ]; then
        install_tcz libao-dev     # libao (Sound component, x86_64 only)
    fi

    # Refresh the shared-library cache inside the chroot
    sudo chroot "${CHROOT_DIR}" /sbin/ldconfig 2>/dev/null || true

    # Ensure gmake is available (make.tcz ships 'make', not 'gmake')
    sudo chroot "${CHROOT_DIR}" sh -c \
        '[ -f /usr/local/bin/gmake ] || ln -sf /usr/local/bin/make /usr/local/bin/gmake'

    # Create /etc/apt so Functions.sh detect_platform() selects the "debian" path
    # (make / nproc) — TCE has neither /etc/apt nor /etc/arch-release.
    sudo mkdir -p "${CHROOT_DIR}/etc/apt"

    # linux-pam-dev installs headers to /usr/local/include/pam_*.h but code
    # includes <security/pam_appl.h>. Create a security/ directory of symlinks.
    sudo chroot "${CHROOT_DIR}" sh -c '
        mkdir -p /usr/local/include/security
        for hdr in /usr/local/include/pam_*.h /usr/local/include/_pam_*.h; do
            [ -f "$hdr" ] || continue
            base=$(basename "$hdr")
            target="/usr/local/include/security/$base"
            [ -e "$target" ] || ln -sf "$hdr" "$target"
        done
    '

    echo "[deps] all dependencies installed"
}

# ---------------------------------------------------------------------------
# Build Gershwin inside the chroot using gershwin-developer
# ---------------------------------------------------------------------------
build_gershwin() {
    echo "[build] building Gershwin inside TCE chroot (gershwin-developer)"

    # Write the inner build script — runs as root inside the chroot
    sudo tee "${CHROOT_DIR}/tmp/build-gershwin.sh" > /dev/null << 'INNER'
#!/bin/sh
set -e

# TCE extensions land in /usr/local
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LD_LIBRARY_PATH=/usr/local/lib

# Verify clang is usable
echo "--- clang version ---"
clang --version

# Verify gmake is available
echo "--- gmake version ---"
make --version | head -1

# /System must NOT exist before we start (Makefile skips build if it does)
if [ -d /System ]; then
    echo "ERROR: /System already exists — Makefile would skip the build!"
    exit 1
fi

# Clone gershwin-developer (the developer environment that builds everything)
cd /tmp
git clone --depth=1 \
    https://github.com/gershwin-desktop/gershwin-developer.git \
    gershwin-developer
cd gershwin-developer

# Fetch all source repos (gershwin-system, tools-make, libobjc2,
# libs-base, libs-gui, libs-back, libdispatch, workspaces, components…)
sh ./Library/Scripts/Checkout.sh

# Run the full Gershwin build (Install-System-Domain.sh via Makefile)
FROM_MAKEFILE=1 make install

echo "--- /System contents after build ---"
find /System -maxdepth 3 | head -60
echo "--- /System disk usage ---"
du -sh /System

echo "[build] Gershwin build complete"
INNER

    sudo chmod +x "${CHROOT_DIR}/tmp/build-gershwin.sh"
    sudo chroot "${CHROOT_DIR}" /bin/sh /tmp/build-gershwin.sh
}

# ---------------------------------------------------------------------------
# Package /System from the chroot as a TCZ
# ---------------------------------------------------------------------------
package_output() {
    echo "[package] creating gershwin-system.tcz"

    local staging="/tmp/tce-staging"
    sudo rm -rf "${staging}"
    sudo mkdir -p "${staging}"

    # Copy /System from the chroot into a clean staging directory
    sudo cp -a "${CHROOT_DIR}/System" "${staging}/"

    # Also bundle non-glibc shared libraries that Gershwin's ELFs need
    # (so the TCZ is self-contained — avoids requiring a matching host)
    echo "[package] bundling runtime shared libraries"
    sudo mkdir -p "${staging}/System/Library/Libraries"
    find "${staging}/System" -type f -executable | while IFS= read -r elf; do
        # Check if it is actually an ELF binary / shared library
        file "${elf}" 2>/dev/null | grep -qE "ELF|shared object" || continue
        ldd "${elf}" 2>/dev/null | awk '/=>/{print $3}' | while IFS= read -r lib; do
            [ -f "${lib}" ] || continue
            libname=$(basename "${lib}")
            # Skip standard glibc/kernel-provided libs
            case "${libname}" in
                libc.so*|libm.so*|libpthread.so*|libdl.so*|librt.so*|\
                libutil.so*|libnsl.so*|ld-linux*|libgcc_s.so*)
                    continue ;;
            esac
            dest="${staging}/System/Library/Libraries/${libname}"
            [ -f "${dest}" ] || sudo cp "${lib}" "${dest}"
        done
    done

    # Create the TCZ (SquashFS xz-compressed); show tail of output on failure
    mksquashfs "${staging}" "${BUILD_DIR}/gershwin-system.tcz" \
        -comp xz -b 1M -noappend -no-progress 2>&1 | tail -5
    [ -s "${BUILD_DIR}/gershwin-system.tcz" ] || { echo "ERROR: mksquashfs produced empty file"; exit 1; }

    # Sanity-check: the real Gershwin build should produce at least 10 MB
    tcz_size=$(stat -c%s "${BUILD_DIR}/gershwin-system.tcz" 2>/dev/null || stat -f%z "${BUILD_DIR}/gershwin-system.tcz")
    if [ "${tcz_size}" -lt 10485760 ]; then
        echo "ERROR: gershwin-system.tcz is only ${tcz_size} bytes (< 10 MB)."
        echo "       The Gershwin build likely did not run — check for 'System appears to be already installed'."
        exit 1
    fi

    # Metadata
    md5sum "${BUILD_DIR}/gershwin-system.tcz" \
        > "${BUILD_DIR}/gershwin-system.tcz.md5.txt"

    unsquashfs -l "${BUILD_DIR}/gershwin-system.tcz" 2>/dev/null \
        | sed 's|squashfs-root||' \
        | sort \
        > "${BUILD_DIR}/gershwin-system.tcz.list"

    cat > "${BUILD_DIR}/gershwin-system.tcz.info" << EOF
Title:          gershwin-system.tcz
Description:    Gershwin desktop system (GNUstep + workspace) for ${TCE_ARCH}
Version:        $(date +%Y%m%d)
Author:         Gershwin OS contributors
Original-site:  https://github.com/gershwin-desktop/gershwin-developer
Copying-policy: GPLv3 / LGPLv2+ (see component licenses)
Size:           $(du -sh "${BUILD_DIR}/gershwin-system.tcz" | cut -f1)
Extension_by:   gershwin-on-tce
Tags:           gnustep objc gershwin desktop ${TCE_ARCH}
Comments:       GNUstep-based Gershwin desktop built with clang $(sudo chroot "${CHROOT_DIR}" clang --version 2>/dev/null | head -1) on TCE ${TCE_VERSION}/${TCE_ARCH}
Change-log:     $(date +%Y/%m/%d) initial build
Current:        $(date +%Y/%m/%d) $(date +%Y%m%d)
EOF

    cat > "${BUILD_DIR}/gershwin-system.tcz.dep" << EOF
clang.tcz
compiletc.tcz
libX11.tcz
libXft.tcz
libXt.tcz
cairo.tcz
gnutls38.tcz
icu74.tcz
libxml2.tcz
libxslt.tcz
libffi.tcz
libjpeg-turbo.tcz
libpng.tcz
libtiff.tcz
avahi.tcz
EOF

    echo "[package] done"
    ls -lh "${BUILD_DIR}/gershwin-system.tcz"*
}

# ---------------------------------------------------------------------------
# Helper: download a TCZ and all its runtime deps to a directory.
# Tracks download order (deps-first) in _img_onboot for onboot.lst.
# ---------------------------------------------------------------------------
_img_pkgs=""
_img_onboot=""

download_tcz_to_dir() {
    local pkg dest_dir
    pkg="${1%.tcz}"
    dest_dir="$2"

    # Skip already-processed packages
    case " ${_img_pkgs} " in
        *" ${pkg} "*) return 0 ;;
    esac
    _img_pkgs="${_img_pkgs} ${pkg}"

    # Resolve and download dependencies first
    local deps
    deps=$(wget -qO- "${TCE_TCZ_URL}/${pkg}.tcz.dep" 2>/dev/null | tr -d '\r' || true)
    for dep in ${deps}; do
        dep="${dep%.tcz}"
        [ -n "${dep}" ] && download_tcz_to_dir "${dep}" "${dest_dir}"
    done

    # Download the TCZ (use the shared cache)
    local tcz="${CACHE_DIR}/${pkg}.tcz"
    mkdir -p "${CACHE_DIR}"
    if [ ! -s "${tcz}" ]; then
        if ! wget -q -O "${tcz}" "${TCE_TCZ_URL}/${pkg}.tcz"; then
            echo "  [img-tcz] WARNING: ${pkg}.tcz not found, skipping"
            rm -f "${tcz}"
            return 0
        fi
    fi

    echo "  [img-tcz] ${pkg}"
    sudo cp "${tcz}" "${dest_dir}/${pkg}.tcz"
    _img_onboot="${_img_onboot}${pkg}.tcz
"
}

# ---------------------------------------------------------------------------
# Create a minimal autostart TCZ that launches X + Gershwin at boot.
# Installed to /opt/bootlocal.sh (run by TCE at end of boot) and
# /home/tc/.xsession (run by startx).
# ---------------------------------------------------------------------------
create_autostart_tcz() {
    local dest_dir="$1"
    local staging="/tmp/autostart-tcz-staging"

    sudo rm -rf "${staging}"
    sudo mkdir -p "${staging}/opt"

    # bootlocal.sh — TCE runs this at the end of boot sequence
    sudo tee "${staging}/opt/bootlocal.sh" > /dev/null << 'BOOTLOCAL'
#!/bin/sh
# Auto-start Gershwin desktop
su - tc -c 'DISPLAY=:0 startx' &
BOOTLOCAL
    sudo chmod +x "${staging}/opt/bootlocal.sh"

    # .xsession — called by startx to decide what runs in X
    sudo mkdir -p "${staging}/home/tc"
    sudo tee "${staging}/home/tc/.xsession" > /dev/null << 'XSESSION'
#!/bin/sh
export PATH=/System/Library/Tools:/usr/local/bin:/usr/bin:/bin
export GNUSTEP_MAKEFILES=/System/Library/Makefiles
export GNUSTEP_USER_ROOT=/home/tc/GNUstep
mkdir -p "${GNUSTEP_USER_ROOT}/Library/ApplicationSupport"
exec /System/Library/CoreServices/Workspace.app/Workspace
XSESSION
    sudo chmod +x "${staging}/home/tc/.xsession"

    mksquashfs "${staging}" "${dest_dir}/gershwin-autostart.tcz" \
        -noappend -no-progress > /dev/null 2>&1
    echo "  [img-tcz] gershwin-autostart (autostart extension)"
}

# ---------------------------------------------------------------------------
# Create a bootable x86_64 disk image (syslinux + TCE + Gershwin + Xorg)
# ---------------------------------------------------------------------------
make_image_x86_64() {
    echo "[image] creating bootable x86_64 disk image"

    local img="${BUILD_DIR}/gershwin-x86_64.img"
    local img_mb=2048

    # Extra host tools
    sudo apt-get install -y -qq syslinux syslinux-utils dosfstools parted

    # Download the TCE kernel (cached)
    local vmlinuz="/tmp/vmlinuz64"
    if [ ! -s "${vmlinuz}" ]; then
        wget -q "http://www.tinycorelinux.net/16.x/x86_64/release/distribution_files/vmlinuz64" \
            -O "${vmlinuz}"
    fi

    # Create raw disk image
    sudo rm -f "${img}"
    dd if=/dev/zero of="${img}" bs=1M count="${img_mb}" status=none

    # Partition: 1MiB gap | 80MiB FAT32 boot (p1) | rest ext4 TCE storage (p2)
    parted -s "${img}" \
        mklabel msdos \
        mkpart primary fat32 1MiB 81MiB \
        set 1 boot on \
        mkpart primary ext4 81MiB 100%

    local loop
    loop=$(sudo losetup -Pf --show "${img}")

    sudo mkfs.vfat -F 32 -n TCEBOOT "${loop}p1"
    sudo mkfs.ext4 -q -L TCESTORE  "${loop}p2"

    # Install syslinux MBR and FAT-partition bootloader
    local mbr_bin
    for mbr_bin in /usr/lib/syslinux/mbr/mbr.bin /usr/lib/syslinux/mbr.bin; do
        [ -f "${mbr_bin}" ] && break
    done
    sudo dd if="${mbr_bin}" of="${loop}" bs=440 count=1 conv=notrunc 2>/dev/null
    sudo syslinux --install "${loop}p1"

    # Populate boot partition (p1)
    local boot_mnt="/tmp/img-boot-x86"
    sudo mkdir -p "${boot_mnt}"
    sudo mount "${loop}p1" "${boot_mnt}"
    sudo cp /tmp/corepure64.gz "${boot_mnt}/corepure64.gz"
    sudo cp "${vmlinuz}"       "${boot_mnt}/vmlinuz64"
    sudo tee "${boot_mnt}/syslinux.cfg" > /dev/null << 'SYSCONFIG'
TIMEOUT 50
PROMPT 0
DEFAULT gershwin

LABEL gershwin
  MENU LABEL Gershwin Desktop (TCE 16.x)
  KERNEL vmlinuz64
  INITRD corepure64.gz
  APPEND quiet tce=sda2 nozswap waitusb=5 noswap
SYSCONFIG
    sudo umount "${boot_mnt}"

    # Populate TCE storage partition (p2)
    local store_mnt="/tmp/img-store-x86"
    sudo mkdir -p "${store_mnt}"
    sudo mount "${loop}p2" "${store_mnt}"
    sudo mkdir -p "${store_mnt}/tce/optional"

    # Copy the Gershwin TCZ (already built)
    sudo cp "${BUILD_DIR}/gershwin-system.tcz" "${store_mnt}/tce/optional/"

    # clang + compiletc (binutils → libbfd) needed at runtime for ObjC JIT / plugins
    _img_pkgs="" ; _img_onboot=""
    download_tcz_to_dir compiletc          "${store_mnt}/tce/optional"
    download_tcz_to_dir clang              "${store_mnt}/tce/optional"

    # Download Xorg bundle (Xorg-7.7.tcz pulls xorg-server + vesa + input + fonts)
    download_tcz_to_dir Xorg-7.7           "${store_mnt}/tce/optional"

    # Gershwin runtime libraries
    download_tcz_to_dir libX11              "${store_mnt}/tce/optional"
    download_tcz_to_dir libXft              "${store_mnt}/tce/optional"
    download_tcz_to_dir libXt               "${store_mnt}/tce/optional"
    download_tcz_to_dir cairo               "${store_mnt}/tce/optional"
    download_tcz_to_dir gnutls38            "${store_mnt}/tce/optional"
    download_tcz_to_dir icu74               "${store_mnt}/tce/optional"
    download_tcz_to_dir libxml2             "${store_mnt}/tce/optional"
    download_tcz_to_dir libxslt             "${store_mnt}/tce/optional"
    download_tcz_to_dir libffi              "${store_mnt}/tce/optional"
    download_tcz_to_dir libjpeg-turbo       "${store_mnt}/tce/optional"
    download_tcz_to_dir libpng              "${store_mnt}/tce/optional"
    download_tcz_to_dir libtiff             "${store_mnt}/tce/optional"
    download_tcz_to_dir avahi               "${store_mnt}/tce/optional"

    # Autostart extension (boots into Gershwin automatically)
    create_autostart_tcz "${store_mnt}/tce/optional"

    # Write onboot.lst (deps-first order from download tracking, then gershwin + autostart last)
    printf '%s' "${_img_onboot}" | sudo tee "${store_mnt}/tce/onboot.lst" > /dev/null
    printf '%s\n' "gershwin-system.tcz" "gershwin-autostart.tcz" \
        | sudo tee -a "${store_mnt}/tce/onboot.lst" > /dev/null

    echo "[image] x86_64 storage contents ($(du -sh "${store_mnt}/tce/optional" | cut -f1)):"
    ls -lh "${store_mnt}/tce/optional/"
    sudo umount "${store_mnt}"
    sudo losetup -d "${loop}"

    echo "[image] compressing x86_64 image (${img_mb} MB) ..."
    gzip -9 "${img}"
    echo "[image] x86_64 image: $(ls -lh "${img}.gz")"

    local gz_size
    gz_size=$(stat -c%s "${img}.gz")
    if [ "${gz_size}" -lt 83886080 ]; then
        echo "WARNING: gershwin-x86_64.img.gz is only ${gz_size} bytes (< 80 MB); image may be incomplete"
    fi
}

# ---------------------------------------------------------------------------
# Create a bootable aarch64 Pi disk image (expand piCore64 + add Gershwin + Xorg)
# ---------------------------------------------------------------------------
make_image_aarch64() {
    echo "[image] creating bootable aarch64 Pi disk image"

    local base_img="/tmp/picore64.img"
    local img="${BUILD_DIR}/gershwin-aarch64.img"
    local img_mb=2048

    # Extra host tools (parted, e2fsprogs)
    sudo apt-get install -y -qq parted e2fsprogs

    # Start from the piCore64 base image (already downloaded for chroot setup)
    sudo cp "${base_img}" "${img}"

    # Expand the raw image file to target size, then resize p2 via parted
    sudo truncate -s "${img_mb}M" "${img}"
    sudo parted -s "${img}" resizepart 2 100%

    local loop
    loop=$(sudo losetup -Pf --show "${img}")

    # Fix and expand the ext4 filesystem on p2 to use the new space
    sudo e2fsck -f -y "${loop}p2" 2>/dev/null || true
    sudo resize2fs "${loop}p2"

    # Populate the TCE storage partition (p2)
    local store_mnt="/tmp/img-store-arm"
    sudo mkdir -p "${store_mnt}"
    sudo mount "${loop}p2" "${store_mnt}"
    sudo mkdir -p "${store_mnt}/tce/optional"

    # Copy the Gershwin TCZ (already built)
    sudo cp "${BUILD_DIR}/gershwin-system.tcz" "${store_mnt}/tce/optional/"

    # clang + compiletc (binutils → libbfd) needed at runtime for ObjC JIT / plugins
    _img_pkgs="" ; _img_onboot=""
    download_tcz_to_dir compiletc          "${store_mnt}/tce/optional"
    download_tcz_to_dir clang              "${store_mnt}/tce/optional"

    # Download aarch64 Xorg bundle and runtime dependencies
    download_tcz_to_dir Xorg                "${store_mnt}/tce/optional"

    # Gershwin runtime libraries (aarch64 package names)
    download_tcz_to_dir libX11              "${store_mnt}/tce/optional"
    download_tcz_to_dir libXft              "${store_mnt}/tce/optional"
    download_tcz_to_dir libXt               "${store_mnt}/tce/optional"
    download_tcz_to_dir cairo               "${store_mnt}/tce/optional"
    download_tcz_to_dir gnutls              "${store_mnt}/tce/optional"
    download_tcz_to_dir icu73               "${store_mnt}/tce/optional"
    download_tcz_to_dir libxml2             "${store_mnt}/tce/optional"
    download_tcz_to_dir libxslt             "${store_mnt}/tce/optional"
    download_tcz_to_dir libffi7             "${store_mnt}/tce/optional"
    download_tcz_to_dir libjpeg-turbo       "${store_mnt}/tce/optional"
    download_tcz_to_dir libpng              "${store_mnt}/tce/optional"
    download_tcz_to_dir libtiff             "${store_mnt}/tce/optional"
    download_tcz_to_dir avahi               "${store_mnt}/tce/optional"

    # Autostart extension (boots into Gershwin automatically)
    create_autostart_tcz "${store_mnt}/tce/optional"

    # Write onboot.lst
    printf '%s' "${_img_onboot}" | sudo tee "${store_mnt}/tce/onboot.lst" > /dev/null
    printf '%s\n' "gershwin-system.tcz" "gershwin-autostart.tcz" \
        | sudo tee -a "${store_mnt}/tce/onboot.lst" > /dev/null

    echo "[image] aarch64 storage contents ($(du -sh "${store_mnt}/tce/optional" | cut -f1)):"
    ls -lh "${store_mnt}/tce/optional/"
    sudo umount "${store_mnt}"
    sudo losetup -d "${loop}"

    echo "[image] compressing aarch64 image (${img_mb} MB) ..."
    gzip -9 "${img}"
    echo "[image] aarch64 image: $(ls -lh "${img}.gz")"

    local gz_size
    gz_size=$(stat -c%s "${img}.gz")
    if [ "${gz_size}" -lt 83886080 ]; then
        echo "WARNING: gershwin-aarch64.img.gz is only ${gz_size} bytes (< 80 MB); image may be incomplete"
    fi
}

# ---------------------------------------------------------------------------
# Create bootable disk image (arch dispatcher)
# ---------------------------------------------------------------------------
make_image() {
    case "${TCE_ARCH}" in
        aarch64) make_image_aarch64 ;;
        *)       make_image_x86_64  ;;
    esac
}

# ---------------------------------------------------------------------------
# Cleanup helper (unmount pseudo-filesystems on exit)
# ---------------------------------------------------------------------------
cleanup() {
    echo "[cleanup] unmounting pseudo-filesystems"
    sudo umount -l "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
    sudo umount -l "${CHROOT_DIR}/dev"     2>/dev/null || true
    sudo umount -l "${CHROOT_DIR}/sys"     2>/dev/null || true
    sudo umount -l "${CHROOT_DIR}/proc"    2>/dev/null || true
    # Clean up any image loop devices
    sudo losetup -a 2>/dev/null \
        | grep -E "gershwin.*\.img" \
        | cut -d: -f1 \
        | while read -r ldev; do sudo losetup -d "${ldev}" 2>/dev/null || true; done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
install_host_deps
setup_chroot
install_build_deps
build_gershwin
package_output
make_image

echo ""
echo "=== Build complete ==="
echo "Artifacts:"
ls -lh "${BUILD_DIR}/gershwin-system.tcz"* "${BUILD_DIR}/gershwin-${TCE_ARCH}.img.gz" 2>/dev/null || \
    ls -lh "${BUILD_DIR}/gershwin-system.tcz"*

