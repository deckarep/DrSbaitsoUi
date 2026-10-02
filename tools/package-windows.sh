#!/usr/bin/env bash
# Builds Dr. Sbaitso: Reborn for 64-bit Windows (cross-compiled by Zig,
# ReleaseSafe) and zips it for a GitHub release. Run via `make windows-app`.
# Output: zig-out/dist/
#
# The zip holds a folder with the .exe (icon + version info embedded, no
# console window) and resources/ next to it; Windows apps are usually shipped
# like this, unzipped anywhere and run in place.
#
# The speech engine (sbaitso_native.lib) is built inside the private
# DrSbaitsoLib project and linked from there; it is never copied into this
# repo (it ends up compiled into the executable only).
set -euo pipefail

cd "$(dirname "$0")/.."

SBAITSO_LIB="${SBAITSO_LIB:-../DrSbaitsoLib}"
APP_VERSION="${APP_VERSION:-1.0.0}"
OPTIMIZE="${OPTIMIZE:-ReleaseSafe}"

APP_NAME="Dr. Sbaitso Reborn"
EXE_NAME="DrSbaitsoUI.exe"
DIST="zig-out/dist"
TRIPLE="x86_64-windows"

if [[ ! -d "$SBAITSO_LIB" ]]; then
    echo "error: DrSbaitsoLib not found at $SBAITSO_LIB (set SBAITSO_LIB=...)" >&2
    exit 1
fi
SBAITSO_LIB="$(cd "$SBAITSO_LIB" && pwd)"

echo "==> Windows ($TRIPLE, $OPTIMIZE)"

# 1. Speech engine, built (and kept) in DrSbaitsoLib.
lib_prefix="zig-out/native-$TRIPLE"
(cd "$SBAITSO_LIB" && zig build port-lib -Dtarget="$TRIPLE" -Doptimize="$OPTIMIZE" -p "$lib_prefix")

# 2. The app itself.
exe_prefix="zig-out/$TRIPLE"
zig build -Dtarget="$TRIPLE" -Doptimize="$OPTIMIZE" -Dapp-version="$APP_VERSION" \
    -Dsbaitso-lib-file="$SBAITSO_LIB/$lib_prefix/lib/sbaitso_native.lib" \
    -p "$exe_prefix"

# 3. The folder that gets zipped (the .pdb debug symbols are left out).
stage="$DIST/Windows"
app="$stage/$APP_NAME"
rm -rf "$stage" && mkdir -p "$app"
cp "$exe_prefix/bin/$EXE_NAME" "$app/"
rsync -a --exclude .DS_Store resources "$app/"

# Windows line endings so Notepad on older Windows shows it properly.
sed 's/$/\r/' >"$app/README.txt" <<EOF
Dr. Sbaitso: Reborn $APP_VERSION for Windows (64-bit)

To run: double-click $EXE_NAME.
Keep the "resources" folder next to $EXE_NAME; the app needs it.

The first time, Windows SmartScreen may say "Windows protected your PC"
because the app isn't signed. Click "More info", then "Run anyway".
EOF

zip="$DIST/DrSbaitsoReborn-$APP_VERSION-Windows-x64.zip"
rm -f "$zip"
(cd "$stage" && zip -qrX "$OLDPWD/$zip" "$APP_NAME")
echo "    $app"
echo "    $zip"
