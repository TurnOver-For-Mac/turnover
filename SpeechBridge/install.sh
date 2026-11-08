#!/bin/sh
# SpeechBridge installer: makes every game in the CrossOver bottle speak through the Mac.
#
# Safe to run any time, as often as you like — after installing a game, and after a Steam
# "verify integrity" (which puts a game's original speech plugins back). It only copies
# files; nothing is run inside the bottle. What it does, per game under steamapps/common:
#
#   nvdaControllerClient.dll present  -> replaced by the NVDA stand-in (original kept as .orig)
#   (also the 64/32-suffixed names Tolk uses, e.g. inside Stardew Access's screen-reader-libs)
#   WindowsTTS.dll present            -> replaced by the WindowsTTS stand-in (original kept)
#   Tolk.dll present                  -> SAAPI64.dll / SAAPI32.dll placed beside it
#   Diablo IV                         -> nothing in its folder; SAAPI64 is served from system32
#
# and once for the bottle: the SapiBridge voice DLLs are copied to C:\SpeechBridge. Their
# registration (regsvr32, from inside the bottle) is a one-off and is checked here, not done —
# see README, "SapiBridge".
#
# Usage:  sh SpeechBridge/install.sh [bottle-name]      default bottle: Steam
#         sh SpeechBridge/install.sh --uninstall [bottle-name]   put every .orig back
# Most people run SpeechBridge/setup.sh instead, which runs this and does the rest (the apps, the registrations).
set -e
cd "$(dirname "$0")"
HERE="$(pwd)"

MODE=install
if [ "$1" = "--uninstall" ]; then MODE=uninstall; shift; fi
BOTTLE="${1:-Steam}"
B="$HOME/Library/Application Support/CrossOver/Bottles/$BOTTLE"
[ -d "$B/drive_c" ] || { echo "No bottle at $B"; exit 1; }
COMMON="$B/drive_c/Program Files (x86)/Steam/steamapps/common"

# 32- or 64-bit? PE magic 0x20b (523) at the optional header. od alone, so a Mac without Apple's
# Command Line Tools (whose python3 is only a prompt to install them) can run this.
bits_of() {
    pe=$(od -An -tu4 -j60 -N4 "$1" | tr -d ' ')
    magic=$(od -An -tu2 -j"$((pe + 24))" -N2 "$1" | tr -d ' ')
    if [ "$magic" = 523 ]; then echo 64; else echo 32; fi
}

is_ours() {   # our DLLs carry this string; the games' do not (grep alone stops at binaries' NULs)
    strings -n 8 "$1" 2>/dev/null | grep -q "SpeechBridge"
}

replace() {   # replace <target> with <ours>, keeping the original once
    target="$1"; ours="$2"
    if is_ours "$target"; then
        cmp -s "$target" "$ours" || { cp "$ours" "$target"; echo "  updated  $(basename "$target")"; }
        return
    fi
    [ -f "$target.orig" ] || cp "$target" "$target.orig"
    cp "$ours" "$target"
    echo "  replaced $(basename "$target") (original kept as .orig)"
}

restore() {
    target="$1"
    [ -f "$target.orig" ] || return 0
    mv -f "$target.orig" "$target"
    rm -f "${target%.dll}.log"
    echo "  restored $(basename "$target")"
}

echo "SpeechBridge $MODE — bottle '$BOTTLE'"
[ -d "$COMMON" ] || { echo "No Steam games folder at $COMMON"; exit 0; }

