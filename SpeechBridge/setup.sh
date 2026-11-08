#!/bin/sh
# SpeechBridge setup: everything a Mac needs so Steam's Windows games speak through TurnOver. Safe to run again any
# time, and meant to be: after installing a game, after its first launch, after a Steam "verify integrity" (which
# puts a game's original speech files back), after a new mod.
#
#   sh SpeechBridge/setup.sh [bottle-name]
#
# Two ways the games can run, and this handles whichever it finds (both, if both are there):
#   NotProton  Steam Play in the Mac Steam client, each game in its own Wine prefix (steamapps/compatdata/<appid>/pfx).
#              The way since October 2026. install-notproton.sh does the work.
#   A CrossOver bottle holding Windows Steam (default name: Steam, or the name given). The way of September 2026;
#              install.sh does the work, plus the one-off registrations and two helper apps built here.
#
# Needs: an Apple-silicon Mac and TurnOver. Nothing else: no Xcode, no Command Line Tools, no Homebrew. The stand-in
# DLLs are prebuilt (their sources are beside them, with build scripts for mingw-w64), and the helper apps are
# AppleScript, compiled by macOS's own osacompile.
#
# Undo: sh SpeechBridge/install-notproton.sh has no uninstall (delete a game's prefix and Steam makes a fresh one);
# sh SpeechBridge/install.sh --uninstall puts a bottle game's original files back.
set -e
cd "$(dirname "$0")"; HERE="$(pwd)"
BOTTLE="${1:-Steam}"
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
COMMON="$B/drive_c/Program Files (x86)/Steam/steamapps/common"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/cxstart"
MACSTEAM="$HOME/Library/Application Support/Steam/steamapps"
say() { printf '\n== %s\n' "$*"; }

say "Checking this Mac"
[ "$(uname -m)" = "arm64" ] || { echo "This needs an Apple-silicon Mac (CrossOver's D3DMetal, which the games need, is Apple silicon only)."; exit 1; }
if [ -d "/Applications/TurnOver.app" ]; then
    echo "TurnOver is installed: it is the voice. The first time a game speaks, TurnOver asks whether it may speak for it; answer Allow."
    # The SpeechBridge Listener (September 2026) spoke through VoiceOver on the same port. TurnOver took its place in
    # October 2026; left running, it holds the port and TurnOver hears nothing.
    if [ -f "$HOME/Library/LaunchAgents/com.oliverkennett.speechbridge-listener.plist" ] || pgrep -x "SpeechBridge Listener" >/dev/null; then
        echo "The old SpeechBridge Listener is still set to run. TurnOver has taken over its job, so it is stopped and taken out of your login items now."
        sh listener/login-item.sh --remove >/dev/null 2>&1 || true
        pkill -x "SpeechBridge Listener" 2>/dev/null || true
        echo "Nothing uses '/Applications/SpeechBridge Listener.app' any more; you can delete it."
    fi
else
    echo "TurnOver is not in Applications. Get it from https://doll-eye.github.io/turnover-updates/ and run this again."
    echo "(Without TurnOver, the games can speak through VoiceOver with the listener in SpeechBridge/listener instead; README.md says how. Steam's own interface isn't read that way.)"
fi
HAVE_NP=no; HAVE_BOTTLE=no
if [ -d "$MACSTEAM" ] && { ls -d "$HOME/Library/Application Support/Steam/compatibilitytools.d"/notproton* >/dev/null 2>&1 || [ -d "$HOME/Library/Application Support/notproton/runners" ]; }; then HAVE_NP=yes; fi
[ -d "$B/drive_c" ] && HAVE_BOTTLE=yes
[ "$HAVE_NP" = yes ] && echo "NotProton is set up in the Mac Steam client: its games get the stand-ins."
[ "$HAVE_BOTTLE" = yes ] && echo "A CrossOver bottle called '$BOTTLE' exists: its games get the stand-ins too."
if [ "$HAVE_NP" = no ] && [ "$HAVE_BOTTLE" = no ]; then
    echo "Neither NotProton nor a CrossOver bottle called '$BOTTLE' was found."
    echo "The usual way: install Steam for the Mac, CrossOver (https://www.codeweavers.com/crossover) and NotProton (https://github.com/NotProtonNot/NotProton),"
    echo "open NotProton once so it sets Steam Play up, install a Windows game, start it once, then run this again."
    echo "The older way: a CrossOver bottle (Windows 10) called '$BOTTLE' with Windows Steam installed in it, or pass your bottle's name."
    exit 1
fi

say "SpeechBridge Setup, the installer as an app"
sh setup-app/build.sh
echo "Open '/Applications/SpeechBridge Setup.app' after installing a game; it does the file part of this without Terminal."

if [ "$HAVE_NP" = yes ]; then
    say "NotProton games"
    sh install-notproton.sh
fi

