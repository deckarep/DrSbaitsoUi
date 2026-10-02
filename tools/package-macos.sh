#!/usr/bin/env bash
# Builds Dr. Sbaitso: Reborn as macOS .app bundles for Apple Silicon and Intel
# (cross-compiled by Zig, ReleaseSafe) and zips each one for a GitHub release.
# Run via `make macos-app`. Output: zig-out/dist/
#
# The speech engine (libsbaitso_native.a) is built inside the private
# DrSbaitsoLib project for each arch and linked from there; it is never
# copied into this repo (it ends up compiled into the executable only).
set -euo pipefail

cd "$(dirname "$0")/.."

SBAITSO_LIB="${SBAITSO_LIB:-../DrSbaitsoLib}"
APP_VERSION="${APP_VERSION:-1.0.0}"
MACOS_MIN="${MACOS_MIN:-11.0}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"

APP_NAME="Dr. Sbaitso Reborn"
EXE_NAME="DrSbaitsoUI"
BUNDLE_ID="com.deckarep.drsbaitso-reborn"
DIST="zig-out/dist"

if [[ ! -d "$SBAITSO_LIB" ]]; then
    echo "error: DrSbaitsoLib not found at $SBAITSO_LIB (set SBAITSO_LIB=...)" >&2
    exit 1
fi
SBAITSO_LIB="$(cd "$SBAITSO_LIB" && pwd)"

mkdir -p "$DIST"

# The app icon, made from the monitor artwork padded to a square.
make_icns() {
    local out="$1" work="$DIST/AppIcon.iconset" square="$DIST/icon-square.png"
    rm -rf "$work" && mkdir -p "$work"
    sips -p 1057 1057 resources/textures/DrSbaitsoMonitor.png --out "$square" >/dev/null
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$square" --out "$work/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$square" --out "$work/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$work" -o "$out"
    rm -rf "$work" "$square"
}

ICNS="$DIST/AppIcon.icns"
make_icns "$ICNS"

for arch in arm64 x86_64; do
    case "$arch" in
        arm64) zig_arch=aarch64; label="AppleSilicon" ;;
        x86_64) zig_arch=x86_64; label="Intel" ;;
    esac
    triple="$zig_arch-macos.$MACOS_MIN"
    echo "==> $label ($triple, $OPTIMIZE)"

    # 1. Speech engine for this arch, built (and kept) in DrSbaitsoLib.
    lib_prefix="zig-out/native-$zig_arch-macos"
    (cd "$SBAITSO_LIB" && zig build port-lib -Dtarget="$triple" -Doptimize="$OPTIMIZE" -p "$lib_prefix")

    # 2. The app itself.
    exe_prefix="zig-out/macos-$arch"
    zig build -Dtarget="$triple" -Doptimize="$OPTIMIZE" \
        -Dsbaitso-lib-file="$SBAITSO_LIB/$lib_prefix/lib/libsbaitso_native.a" \
        -p "$exe_prefix"

    # 3. The .app bundle.
    app="$DIST/$label/$APP_NAME.app"
    rm -rf "$DIST/$label" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$exe_prefix/bin/$EXE_NAME" "$app/Contents/MacOS/"
    cp "$ICNS" "$app/Contents/Resources/AppIcon.icns"
    # main.zig switches to Contents/Resources at startup and loads resources/ from there.
    rsync -a --exclude .DS_Store resources "$app/Contents/Resources/"

    cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Dr. Sbaitso: Reborn</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>$APP_VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MACOS_MIN</string>
    <key>LSArchitecturePriority</key>
    <array><string>$arch</string></array>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

    # Ad-hoc signature: required for arm64, and seals the bundle. Not notarized,
    # so other Macs will still need right-click > Open the first time.
    codesign --force --deep --sign - "$app"

    zip="$DIST/DrSbaitsoReborn-$APP_VERSION-macOS-$label.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    echo "    $app"
    echo "    $zip"
done

rm -f "$ICNS"