find "$COMMON" -maxdepth 8 \( -iname "nvdaControllerClient.dll" -o -iname "nvdaControllerClient64.dll" -o -iname "nvdaControllerClient32.dll" -o -iname "WindowsTTS.dll" -o -iname "Tolk.dll" \) 2>/dev/null | sort | while IFS= read -r f; do
    game="${f#$COMMON/}"; game="${game%%/*}"
    name="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
    dir="$(dirname "$f")"
    echo "$game:"
    if [ "$MODE" = uninstall ]; then
        case "$name" in
            nvdacontrollerclient.dll|nvdacontrollerclient64.dll|nvdacontrollerclient32.dll|windowstts.dll) restore "$f" ;;
            tolk.dll) if [ -f "$dir/SAAPI64.dll.orig" ]; then mv -f "$dir/SAAPI64.dll.orig" "$dir/SAAPI64.dll"; else rm -f "$dir/SAAPI64.dll"; fi; rm -f "$dir/SAAPI32.dll" "$dir/SAAPI64.log"; echo "  SAAPI stand-in beside Tolk removed" ;;
        esac
        continue
    fi
    bits="$(bits_of "$f")"
    case "$name" in
        nvdacontrollerclient.dll|nvdacontrollerclient64.dll|nvdacontrollerclient32.dll) replace "$f" "$HERE/NVDA/nvdaControllerClient$bits.dll" ;;
        windowstts.dll)           replace "$f" "$HERE/WindowsTTS/WindowsTTS$bits.dll" ;;
        tolk.dll)
            # Tolk finds SAAPI64.dll through the normal DLL search, so the copy in
            # C:\windows\system32 serves every Tolk game. A copy beside the game is only
            # kept where the game ships its own (Stardew Access does), so the one Tolk sees
            # is ours; never added to a game that ships none — Diablo IV's protection layer
            # ends the process about two minutes after a DLL loads from the game folder.
            if [ "$bits" = 64 ]; then
                if [ -f "$dir/SAAPI64.dll" ]; then
                    if ! is_ours "$dir/SAAPI64.dll"; then [ -f "$dir/SAAPI64.dll.orig" ] || cp "$dir/SAAPI64.dll" "$dir/SAAPI64.dll.orig"; fi
                    cmp -s "$HERE/SAAPI64/SAAPI64.dll" "$dir/SAAPI64.dll" || { cp "$HERE/SAAPI64/SAAPI64.dll" "$dir/SAAPI64.dll"; echo "  SAAPI64.dll replaced beside Tolk.dll (the game shipped one)"; }
                else
                    echo "  Tolk.dll found; SAAPI64.dll is served from C:\\windows\\system32"
                fi
            else echo "  32-bit Tolk: no SAAPI32 build yet — build one from SAAPI64/saapi64.c with i686-w64-mingw32-gcc"; fi ;;
    esac
done

# Diablo IV: nothing goes in its folder — its protection layer ends the process about two
# minutes after a DLL is loaded from anywhere but Windows' own folders (measured 28 Sep 2026).
# An old copy from earlier versions is removed.
if [ "$MODE" = install ] && [ -f "$COMMON/Diablo IV/SAAPI64.dll" ]; then
    rm -f "$COMMON/Diablo IV/SAAPI64.dll" "$COMMON/Diablo IV/SAAPI64.log"
    echo "Diablo IV:"; echo "  removed SAAPI64.dll from the game folder (served from system32 now)"
fi

# The bottle-wide pieces live in Windows' own folders, the one place Diablo IV's protection
# layer accepts a DLL from: the SAPI voice engine, the SpVoice stand-in (SAPI's voice object
# itself — Wine's cannot render into a stream a game supplies, and Diablo IV then dies two
# minutes later), and SAAPI64 for Tolk. sbsay.exe (Ren'Py) stays in C:\SpeechBridge.
# Registration is a one-off inside the bottle and is checked here.
if [ "$MODE" = install ]; then
    S32="$B/drive_c/windows/system32"; S64="$B/drive_c/windows/syswow64"
    mkdir -p "$B/drive_c/SpeechBridge" "$S32" "$S64"
    cp "$HERE/SapiBridge/SapiBridge64.dll" "$HERE/SpVoice/SpVoiceBridge64.dll" "$HERE/SAAPI64/SAAPI64.dll" "$HERE/ZDSR/ZDSRAPI_x64.dll" "$S32/"
    cp "$HERE/SapiBridge/SapiBridge32.dll" "$HERE/SpVoice/SpVoiceBridge32.dll" "$HERE/ZDSR/ZDSRAPI.dll" "$S64/"
    # NVDA's controller client, too, so a game that asks for it without shipping it (Tolk's
    # NVDA driver, or a game's own LoadLibrary) finds the stand-in on the normal DLL search.
    cp "$HERE/NVDA/nvdaControllerClient64.dll" "$S32/nvdaControllerClient64.dll"; cp "$HERE/NVDA/nvdaControllerClient64.dll" "$S32/nvdaControllerClient.dll"
    cp "$HERE/NVDA/nvdaControllerClient32.dll" "$S64/nvdaControllerClient32.dll"; cp "$HERE/NVDA/nvdaControllerClient32.dll" "$S64/nvdaControllerClient.dll"
    # Programs built on the Prism speech library (Fallout 4 Access) reach the ZDSR stand-in only
    # when ZDSR's registry key exists; a one-off, checked here.
    if grep -q 'zhiduo\\\\zdsr\]' "$B/system.reg" 2>/dev/null; then
        echo "ZDSR stand-in: in C:\\windows\\system32, registry key present."
    else
        echo "ZDSR stand-in: copied — registry key NOT present yet. Inside the bottle run:"
        echo "  reg add HKLM\\SOFTWARE\\WOW6432Node\\zhiduo\\zdsr /v Path /t REG_SZ /d C:\\SpeechBridge /f"
    fi
    [ -f "$HERE/RenPy/sbsay.exe" ] && cp "$HERE/RenPy/sbsay.exe" "$HERE/RenPy/renpy.reg" "$B/drive_c/SpeechBridge/"
    [ -f "$HERE/tools/steam.vbs" ] && cp "$HERE/tools/steam.vbs" "$B/drive_c/SpeechBridge/"
    rm -f "$B/drive_c/SpeechBridge/SapiBridge64.dll" "$B/drive_c/SpeechBridge/SapiBridge32.dll" "$B/drive_c/SpeechBridge/SpVoiceBridge64.dll" "$B/drive_c/SpeechBridge/SpVoiceBridge32.dll"
    if grep -q 'system32\\\\SpVoiceBridge64.dll' "$B/system.reg" 2>/dev/null && grep -q 'Tokens\\\\SpeechBridge\]' "$B/system.reg" 2>/dev/null; then
        echo "SAPI voice and SpVoice stand-in: in C:\\windows\\system32, registered."
    else
        echo "SAPI voice and SpVoice stand-in: copied to C:\\windows\\system32 — NOT registered yet. Inside the bottle run:"
        echo "  regsvr32 C:\\windows\\system32\\SapiBridge64.dll"
        echo "  C:\\windows\\syswow64\\regsvr32 C:\\windows\\syswow64\\SapiBridge32.dll"
        echo "  regsvr32 C:\\windows\\system32\\SpVoiceBridge64.dll"
        echo "  C:\\windows\\syswow64\\regsvr32 C:\\windows\\syswow64\\SpVoiceBridge32.dll"
    fi
