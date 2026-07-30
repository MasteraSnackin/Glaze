#!/bin/bash
set -e

# Change to the root of the project
cd "$(dirname "$0")/.."

APP_NAME="glaze-flutter"
# Extract version from pubspec.yaml (e.g. 0.7.0)
VERSION=$(grep '^version:' pubspec.yaml | sed 's/version: //g' | cut -d '+' -f 1 | tr -d '\r')
ARCH=$(uname -m)

if [ -z "$VERSION" ]; then
    echo "Error: Could not determine version from pubspec.yaml"
    exit 1
fi

echo "Building $APP_NAME version $VERSION for architecture $ARCH..."

if [ "$ARCH" = "x86_64" ]; then
    DEB_ARCH="amd64"
elif [ "$ARCH" = "aarch64" ]; then
    DEB_ARCH="arm64"
else
    DEB_ARCH="$ARCH"
fi

# Run the flutter build
echo "Running flutter build linux --release $@"
flutter build linux --release "$@"

BUNDLE_DIR="build/linux/x64/release/bundle"

if [ ! -d "$BUNDLE_DIR" ]; then
    echo "Error: Build directory '$BUNDLE_DIR' not found. Did the build fail?"
    exit 1
fi

# 1. Build DEB Package
if command -v dpkg-deb &> /dev/null; then
    echo "Building .deb package..."
    DEB_DIR="build/linux/deb/$APP_NAME-${VERSION}_$DEB_ARCH"
    mkdir -p "$DEB_DIR/opt/$APP_NAME"
    mkdir -p "$DEB_DIR/usr/bin"
    mkdir -p "$DEB_DIR/usr/share/applications"
    mkdir -p "$DEB_DIR/usr/share/icons/hicolor/512x512/apps"
    mkdir -p "$DEB_DIR/DEBIAN"

    # Copy bundle contents
    cp -r $BUNDLE_DIR/* "$DEB_DIR/opt/$APP_NAME/"
    
    # Create symlink for the executable
    ln -sf "/opt/$APP_NAME/glaze_flutter" "$DEB_DIR/usr/bin/$APP_NAME"

    # Copy icon
    if [ -f "assets/logos/glaze.png" ]; then
        cp assets/logos/glaze.png "$DEB_DIR/usr/share/icons/hicolor/512x512/apps/$APP_NAME.png"
    else
        echo "Warning: assets/logos/glaze.png not found, skipping icon."
    fi

    # Create .desktop file
    cat <<EOF > "$DEB_DIR/usr/share/applications/$APP_NAME.desktop"
[Desktop Entry]
Name=Glaze
Comment=Native LLM frontend for AI roleplay
Exec=$APP_NAME
Icon=$APP_NAME
Terminal=false
Type=Application
Categories=Utility;Chat;Network;
EOF

    # Create DEBIAN/control
    cat <<EOF > "$DEB_DIR/DEBIAN/control"
Package: $APP_NAME
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: Glaze Developers
Description: AI chat client
 Glaze is a Native LLM frontend for AI roleplay.
EOF

    # Build the package. Guarded by an if so a dpkg-deb failure doesn't trip
    # `set -e` and abort the whole script before the pacman package below gets
    # a chance to build — each format's failure is independent and reported as
    # a warning, not a fatal script error.
    if dpkg-deb --build "$DEB_DIR"; then
        echo "Deb package created at build/linux/deb/$APP_NAME-${VERSION}_$DEB_ARCH.deb"
    else
        echo "::warning::dpkg-deb failed — no .deb package was produced."
    fi
else
    echo "dpkg-deb not found. Skipping .deb package creation."
fi

# 2. Build Pacman Package (Arch / CachyOS)
if command -v makepkg &> /dev/null; then
    echo "Building pacman package..."
    ARCH_DIR="build/linux/arch"
    mkdir -p "$ARCH_DIR"
    
    # Generate PKGBUILD for pre-built binaries
    cat <<EOF > "$ARCH_DIR/PKGBUILD"
pkgname=$APP_NAME-bin
pkgver=$VERSION
pkgrel=1
pkgdesc="Native LLM frontend for AI roleplay (Flutter)"
arch=('x86_64')
url="https://github.com/hydall/Glaze"
license=('AGPL3')
depends=('gtk3' 'glib2' 'sqlite3')
options=('!strip' '!emptydirs')

package() {
    mkdir -p "\$pkgdir/opt/$APP_NAME"
    mkdir -p "\$pkgdir/usr/bin"
    mkdir -p "\$pkgdir/usr/share/applications"
    mkdir -p "\$pkgdir/usr/share/icons/hicolor/512x512/apps"

    # Copy from the flutter release bundle
    cp -r "\$srcdir/../../x64/release/bundle/"* "\$pkgdir/opt/$APP_NAME/"
    
    # Symlink binary
    ln -s "/opt/$APP_NAME/glaze_flutter" "\$pkgdir/usr/bin/$APP_NAME"
    
    # Copy icon
    if [ -f "\$srcdir/../../../../assets/logos/glaze.png" ]; then
        cp "\$srcdir/../../../../assets/logos/glaze.png" "\$pkgdir/usr/share/icons/hicolor/512x512/apps/$APP_NAME.png"
    fi

    # Create desktop file
    cat <<DESKTOP > "\$pkgdir/usr/share/applications/$APP_NAME.desktop"
[Desktop Entry]
Name=Glaze
Comment=Native LLM frontend for AI roleplay
Exec=$APP_NAME
Icon=$APP_NAME
Terminal=false
Type=Application
Categories=Utility;Chat;Network;
DESKTOP
}
EOF

    # Build the package using makepkg. --nodeps skips the depends=() check: the
    # CI runner has no configured pacman repositories, so -s (syncdeps) cannot
    # resolve anything, and even the local-only check can fail outright on a
    # bare Ubuntu runner ("failed to initialize alpm library ... could not
    # create database") before /var/lib/pacman exists. A real `pacman -U`
    # install still enforces depends=() using the target machine's own
    # database, so skipping the check here only affects this build step.
    # We do not use sudo with makepkg. Guarded the same way as the .deb build
    # above, so a makepkg failure doesn't abort the script and lose a .deb that
    # already built successfully.
    cd "$ARCH_DIR"
    if makepkg -f --nodeps --noconfirm; then
        cd - > /dev/null
        echo "Pacman package created in $ARCH_DIR"
    else
        cd - > /dev/null
        echo "::warning::makepkg failed — no pacman package was produced. See the log above for the pacman/alpm error."
    fi
else
    echo "makepkg not found. Skipping pacman package creation."
fi

echo "Packaging complete!"
