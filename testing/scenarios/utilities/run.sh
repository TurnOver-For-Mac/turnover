#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# The utility apps in both styles (day-test.sh: lead list and style put back), then every app that wasn't running
# before is quit again, and the front app put back.
T="$HOME/Library/Developer/TurnOver/tools"; D="$HOME/Library/Developer/TurnOver/scenarios/utilities"
APPS=("Activity Monitor" "Console" "Disk Utility" "Passwords" "Script Editor" "Xcode")
typeset -A WAS; for a in "${APPS[@]}"; do pgrep -xq "$a" && WAS[$a]=1 || WAS[$a]=0; done
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
STYLE=$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/TurnOver/settings.json'))['general']['keyboardStyle'])")
"$T/day-test.sh" "$D" com.apple.ActivityMonitor com.apple.Console com.apple.DiskUtility com.apple.Passwords com.apple.ScriptEditor2 com.apple.dt.Xcode
for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && { osascript -e "tell application \"$a\" to quit" >/dev/null 2>&1; echo "quit $a"; }; done
sleep 2; for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && echo "STILL RUNNING: $a"; done
open -b "$FRONT"; sleep 1
NOW=$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/TurnOver/settings.json'))['general']['keyboardStyle'])")
echo "style $NOW (was $STYLE)"; echo "front $(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')"
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