fi

# Fallout 4: Steam runs Fallout4Launcher.exe, and a launch option of "f4se_loader.exe %command%"
# fails because F4SE 0.7.9 refuses the launcher path as an extra argument ("too many free
# args"). So the loader stands in for the launcher, original kept as .orig; a Steam verify puts
# the launcher back, and this puts the loader back.
FO4="$COMMON/Fallout 4"
if [ -f "$FO4/f4se_loader.exe" ]; then
    if [ "$MODE" = uninstall ]; then
        [ -f "$FO4/Fallout4Launcher.exe.orig" ] && mv -f "$FO4/Fallout4Launcher.exe.orig" "$FO4/Fallout4Launcher.exe" && echo "Fallout 4: launcher restored"
    elif ! cmp -s "$FO4/f4se_loader.exe" "$FO4/Fallout4Launcher.exe"; then
        [ -f "$FO4/Fallout4Launcher.exe.orig" ] || cp "$FO4/Fallout4Launcher.exe" "$FO4/Fallout4Launcher.exe.orig"
        cp "$FO4/f4se_loader.exe" "$FO4/Fallout4Launcher.exe"
        echo "Fallout 4: F4SE loader put in the launcher's place (original kept as .orig)"
    fi
fi

# Fallout 4's sound under Wine's own XAudio2 is static; the known fix (CodeWeavers, AppleGamingWiki)
# is Microsoft's real XAudio2 2.7, X3DAudio 1.7, XAPOFX 1.5 and XACT 3.7, which Steam ships in every
# game's DirectX redistributable. They go into system32/syswow64 and Fallout4.exe alone is told to
# use them ("native" overrides, a one-off inside the bottle). Needs cabextract (brew install cabextract).
DXC="$COMMON/Steamworks Shared/_CommonRedist/DirectX/Jun2010"
if [ "$MODE" = install ] && [ -d "$COMMON/Fallout 4" ] && [ -d "$DXC" ]; then
    S32="$B/drive_c/windows/system32"; S64="$B/drive_c/windows/syswow64"
    if [ "$(stat -f %z "$S32/xaudio2_7.dll" 2>/dev/null || echo 0)" -gt 400000 ]; then
        echo "Fallout 4: Microsoft's XAudio2 in place."
    elif command -v cabextract >/dev/null; then
        T="$(mktemp -d)"
        for c in Jun2010_XAudio_x64 Jun2010_XACT_x64 Feb2010_X3DAudio_x64; do cabextract -q -d "$T/64" "$DXC/$c.cab" 2>/dev/null; done
        for c in Jun2010_XAudio_x86 Jun2010_XACT_x86 Feb2010_X3DAudio_x86; do cabextract -q -d "$T/32" "$DXC/$c.cab" 2>/dev/null; done
        for f in XAudio2_7 XAPOFX1_5 xactengine3_7 X3DAudio1_7; do
            [ -f "$T/64/$f.dll" ] && cp "$T/64/$f.dll" "$S32/$(echo "$f" | tr 'A-Z' 'a-z').dll"
            [ -f "$T/32/$f.dll" ] && cp "$T/32/$f.dll" "$S64/$(echo "$f" | tr 'A-Z' 'a-z').dll"
        done
        rm -rf "$T"; echo "Fallout 4: Microsoft's XAudio2 copied into system32/syswow64."
    else
        echo "Fallout 4: sound needs Microsoft's XAudio2 — install cabextract (brew install cabextract) and run this again."
    fi
    if grep -F -A6 'AppDefaults\\Fallout4.exe\\DllOverrides' "$B/user.reg" 2>/dev/null | grep -q '"xaudio2_7"="native"'; then
        echo "Fallout 4: XAudio overrides in place."
    else
        echo "Fallout 4: XAudio overrides NOT set — inside the bottle run, once each:"
        for v in xaudio2_7 x3daudio1_7 xapofx1_5 xactengine3_7; do echo "  reg add HKCU\\Software\\Wine\\AppDefaults\\Fallout4.exe\\DllOverrides /v $v /t REG_SZ /d native /f"; done
    fi
