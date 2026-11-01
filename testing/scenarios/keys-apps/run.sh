#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Chat keys in both styles (day-test.sh), then Word in the Windows style; apps not running before are quit again;
# style, front app and TurnOver checked.
T="$HOME/Library/Developer/TurnOver/tools"; D="$HOME/Library/Developer/TurnOver/scenarios/keys-apps"
S="$HOME/Library/Application Support/TurnOver/settings.json"
APPS=("Messages" "WhatsApp" "Microsoft Word")
typeset -A WAS; for a in "${APPS[@]}"; do pgrep -xq "$a" && WAS[$a]=1 || WAS[$a]=0; done
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
STYLE=$(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])")
"$T/day-test.sh" "$D/chat" com.apple.MobileSMS net.whatsapp.WhatsApp
# day-test.sh restarts TurnOver as it puts the apps list back, and the start presses the VoiceOver toggle keys: mark
# that as the test's own activity, or word.txt stops at once as "user active" (16 Oct 2026).
date +%s > /tmp/to-drive-at; sleep 3
python3 "$T/scenario.py" "$D/word.txt"
for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && { osascript -e "tell application \"$a\" to quit saving no" >/dev/null 2>&1 || osascript -e "tell application \"$a\" to quit" >/dev/null 2>&1; echo "quit $a"; }; done
sleep 2; for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && echo "STILL RUNNING: $a"; done
NOW=$(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])")
if [ "$NOW" != "$STYLE" ]; then pkill -x turnover; sleep 2; python3 -c "import json;p='$S';d=json.load(open(p));d['general']['keyboardStyle']='$STYLE';json.dump(d,open(p,'w'),indent=2)"; open -a TurnOver; sleep 5; echo "style was $NOW: put back to $STYLE"; fi
open -b "$FRONT"; sleep 1
echo "style $(python3 -c "import json;print(json.load(open('$S'))['general']['keyboardStyle'])") (was $STYLE); front $(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')"
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
