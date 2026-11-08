#!/bin/sh
# Keeps "/Applications/SpeechBridge Listener.app" running: a per-user launchd agent that
# starts it at login and restarts it if it ever exits. No permission prompt for this;
# the VoiceOver Automation permission is the app's own and is asked once, on first speech.
#
#   listener/login-item.sh          install (or update) the agent and start it now
#   listener/login-item.sh --remove stop it and remove the agent
set -e
LABEL="com.oliverkennett.speechbridge-listener"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="/Applications/SpeechBridge Listener.app/Contents/MacOS/SpeechBridge Listener"
UID_="$(id -u)"

if [ "$1" = "--remove" ]; then
    launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Removed. The listener is no longer kept running."
    exit 0
fi

[ -x "$APP" ] || { echo "Build and install the app first: listener/build.sh"; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
# Any copy started by hand would hold the port; the agent's copy takes over.
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
pkill -x "SpeechBridge Listener" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$UID_" "$PLIST"
sleep 2
if pgrep -x "SpeechBridge Listener" >/dev/null; then
    echo "Installed: the listener starts at login and is restarted if it stops."
else
    echo "Agent installed but the listener is not running — check: launchctl print gui/$UID_/$LABEL"
fi