fi

# Rumble over Bluetooth: Steam's SDL asks the device manager for a controller's parent to learn
# its bus, Wine has no parent, so every pad counts as wired and a Bluetooth DualSense is sent
# USB-format reports it ignores. BusType/cfgmgr32.dll beside steam.exe answers that one call from
# the registry (see BusType/bustype.c); Wine loads it only with a native override for steam.exe.
STEAM="$B/drive_c/Program Files (x86)/Steam"
if [ -d "$STEAM" ]; then
    if [ "$MODE" = uninstall ]; then
        rm -f "$STEAM/cfgmgr32.dll" && echo "Steam: bus-type shim removed (the registry override can stay; it is harmless without the file)"
    elif [ -f "$HERE/BusType/cfgmgr32.dll" ]; then
        cmp -s "$HERE/BusType/cfgmgr32.dll" "$STEAM/cfgmgr32.dll" 2>/dev/null || { cp "$HERE/BusType/cfgmgr32.dll" "$STEAM/cfgmgr32.dll"; echo "Steam: bus-type shim installed beside steam.exe (restart Steam)"; }
        if grep -F -A3 'AppDefaults\\steam.exe\\DllOverrides' "$B/user.reg" 2>/dev/null | grep -q '"cfgmgr32"="native,builtin"'; then
            echo "Steam: cfgmgr32 override in place — Bluetooth controllers rumble."
        else
            echo "Steam: cfgmgr32 override NOT set — inside the bottle run:"
            echo "  reg add HKCU\\Software\\Wine\\AppDefaults\\steam.exe\\DllOverrides /v cfgmgr32 /t REG_SZ /d native,builtin /f"
        fi
    fi
fi

# Names in the app switcher (see tools/name-stubs.sh): the script is kept beside the listener's
# logs so the Steam launcher can run it, and it runs now in case Steam is already up.
mkdir -p "$HOME/Library/Application Support/SpeechBridge"; cp "$HERE/tools/name-stubs.sh" "$HOME/Library/Application Support/SpeechBridge/name-stubs.sh"
sh "$HERE/tools/name-stubs.sh" "$BOTTLE"

# Who hears the games: TurnOver's speech port (127.0.0.1:52134, since October 2026), or without TurnOver the old
# SpeechBridge Listener. Both at once can't be: whichever starts second finds the port taken.
if lsof -nP -iTCP:52134 -sTCP:LISTEN 2>/dev/null | grep -q turnover; then
    echo "TurnOver is listening for game speech (port 52134). A game asks to speak through it the first time; answer Allow."
elif pgrep -x "SpeechBridge Listener" >/dev/null; then
    echo "The old SpeechBridge Listener holds port 52134 (speech goes to VoiceOver). With TurnOver installed, retire it: sh listener/login-item.sh --remove."
else
    echo "Nothing is listening on port 52134: start TurnOver (or, without TurnOver, build the listener: sh listener/build.sh)."
fi
