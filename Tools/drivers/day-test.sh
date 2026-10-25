#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# day-test.sh <scenario dir> <bundle ids…>: TurnOver leads in the given apps for the run (settings edited with TurnOver
# quit), every scenario in the folder runs in both styles, then the apps list is put back exactly and TurnOver
# relaunched. Waits for the user to be idle 90 s first; stops if they come back.
DIR="$1"; shift
C="$HOME/Library/Application Support/TurnOver/settings.json"; T="$HOME/Library/Developer/TurnOver/tools"
for i in $(seq 1 360); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 90 ] && "$T/displayawake" >/dev/null && break; sleep 10; done
[ "$idle" -lt 90 ] && { echo "never idle; not run"; exit 0; }
"$T/displayawake" >/dev/null || { echo "display asleep or screen locked: not run"; exit 0; }
# A welcome waiting holds TurnOver back (VoiceOver reads it): every check would hear VoiceOver (12 Oct 2026).
V=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/TurnOver.app/Contents/Info.plist 2>/dev/null)
[ "$(defaults read com.turnover.reader welcomed-$V 2>/dev/null)" = "1" ] || { echo "TurnOver's welcome for $V hasn't been closed: not run"; exit 0; }
FRONT=$(osascript -e 'tell application "System Events" to name of first process whose frontmost is true')
pkill -x turnover; sleep 2
cp "$C" "$C.day-test-backup"
python3 - "$C" "$@" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); a=d["applications"]; lb=a["leadBundles"]
# TurnOver's in either reading mode: on its list ("apps"), and off VoiceOver's ("everywhere"; System
# Settings had been given to VoiceOver, and the day-one part failed on it, 19 Oct 2026).
for b in sys.argv[2:]:
    if b not in lb: lb.append(b)
a["voiceOverBundles"]=[b for b in a.get("voiceOverBundles",[]) if b not in sys.argv[2:]]
json.dump(d,open(p,"w"),indent=2)
PY
open -a TurnOver; sleep 6
# TurnOver's own start presses the VoiceOver toggle keys: that activity is the test's, not the user's.
date +%s > /tmp/to-drive-at
for style in ${=STYLES:-mac windows}; do   # STYLES=mac for a run in one style
  for f in "$DIR"/*.txt; do
    sed "s/^app:/style: $style\\
app:/" "$f" > "/tmp/day-$(basename $f)"
    python3 "$T/scenario.py" "/tmp/day-$(basename $f)" 2>&1 | grep -v "^  ok" | sed "s#/tmp/day-##"
    rc=${pipestatus[1]}
    # The user back (3), the wrong app in front (4), a style switch that failed (5), a key being passed through (6):
    # nothing more is sent (10 Oct 2026).
    if [ "$rc" -eq 7 ]; then continue; fi   # the app isn't on this Mac: the next scenario (25 Oct 2026)
    if [ "$rc" -ge 3 ]; then echo "stopped: scenario exit $rc"; break 2; fi
    idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')
  done
done
pkill -x turnover; sleep 2
python3 - "$C" "$C.day-test-backup" <<'PY'
import json,sys; cur=json.load(open(sys.argv[1])); old=json.load(open(sys.argv[2]))
cur["applications"]["leadBundles"]=old["applications"]["leadBundles"]; cur["applications"]["voiceOverBundles"]=old["applications"].get("voiceOverBundles",[]); cur["general"]["keyboardStyle"]=old["general"].get("keyboardStyle","mac")
json.dump(cur,open(sys.argv[1],"w"),indent=2); print("apps list and style put back")
PY
rm -f "$C.day-test-backup"
open -a TurnOver; sleep 4
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "NOT RUNNING: VoiceOver on"; }
[ -n "$FRONT" ] && open -a "$FRONT"