if [ "$HAVE_BOTTLE" = yes ]; then
    say "The CrossOver bottle: helper apps"
    [ -x "$CX" ] || { echo "CrossOver is not installed at /Applications/CrossOver.app, so the bottle can't be set up."; exit 1; }
    [ -f "$B/drive_c/Program Files (x86)/Steam/steam.exe" ] || echo "Note: no Windows Steam in the '$BOTTLE' bottle yet. The speech pieces install anyway."
    mkdir -p "$HOME/Library/Application Support/SpeechBridge/run-in-bottle"
    osacompile -o "$HOME/Library/Application Support/SpeechBridge/run-in-bottle/RunInBottle.app" tools/run-in-bottle.applescript
    # "Windows Steam", not "Steam": the Mac's own Steam.app in Applications keeps its name.
    osacompile -o "/Applications/Windows Steam.app" tools/steam-launcher.applescript
    echo "Built '/Applications/Windows Steam.app', which starts the bottle's Steam without CrossOver's window."

    say "The CrossOver bottle: stand-ins"
    sh install.sh "$BOTTLE"

    say "The CrossOver bottle: registrations inside it (one-off, harmless to repeat)"
    inb() {   # run one Windows command in the bottle, giving up after 90 s
        "$CX" --bottle "$BOTTLE" --no-update --wait "$@" >/dev/null 2>&1 &
        pid=$!; i=0; while kill -0 $pid 2>/dev/null && [ $i -lt 90 ]; do sleep 1; i=$((i+1)); done
        kill -0 $pid 2>/dev/null && { kill $pid 2>/dev/null; echo "  (timed out: $*)"; return 1; }; wait $pid 2>/dev/null || true
    }
    reg() {   # reg <what> <command...>: one registration, reported either way
        what="$1"; shift
        if inb "$@"; then echo "  $what"; else echo "  could not do: $what"; fi
    }
    reg "SAPI voice, 64-bit"              regsvr32 /s 'C:\windows\system32\SapiBridge64.dll'
    reg "SAPI voice, 32-bit"              'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\SapiBridge32.dll'
    reg "SpVoice stand-in, 64-bit"        regsvr32 /s 'C:\windows\system32\SpVoiceBridge64.dll'
    reg "SpVoice stand-in, 32-bit"        'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\SpVoiceBridge32.dll'
    reg "ZDSR key (games built on Prism: Fallout 4 Access, Cyberpunk Access)" reg add 'HKLM\SOFTWARE\WOW6432Node\zhiduo\zdsr' /v Path /t REG_SZ /d 'C:\SpeechBridge' /f
    reg "Bluetooth rumble shim for Steam" reg add 'HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides' /v cfgmgr32 /t REG_SZ /d native,builtin /f
    reg "Ren'Py self-voicing"             reg import 'C:\SpeechBridge\renpy.reg'
    # Per game: Wine loads a DLL from a program's own folder only when told to, and the mod loaders the accessibility
    # mods ride on are such DLLs. Each override names one program, so nothing else changes. Only for games that are
    # installed; run this again after installing one.
    over() {   # over "<game folder>" "<program>" <dll> <mode> "<what>"
        [ -d "$COMMON/$1" ] || return 0
        reg "$1: $5" reg add "HKCU\\Software\\Wine\\AppDefaults\\$2\\DllOverrides" /v "$3" /t REG_SZ /d "$4" /f
    }
    over "Hades II"       "Hades2.exe"        d3d12 native,builtin "Hell2Modding's d3d12.dll (the blind accessibility mods)"
    over "Cyberpunk 2077" "Cyberpunk2077.exe" winmm native,builtin "RED4ext's winmm.dll (Cyberpunk Access)"
    for d in "$COMMON"/FINAL\ FANTASY\ VI*; do
        [ -d "$d" ] || continue
        reg "$(basename "$d"): MelonLoader's version.dll (the FF6 Screen Reader mod)" reg add 'HKCU\Software\Wine\AppDefaults\FINAL FANTASY VI.exe\DllOverrides' /v version /t REG_SZ /d native,builtin /f
        break
    done
    if [ -d "$COMMON/Fallout 4" ]; then
        for v in xaudio2_7 x3daudio1_7 xapofx1_5 xactengine3_7; do
            over "Fallout 4" "Fallout4.exe" "$v" native "Microsoft's $v (sound; Wine's own gives static)"
        done
    fi
fi

say "Done"
cat <<'TXT'
Next:
  1. To have Steam's Big Picture read as you move: TurnOver's Settings, Other apps' speech, Read Steam's Big Picture,
     then Restart Steam there.
  2. Install a game, start it once, then run this again (or open "SpeechBridge Setup"), so the game's own speech
     files are swapped for the stand-ins and its mod loader is allowed. Again after any Steam "verify integrity".
  3. Start the game. The first time it speaks, TurnOver asks whether it may speak for it: Allow. From then on the game
     speaks in TurnOver's voice whenever it is the app in front.
The guide "Windows games on your Mac" (Guides/14-windows-games.md) has each game's mods and settings; README.md
beside this script has the detail and the traps.
TXT
