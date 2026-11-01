#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Waits for the user to be idle 90 s, runs both, then puts back the test file, the front app and the style; TurnOver running.
T="$HOME/Library/Developer/TurnOver/tools"; F="$HOME/Library/Developer/TurnOver/scenarios/files/parity.txt"; D="$HOME/Library/Developer/TurnOver/scenarios/decisions"
for i in $(seq 1 360); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 90 ] && break; sleep 10; done
[ "$idle" -lt 90 ] && { echo "never idle; not run"; exit 0; }
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
cp "$F" /tmp/parity.before
STYLE=$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/TurnOver/settings.json'))['general']['keyboardStyle'])")
for s in mac windows; do
  python3 "$T/scenario.py" "$D/$s.txt" --mask 0; rc=$?
  [ $rc -ge 3 ] && { echo "stopped: exit $rc"; break; }
done
osascript -e 'tell application "TextEdit" to close (every document whose path contains "parity.txt") saving no' >/dev/null 2>&1
cmp -s "$F" /tmp/parity.before && echo "parity.txt unchanged" || { cp /tmp/parity.before "$F"; echo "parity.txt restored"; }
open -b "$FRONT"; sleep 1; echo "front back to $(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')"
NOW=$(python3 -c "import json;print(json.load(open('$HOME/Library/Application Support/TurnOver/settings.json'))['general']['keyboardStyle'])")
if [ "$NOW" != "$STYLE" ]; then
  # Never leave the Mac in another style: put it back with TurnOver quit (settings are edited only then).
  pkill -x turnover; sleep 2
  python3 -c "import json,sys;p='$HOME/Library/Application Support/TurnOver/settings.json';d=json.load(open(p));d['general']['keyboardStyle']='$STYLE';json.dump(d,open(p,'w'),indent=2)"
  open -a TurnOver; sleep 5; echo "style was $NOW: put back to $STYLE"
fi
python3 -c "import json;print('style', json.load(open('$HOME/Library/Application Support/TurnOver/settings.json'))['general']['keyboardStyle'])"
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
