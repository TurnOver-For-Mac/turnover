#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Layer key in TextEdit; then the emergency key (quit, then start); TurnOver always running at the end.
T="$HOME/Library/Developer/TurnOver/tools"; F="$HOME/Library/Developer/TurnOver/scenarios/files/parity.txt"; D="$HOME/Library/Developer/TurnOver/scenarios/layer"
S="$HOME/Library/Application Support/TurnOver/settings.json"
for i in $(seq 1 720); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 90 ] && break; sleep 10; done
[ "$idle" -lt 90 ] && { echo "never idle; not run"; exit 0; }
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
STYLE=$(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])")
cp "$F" /tmp/parity.before
CALC=0; pgrep -xq Calculator && CALC=1
python3 "$T/scenario.py" "$D/calculator.txt" --mask 0; rc=$?
# The three reading modes, round and back; the mode put back if a run stopped halfway (13 Oct 2026).
MODE=$(python3 -c "import json;print(json.load(open('$S'))['applications'].get('leadMode','apps'))")
# modes.txt starts from "TurnOver in its apps": set that first (TurnOver quit), whatever the mode was; put back below.
if [ "$MODE" != "apps" ]; then pkill -x turnover; sleep 2; python3 -c "import json;p='$S';d=json.load(open(p));d['applications']['leadMode']='apps';json.dump(d,open(p,'w'),indent=2)"; open -a TurnOver; sleep 6; fi
# The restart above presses the VoiceOver toggle keys: that activity is the test's, not the user's (both runs on
# 16 Oct 2026 stopped here as "user active"; day-test.sh marks the same way).
date +%s > /tmp/to-drive-at; sleep 3
[ $rc -lt 3 ] && { python3 "$T/scenario.py" "$D/modes.txt" --mask 0; rc=$?; }
NOW=$(python3 -c "import json;print(json.load(open('$S'))['applications'].get('leadMode','apps'))")
if [ "$NOW" != "$MODE" ]; then pkill -x turnover; sleep 2; python3 -c "import json;p='$S';d=json.load(open(p));d['applications']['leadMode']='$MODE';json.dump(d,open(p,'w'),indent=2)"; open -a TurnOver; sleep 6; echo "reading mode was $NOW: put back to $MODE"; else echo "reading mode $NOW (unchanged)"; fi
f=$(ls -t "$HOME/Library/Application Support/TurnOver/logs/"* | head -1); grep -E "layer key where VoiceOver leads|stepping in|hand(ing)? (back|over)|lead watcher" "$f" | tail -4 | cut -c1-150
[ $CALC = 0 ] && osascript -e 'tell application "Calculator" to quit' >/dev/null 2>&1
osascript -e 'tell application "TextEdit" to close (every document whose path contains "parity.txt") saving no' >/dev/null 2>&1
cmp -s "$F" /tmp/parity.before && echo "parity.txt unchanged" || { cp /tmp/parity.before "$F"; echo "parity.txt restored"; }
if [ $rc -lt 3 ]; then
  # The emergency key: quit, then start again.
  # The user is away if nothing but the test's own keys happened (the marker is the test's last key).
  idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); since=$(( $(date +%s) - $(cat /tmp/to-drive-at 2>/dev/null || echo 0) ))
  if [ $(( since - idle )) -le 3 ]; then
    date +%s > /tmp/to-drive-at
    # Since 18 Oct 2026 the key toggles a running TurnOver through the control channel ("TurnOver off", "TurnOver
    # on", the process staying); only a TurnOver that doesn't answer is quit and started. Checked by its words.
    L=$(ls -t "$HOME/Library/Application Support/TurnOver/logs"/turnover-*.log | head -1); N=$(wc -l < "$L" | tr -d ' ')
    "$T/drive" clearmods control+command+. clearmods; sleep 5
    tail -n +$N "$L" | grep -q "IO say: TurnOver off" && echo "emergency key turned TurnOver off" || echo "EMERGENCY KEY: no \"TurnOver off\" after the press"
    N=$(wc -l < "$L" | tr -d ' ')
    "$T/drive" clearmods control+command+. clearmods; sleep 5
    tail -n +$N "$L" | grep -q "IO say: TurnOver on" && echo "emergency key turned TurnOver on" || echo "EMERGENCY KEY: no \"TurnOver on\" after the second press"
  else echo "User active: emergency key not tested"; fi
fi
pgrep -x turnover >/dev/null || { open -a TurnOver; sleep 6; echo "TurnOver started by the wrapper"; }
NOW=$(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])")
if [ "$NOW" != "$STYLE" ]; then pkill -x turnover; sleep 2; python3 -c "import json;p='$S';d=json.load(open(p));d['general']['keyboardStyle']='$STYLE';json.dump(d,open(p,'w'),indent=2)"; open -a TurnOver; sleep 6; echo "style was $NOW: put back to $STYLE"; fi
open -b "$FRONT"; sleep 1
echo "style $(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])"); front $(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')"
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
tail -3 "$HOME/Library/Logs/TurnOver Key.log" 2>/dev/null
