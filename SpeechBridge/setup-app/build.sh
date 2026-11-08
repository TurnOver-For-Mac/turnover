#!/bin/sh
# Builds "/Applications/SpeechBridge Setup.app": a self-contained copy of install.sh, install-notproton.sh and every
# stand-in DLL, so opening the app runs the installer without touching the project folder
# (an app reading ~/Desktop trips a macOS privacy prompt that blocks it silently).
# Rebuild after changing install.sh or any DLL.
set -e
cd "$(dirname "$0")/.."
APP="/Applications/SpeechBridge Setup.app"
PAYLOAD="$APP/Contents/Resources/SpeechBridge"
rm -rf "$APP"
osacompile -o "$APP" setup-app/setup.applescript
mkdir -p "$PAYLOAD"
for d in SAAPI64 NVDA WindowsTTS SapiBridge SpVoice RenPy BusType ZDSR; do
    mkdir -p "$PAYLOAD/$d"
    cp "$d"/*.dll "$PAYLOAD/$d/" 2>/dev/null || true
    cp "$d"/*.exe "$PAYLOAD/$d/" 2>/dev/null || true
    cp "$d"/*.reg "$PAYLOAD/$d/" 2>/dev/null || true
done
cp install.sh "$PAYLOAD/install.sh"
cp install-notproton.sh "$PAYLOAD/install-notproton.sh"; chmod +x "$PAYLOAD/install-notproton.sh"
mkdir -p "$PAYLOAD/tools"; cp tools/name-stubs.sh "$PAYLOAD/tools/"
chmod +x "$PAYLOAD/install.sh"
plutil -replace CFBundleName -string "SpeechBridge Setup" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.turnover.speechbridge-setup" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
touch "$APP"
echo "Built $APP (payload: $(ls "$PAYLOAD" | tr '\n' ' '))"
