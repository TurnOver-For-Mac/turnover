#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Command Control Period: quit TurnOver, then start it again. TurnOver always running at the end.
T="$HOME/Library/Developer/TurnOver/tools"
for i in $(seq 1 720); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 90 ] && break; sleep 10; done
[ "$idle" -lt 90 ] && { echo "never idle; not run"; exit 0; }
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
"$T/drive" clearmods control+command+. clearmods; sleep 6
pgrep -x turnover >/dev/null && echo "EMERGENCY KEY: TurnOver still running after the quit press" || echo "emergency key quit TurnOver"
osascript -e 'tell application "System Events" to get value of attribute "AXEnabled" of application process "VoiceOver"' >/dev/null 2>&1
defaults read com.apple.universalaccess voiceOverOnOffKey >/dev/null 2>&1
pgrep -x VoiceOver >/dev/null && echo "VoiceOver is running" || echo "VoiceOver NOT running"
"$T/drive" clearmods control+command+. clearmods; sleep 9
pgrep -x turnover >/dev/null && echo "emergency key started TurnOver" || { echo "EMERGENCY KEY: TurnOver did not start; starting it"; open -a TurnOver; sleep 6; }
open -b "$FRONT"; sleep 1
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
tail -4 "$HOME/Library/Logs/TurnOver Key.log"
