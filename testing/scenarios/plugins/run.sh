#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
T="$HOME/Library/Developer/TurnOver/tools"; F="$HOME/Library/Developer/TurnOver/scenarios/files/parity.txt"; P="$HOME/Library/Application Support/TurnOver/plugins"
for i in $(seq 1 720); do idle=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'); [ "$idle" -ge 90 ] && break; sleep 10; done
[ "$idle" -lt 90 ] && { echo "never idle; not run"; exit 0; }
FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true')
rm -rf /tmp/plugins.before; cp -R "$P" /tmp/plugins.before; cp "$F" /tmp/parity.before
python3 "$T/scenario.py" "$HOME/Library/Developer/TurnOver/scenarios/plugins/textedit.txt" --mask 0
osascript -e 'tell application "TextEdit" to close (every document whose path contains "parity.txt") saving no' >/dev/null 2>&1
cmp -s "$F" /tmp/parity.before && echo "parity.txt unchanged" || { cp /tmp/parity.before "$F"; echo "parity.txt restored"; }
if diff -rq "$P" /tmp/plugins.before >/dev/null 2>&1; then echo "plugins folder unchanged"; else diff -rq "$P" /tmp/plugins.before | head -5; rm -rf "$P"; cp -R /tmp/plugins.before "$P"; echo "plugins folder put back"; fi
open -b "$FRONT"; sleep 1
pgrep -x turnover >/dev/null && echo "TurnOver running" || { open -a VoiceOver; echo "TurnOver NOT running: VoiceOver opened"; }
