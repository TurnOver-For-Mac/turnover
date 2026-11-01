#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
T="$HOME/Library/Developer/TurnOver/tools"; S="$HOME/Library/Application Support/TurnOver/settings.json"
for i in $(seq 1 720); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 90 ] && break; sleep 10; done
[ "$idle" -lt 90 ] && { echo "never idle; not run"; exit 0; }
WAS=0; pgrep -xq "Microsoft Word" && WAS=1
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
STYLE=$(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])")
python3 "$T/scenario.py" "$HOME/Library/Developer/TurnOver/scenarios/keys-apps/word.txt"
[ $WAS = 0 ] && pgrep -xq "Microsoft Word" && { osascript -e 'tell application "Microsoft Word" to quit saving no' >/dev/null 2>&1; echo "quit Word"; }
NOW=$(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])")
if [ "$NOW" != "$STYLE" ]; then pkill -x turnover; sleep 2; python3 -c "import json;p='$S';d=json.load(open(p));d['general']['keyboardStyle']='$STYLE';json.dump(d,open(p,'w'),indent=2)"; open -a TurnOver; sleep 5; echo "style was $NOW: put back to $STYLE"; fi
open -b "$FRONT"; sleep 1
echo "style $(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])"); front $(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')"
pgrep -xq "Microsoft Word" && [ $WAS = 0 ] && echo "STILL RUNNING: Word"
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
