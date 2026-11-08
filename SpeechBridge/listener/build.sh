#!/bin/sh
# Builds the listener into "/Applications/SpeechBridge Listener.app" and (re)launches it.
# An app rather than a bare binary so the VoiceOver Automation permission belongs to it
# and it can be a login item. Builds outside the project directory (iCloud's extended
# attributes break codesign under ~/Desktop).
set -e
cd "$(dirname "$0")"
NAME="SpeechBridge Listener"
BUILD="$HOME/Library/Developer/SpeechBridge"
APP="$BUILD/$NAME.app"
DEST="/Applications/$NAME.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/$NAME" d4bridge.swift
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>com.oliverkennett.speechbridge-listener</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SpeechBridge Listener speaks game text through VoiceOver.</string>
    <key>NSHumanReadableCopyright</key><string>Oliver Kennett</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1
pkill -x "$NAME" 2>/dev/null || true
pkill -f "listener/d4bridge.py" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
open "$DEST"
echo "Installed to $DEST and launched."
echo "Latest log: $(ls -t "$HOME/Library/Application Support/SpeechBridge/logs" 2>/dev/null | head -1)"
