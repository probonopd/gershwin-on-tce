#!/bin/sh
# Build Gershwin in a Tiny Core Linux 16.x chroot using the existing clang.tcz
# from the official TCE repository.  No Docker required; pure chroot.

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
TCE_VERSION="16.x"
TCE_ARCH="x86_64"
TCE_BASE_URL="http://www.tinycorelinux.net/${TCE_VERSION}/${TCE_ARCH}"
TCE_TCZ_URL="${TCE_BASE_URL}/tcz"
TCE_CORE_URL="${TCE_BASE_URL}/release/distribution_files/corepure64.gz"

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
        cpio squashfs-tools wget xz-utils git
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
# Set up the TCE 16.x chroot
# ---------------------------------------------------------------------------
setup_chroot() {
    echo "[setup] creating TCE ${TCE_VERSION} chroot at ${CHROOT_DIR}"
    mkdir -p "${CHROOT_DIR}"

    # Download base root filesystem
    local gz="/tmp/corepure64.gz"
    if [ ! -s "${gz}" ]; then
        wget -q "${TCE_CORE_URL}" -O "${gz}"
    fi

    # Extract initramfs
    cd "${CHROOT_DIR}"
    zcat "${gz}" | sudo cpio -idm 2>/dev/null || true
    cd -

    # Make /usr/local tree available inside the chroot
    sudo mkdir -p \
        "${CHROOT_DIR}/usr/local/bin" \
        "${CHROOT_DIR}/usr/local/lib" \
        "${CHROOT_DIR}/usr/local/include" \
        "${CHROOT_DIR}/usr/local/lib/pkgconfig"

    # Ensure /tmp and /System exist
    sudo mkdir -p "${CHROOT_DIR}/tmp" "${CHROOT_DIR}/System"

    # DNS resolution
    sudo cp /etc/resolv.conf "${CHROOT_DIR}/etc/resolv.conf"

    # CA certificates — TCE git/curl are compiled with /usr/local prefix and
    # look for certs at /usr/local/etc/ssl/certs/ca-certificates.crt
    sudo mkdir -p "${CHROOT_DIR}/usr/local/etc/ssl/certs"
    sudo cp /etc/ssl/certs/ca-certificates.crt \
        "${CHROOT_DIR}/usr/local/etc/ssl/certs/ca-certificates.crt"
    # Also place them where standard tools expect them
    sudo mkdir -p "${CHROOT_DIR}/etc/ssl/certs"
    sudo cp /etc/ssl/certs/ca-certificates.crt \
        "${CHROOT_DIR}/etc/ssl/certs/ca-certificates.crt"

    # Make /usr/local/lib visible to the dynamic linker inside chroot
    sudo mkdir -p "${CHROOT_DIR}/etc/ld.so.conf.d"
    echo "/usr/local/lib" | sudo tee "${CHROOT_DIR}/etc/ld.so.conf.d/usr-local.conf" > /dev/null

    # Bind-mount pseudo-filesystems
    sudo mount -t proc   none "${CHROOT_DIR}/proc"    2>/dev/null || true
    sudo mount -t sysfs  none "${CHROOT_DIR}/sys"     2>/dev/null || true
    sudo mount -o bind   /dev "${CHROOT_DIR}/dev"     2>/dev/null || true
    sudo mount -o bind   /dev/pts "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Install all build + runtime dependencies from the TCE 16.x repository
# ---------------------------------------------------------------------------
install_build_deps() {
    echo "[deps] installing build dependencies from TCE ${TCE_VERSION}"

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
    install_tcz libtool
    install_tcz pkg-config

    # libs-base deps
    install_tcz gnutls38-dev      # TLS library
    install_tcz icu74-dev         # Unicode / ICU
    install_tcz libxml2-dev       # XML
    install_tcz libxslt-dev       # XSLT
    install_tcz libffi-dev        # FFI
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

    # Refresh the shared-library cache inside the chroot
    sudo chroot "${CHROOT_DIR}" /sbin/ldconfig 2>/dev/null || true

    echo "[deps] all dependencies installed"
}

# ---------------------------------------------------------------------------
# Build Gershwin inside the chroot
# ---------------------------------------------------------------------------
build_gershwin() {
    echo "[build] building Gershwin inside TCE chroot"

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

# Clone Gershwin system repository (includes all GNUstep submodules)
cd /tmp
git clone --recurse-submodules \
    https://github.com/gershwin-desktop-legacy/system.git \
    gershwin-system
cd gershwin-system

# The Makefile installs to /System and detects WORKDIR automatically.
# It builds: tools-make → libobjc2 (cmake/clang) → libs-base →
#            libs-gui → libs-back → workspace → apps-systempreferences →
#            dubstep-dark-theme
make install

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

    # Metadata
    md5sum "${BUILD_DIR}/gershwin-system.tcz" \
        > "${BUILD_DIR}/gershwin-system.tcz.md5.txt"

    unsquashfs -l "${BUILD_DIR}/gershwin-system.tcz" 2>/dev/null \
        | sed 's|squashfs-root||' \
        | sort \
        > "${BUILD_DIR}/gershwin-system.tcz.list"

    cat > "${BUILD_DIR}/gershwin-system.tcz.info" << EOF
Title:          gershwin-system.tcz
Description:    Gershwin desktop system (GNUstep + workspace)
Version:        $(date +%Y%m%d)
Author:         Gershwin OS contributors
Original-site:  https://github.com/gershwin-desktop-legacy/system
Copying-policy: GPLv3 / LGPLv2+ (see component licenses)
Size:           $(du -sh "${BUILD_DIR}/gershwin-system.tcz" | cut -f1)
Extension_by:   gershwin-on-tce
Tags:           gnustep objc gershwin desktop
Comments:       GNUstep-based Gershwin desktop built with clang $(sudo chroot "${CHROOT_DIR}" clang --version 2>/dev/null | head -1) on TCE ${TCE_VERSION}
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
# Cleanup helper (unmount pseudo-filesystems on exit)
# ---------------------------------------------------------------------------
cleanup() {
    echo "[cleanup] unmounting pseudo-filesystems"
    sudo umount -l "${CHROOT_DIR}/dev/pts" 2>/dev/null || true
    sudo umount -l "${CHROOT_DIR}/dev"     2>/dev/null || true
    sudo umount -l "${CHROOT_DIR}/sys"     2>/dev/null || true
    sudo umount -l "${CHROOT_DIR}/proc"    2>/dev/null || true
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

echo ""
echo "=== Build complete ==="
echo "Artifacts:"
ls -lh "${BUILD_DIR}/gershwin-system.tcz"*
