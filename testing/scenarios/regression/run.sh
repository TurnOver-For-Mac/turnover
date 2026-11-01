#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# The regression pass before a build: `run.sh` runs every part; `run.sh core layer` runs the parts named. Each part
# is idle-gated and puts back what it changed; this wrapper puts back the rest on exit, however it ends (trap):
# apps not running before are quit, the style, the front app, the speech-words default and TurnOver checked.
# Parts: plugins core day1 day2 days45 utilities decisions keypad layer keys. (One runner since 16 Oct 2026: there
# were three copies, and none restored on an abort.)
S="$HOME/Library/Developer/TurnOver/scenarios"; T="$HOME/Library/Developer/TurnOver/tools"; C="$HOME/Library/Application Support/TurnOver/settings.json"
PARTS=("$@"); [ ${#PARTS[@]} -eq 0 ] && PARTS=(plugins core day1 day2 days45 utilities decisions keypad layer keys)
APPS=("Calendar" "Contacts" "Freeform" "Reminders" "Shortcuts" "System Settings" "Byword" "Microsoft Excel" "Preview" "Ulysses" "BambuStudio" "Cyberduck" "Audible" "Books" "QuickTime Player" "Voice Memos" "Mail" "Messages" "WhatsApp" "Microsoft Word" "Terminal" "Music" "App Store" "TextEdit" "Finder" "Calculator" "Activity Monitor" "Console" "Disk Utility" "Passwords" "Script Editor" "Xcode")
# Only once the user has really gone: five quiet minutes first (reading a reply looks idle; 12 Oct 2026).
for i in $(seq 1 1440); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 300 ] && "$T/displayawake" >/dev/null && break; sleep 15; done
[ "$idle" -lt 300 ] && { echo "never idle; not run"; exit 0; }
echo "started $(date +%H:%M): ${PARTS[*]}"
LOGSPEECH_WAS=$(defaults read com.turnover.reader logSpeech 2>/dev/null || echo "unset")
typeset -A WAS; for a in "${APPS[@]}"; do pgrep -xq "$a" && WAS[$a]=1 || WAS[$a]=0; done
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
STYLE=$(python3 -c "import json;print(json.load(open('$C'))['general']['keyboardStyle'])")
MODE=$(python3 -c "import json;print(json.load(open('$C'))['applications'].get('leadMode','apps'))")
restore() {
  echo "== putting back"
  for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && { "$T/quitapp" "$a" >/dev/null 2>&1 || osascript -e "tell application \"$a\" to quit saving no" >/dev/null 2>&1; echo "quit $a"; }; done
  # quitapp can close the windows and leave the app running (sixteen apps, 19 Oct 2026): the ordinary quit as well.
  LEFT=(); for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && LEFT+=("$a"); done
  [ ${#LEFT[@]} -gt 0 ] && "$T/quitnamed" "${LEFT[@]}"
  sleep 3; for a in "${APPS[@]}"; do [ "${WAS[$a]}" = 0 ] && pgrep -xq "$a" && echo "STILL RUNNING: $a"; done
  [ -f "$C.day-test-backup" ] && { python3 - "$C" "$C.day-test-backup" <<'PY'
import json,sys; cur=json.load(open(sys.argv[1])); old=json.load(open(sys.argv[2]))
cur["applications"]["leadBundles"]=old["applications"]["leadBundles"]; cur["applications"]["voiceOverBundles"]=old["applications"].get("voiceOverBundles",[]); json.dump(cur,open(sys.argv[1],"w"),indent=2); print("apps lists put back from the backup a stopped part left")
PY
  rm -f "$C.day-test-backup"; }
  pkill -x turnover; sleep 2
  python3 -c "import json;p='$C';d=json.load(open(p));d['general']['keyboardStyle']='$STYLE';d['applications']['leadMode']='$MODE';json.dump(d,open(p,'w'),indent=2)"
  if [ "$LOGSPEECH_WAS" = "unset" ]; then defaults delete com.turnover.reader logSpeech 2>/dev/null; else defaults write com.turnover.reader logSpeech -bool "$([ "$LOGSPEECH_WAS" = 1 ] && echo true || echo false)"; fi
  open -a TurnOver; sleep 6
  open -b "$FRONT" 2>/dev/null; sleep 1
  echo "style $STYLE, mode $MODE, logSpeech $LOGSPEECH_WAS put back; front $(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')"
  pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
}
trap restore EXIT
# The scenarios read what was said from the log: words in the log for the run (TurnOver reads the default at start).
defaults write com.turnover.reader logSpeech -bool true; pkill -x turnover; sleep 2; open -a TurnOver; sleep 6; date +%s > /tmp/to-drive-at; sleep 3
for part in "${PARTS[@]}"; do
  echo "== $part"
  case "$part" in
    plugins) "$S/plugins/run.sh" ;;
    core) "$T/day-test.sh" "$S/regression/core" com.apple.finder com.apple.mail com.apple.MobileSMS net.whatsapp.WhatsApp com.apple.TextEdit com.apple.Terminal com.apple.Music com.apple.AppStore com.microsoft.Word ;;
    day1) "$T/day-test.sh" "$S/day1" com.apple.iCal com.apple.AddressBook com.apple.freeform com.apple.reminders com.apple.shortcuts com.apple.systempreferences ;;
    day2) "$T/day-test.sh" "$S/day2" com.metaclassy.byword com.microsoft.Excel com.apple.Preview com.ulyssesapp.mac ;;
    days45) "$T/day-test.sh" "$S/days4-5" com.bambulab.bambu-studio ch.sudo.cyberduck com.audible.iphone com.apple.iBooksX com.apple.QuickTimePlayerX com.apple.VoiceMemos ;;
    utilities) "$S/utilities/run.sh" ;;
    decisions) "$S/decisions/run.sh" ;;
    keypad) "$S/keypad/run.sh" ;;
    layer) "$S/layer/run.sh" ;;
    keys) "$S/keys-apps/run.sh" ;;
    *) echo "no such part: $part" ;;
  esac
  date +%s > /tmp/to-drive-at
done
