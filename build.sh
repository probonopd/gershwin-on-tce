#!/bin/sh
#
# Build script for Gershwin Desktop on Tiny Core Linux (TCE)
#
# This script:
# 1. Clones gershwin-developer and all its sub-repositories
# 2. Installs build dependencies (Debian packages)
# 3. Builds the entire Gershwin Desktop into /System/Library/
# 4. Packages the result into a .tcz (SquashFS) extension
#
# TCE .tcz files are SquashFS compressed filesystem images.
# Building is done on Debian because TCE's package repository lacks
# many development libraries needed for compilation.
# The resulting .tcz is loadable on any compatible TCE system.
#
# Usage: sudo ./build.sh
#
set -e

# --- Configuration ---
GERSHWIN_REPO="https://github.com/gershwin-desktop/gershwin-developer.git"
GERSHWIN_BRANCH="${GERSHWIN_BRANCH:-main}"
BUILD_DIR="${BUILD_DIR:-/tmp/gershwin-build}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/artifacts}"
TCZ_NAME="gershwin"
# Target: Tiny Core Linux 15.x
# Build on Debian oldstable (bookworm, glibc 2.36) for TCE compatibility
# TCE 15.x x86_64 uses glibc 2.38, aarch64 uses glibc 2.39

# --- Preflight checks ---
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root."
    exit 1
fi

if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "Error: mksquashfs not found. Install squashfs-tools."
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Error: git not found."
    exit 1
fi

echo "=== Gershwin TCE Build ==="
echo "Build directory: $BUILD_DIR"
echo "Output directory: $OUTPUT_DIR"

# --- Clone gershwin-developer ---
echo ""
echo "=== Cloning gershwin-developer ==="
if [ -d "$BUILD_DIR/gershwin-developer" ]; then
    echo "Already cloned, updating..."
    cd "$BUILD_DIR/gershwin-developer"
    git pull --ff-only || true
else
    mkdir -p "$BUILD_DIR"
    git clone --depth 1 -b "$GERSHWIN_BRANCH" "$GERSHWIN_REPO" "$BUILD_DIR/gershwin-developer"
    cd "$BUILD_DIR/gershwin-developer"
fi

# --- Install build dependencies ---
echo ""
echo "=== Installing build dependencies ==="
./Library/Scripts/Bootstrap.sh

# --- Checkout sub-repositories ---
echo ""
echo "=== Checking out source repositories ==="
PINNED=1 ./Library/Scripts/Checkout.sh

# --- Build ---
echo ""
echo "=== Building Gershwin Desktop ==="
make install

# --- Package as .tcz ---
echo ""
echo "=== Packaging as TCE extension (.tcz) ==="
mkdir -p "$OUTPUT_DIR"

# Create the .tcz (SquashFS image with XZ compression)
mksquashfs /System "$OUTPUT_DIR/${TCZ_NAME}.tcz" \
    -comp xz -b 1M -noappend

# Generate file list
unsquashfs -l "$OUTPUT_DIR/${TCZ_NAME}.tcz" | \
    grep -v "^squashfs-root$" | \
    sed 's|^squashfs-root||' | \
    sort > "$OUTPUT_DIR/${TCZ_NAME}.tcz.list"

# Generate MD5 checksum
cd "$OUTPUT_DIR"
md5sum "${TCZ_NAME}.tcz" > "${TCZ_NAME}.tcz.md5.txt"

# Generate .tcz.info metadata
TIMESTAMP=$(date +%Y/%m/%d)
SIZE=$(du -h "${TCZ_NAME}.tcz" | cut -f1)
cat > "${TCZ_NAME}.tcz.info" << EOF
Title:          ${TCZ_NAME}.tcz
Description:    Gershwin Desktop Environment based on GNUstep
Version:        $(date +%Y%m%d)
Author:         Gershwin Desktop Project
Original-site:  https://github.com/gershwin-desktop
Copying-policy: MIT
Size:           ${SIZE}
Extension_by:   gershwin-on-tce
Tags:           DESKTOP GNUSTEP WINDOWMANAGER GUI
Comments:       Complete Gershwin Desktop built from gershwin-developer.
                Installs to /System/Library/. Start with:
                startx /System/Library/Scripts/Gershwin.sh
Change-log:     ${TIMESTAMP} Initial build
Current:        ${TIMESTAMP}
EOF

# Generate runtime dependency list (TCE 15.x extensions needed at runtime)
# Package names verified against http://repo.tinycorelinux.net/15.x/
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
cat > "${TCZ_NAME}.tcz.dep" << EOF
Xorg-7.7-lib.tcz
libX11.tcz
libXext.tcz
libXrender.tcz
cairo.tcz
libpng.tcz
libtiff.tcz
libjpeg-turbo.tcz
libxml2.tcz
libxslt.tcz
gnutls38.tcz
libffi.tcz
icu74.tcz
giflib7.tcz
libao.tcz
portaudio.tcz
dbus.tcz
cups.tcz
libxcb.tcz
libXft.tcz
libXrandr.tcz
libXcomposite.tcz
libXt.tcz
avahi.tcz
imagemagick.tcz
freeglut.tcz
EOF
elif [ "$ARCH" = "aarch64" ]; then
cat > "${TCZ_NAME}.tcz.dep" << EOF
libX11.tcz
libXext.tcz
libXrender.tcz
cairo.tcz
libpng.tcz
libtiff.tcz
libjpeg-turbo.tcz
libxml2.tcz
libxslt.tcz
gnutls.tcz
libffi7.tcz
icu73.tcz
giflib.tcz
portaudio.tcz
dbus.tcz
cups.tcz
libxcb.tcz
libXft.tcz
libXrandr.tcz
libXcomposite.tcz
libXt.tcz
avahi.tcz
EOF
else
  echo "Warning: Unknown architecture $ARCH, generating empty dep file"
  : > "${TCZ_NAME}.tcz.dep"
fi

echo ""
echo "=== Build complete ==="
echo "Output files:"
ls -lh "$OUTPUT_DIR/${TCZ_NAME}"*
echo ""
echo "To install on Tiny Core Linux:"
echo "  tce-load -i ${TCZ_NAME}.tcz"
echo "  startx /System/Library/Scripts/Gershwin.sh"
