#!/bin/sh
# Gives every game its own name in the app switcher.
#
# CrossOver runs each Windows program through a file named after it in a per-session temp
# folder (winetemp-…), and macOS names the process from that file. For most programs the file
# is a copy of CrossOver's loader stub and the switcher says "Hades2.exe"; for some (Diablo IV,
# Cyberpunk 2077, anything a launcher spawns) it is a bare symlink to the Wine binary and the
# switcher says "wine". Measured 30 Sep 2026: if the stub file already exists under the game's
# exe name, CrossOver reuses it and the process is named after the game. So this creates a
# stub for every .exe in the Steam library, replacing symlinks. The folder is recreated at
# every boot, so the Steam launcher runs this after starting Steam; the Setup app runs it too.
BOTTLE="${1:-Steam}"
COMMON="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE/drive_c/Program Files (x86)/Steam/steamapps/common"
W=""; i=0
while [ -z "$W" ] && [ $i -lt 30 ]; do
    W=$(ls -d "${TMPDIR:-/tmp}"/winetemp-* /private/var/folders/*/*/T/winetemp-* 2>/dev/null | while read -r d; do [ -f "$d/wineloader" ] && echo "$d" && break; done)
    [ -z "$W" ] && { sleep 1; i=$((i+1)); }
done
[ -n "$W" ] || { echo "no running bottle (no winetemp folder with a loader stub)"; exit 0; }
[ -d "$COMMON" ] || exit 0
made=0
find "$COMMON" -maxdepth 4 -iname "*.exe" 2>/dev/null | while IFS= read -r exe; do
    n=$(basename "$exe")
    case "$n" in UnityCrashHandler*|*redist*|*Redist*|vc_redist*|dxsetup*|DXSETUP*|*.tmp.exe) continue ;; esac
    t="$W/$n"
    if [ -L "$t" ] || [ ! -e "$t" ]; then rm -f "$t"; ln "$W/wineloader" "$t" 2>/dev/null && echo "$n"; fi
done | sort -u | tr '\n' ' ' | sed 's/^/named: /'; echo
