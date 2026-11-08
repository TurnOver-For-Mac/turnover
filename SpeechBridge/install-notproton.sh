#!/bin/sh
# SpeechBridge for NotProton: makes every Windows game that Steam on the Mac runs through
# NotProton speak through TurnOver. Safe to run any time, as often as you like: after
# installing a game, after its first launch, and after a Steam "verify integrity".
#
# What it does, per game that Steam has set to NotProton (or that already has a prefix):
#   - a game with no prefix yet is left for NotProton to make on the game's first launch (then
#     run this again); where a template prefix exists (~/Library/Application Support/SpeechBridge/
#     template-pfx, the maintainer's copy of a CrossOver bottle with no games in it) one is made
#     from that instead, and files Steam Cloud has already put there are kept;
#   - the stand-in speech DLLs go into the prefix's system32 and syswow64 and are registered
#     (SAPI voice, SpVoice, ZDSR for Prism, the Ren'Py voice command);
#   - speech DLLs the game ships (NVDA's controller client, WindowsTTS, SAAPI64 beside Tolk)
#     are replaced by the stand-ins, originals kept as .orig;
#   - the Wine overrides mod loaders need: Hades II (d3d12), Final Fantasy VI (version),
#     Cyberpunk 2077 (winmm), Fallout 4 (Microsoft's XAudio2, and F4SE in the launcher's place);
#   - launch options: Stardew Valley starts through SMAPI, Periphery Synthetic opens its
#     debugging port for TurnOver's web reader. Steam must be closed for these; if it is open
#     the script says so and leaves them for next time.
# Then it reports whether TurnOver is listening on the bridge port.
#
# Usage:  sh install-notproton.sh            (setup.sh runs it, and the Setup app runs its own copy)
# Needs nothing but macOS: no Xcode, no Command Line Tools (python3 is used only to write Steam launch options, and
# only where Apple's tools are installed; otherwise the option to set is printed).
HERE="$(cd "$(dirname "$0")" && pwd)"
STEAM="$HOME/Library/Application Support/Steam"
APPS="$STEAM/steamapps"
COMMON="$APPS/common"
NP="$HOME/Library/Application Support/notproton/runners/current"
SBDIR="$HOME/Library/Application Support/SpeechBridge"
TPL="$SBDIR/template-pfx"
USERCFG="$(ls -d "$STEAM"/userdata/*/config 2>/dev/null | head -1)"

[ -d "$APPS" ] || { echo "No Steam library at $APPS."; exit 1; }
[ -x "$NP/bin/wine" ] || echo "NotProton's runner is not at $NP; registrations inside prefixes will be skipped."

# ---- helpers -------------------------------------------------------------------------
bits_of() {   # 32- or 64-bit? PE magic 0x20b (523) at the optional header; od alone, so no python3 is needed
    pe=$(od -An -tu4 -j60 -N4 "$1" | tr -d ' ')
    magic=$(od -An -tu2 -j"$((pe + 24))" -N2 "$1" | tr -d ' ')
    if [ "$magic" = 523 ]; then echo 64; else echo 32; fi
}
is_ours() { strings -n 8 "$1" 2>/dev/null | grep -q "SpeechBridge"; }
replace() {   # replace <target> with <ours>, keeping the original once
    target="$1"; ours="$2"
    if is_ours "$target"; then
        cmp -s "$target" "$ours" || { cp "$ours" "$target"; echo "    updated $(basename "$target")"; }
        return
    fi
    [ -f "$target.orig" ] || cp "$target" "$target.orig"
    cp "$ours" "$target"; echo "    replaced $(basename "$target") (original kept as .orig)"
}
manifest_value() { sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$1" | head -1; }

# NotProton's own Wine, the way its run script sets it up.
wine_env() {
    export CX_ROOT="$NP"; export CX_HOME="$HOME/Library/Application Support/CrossOver"
    WINE_UNIX="$NP/lib/wine/aarch64-unix"; W="$WINE_UNIX/wine.app/Contents/MacOS/wine"; export WINESERVER="$NP/bin/wineserver-arm64"
    if [ ! -x "$W" ] || [ ! -x "$WINESERVER" ]; then
        WINE_UNIX="$NP/lib/wine/x86_64-unix"; W="$WINE_UNIX/wine"; export WINESERVER="$NP/bin/wineserver"
        [ -x "$WINESERVER" ] || export WINESERVER="$NP/bin/wineserver-x86"
    fi
    export WINELOADER="$W"; export WINEDLLPATH="$NP/lib/wine/x86_64-windows:$WINE_UNIX"
    export PATH="$NP/bin:$PATH"; export WINEDEBUG=-all
}
# inprefix <pfx> <command...>: one Windows command in that prefix; the server is stopped by stop_server.
inprefix() { p="$1"; shift; [ -x "$W" ] || return 1; WINEPREFIX="$p" "$W" "$@" >/dev/null 2>&1; }
stop_server() { [ -x "$WINESERVER" ] || return 0; WINEPREFIX="$1" "$WINESERVER" -w 2>/dev/null || true; WINEPREFIX="$1" "$WINESERVER" -k 2>/dev/null || true; }
game_running() { pgrep -f "compatdata/$1/" >/dev/null 2>&1; }
has_override() { grep -F -A8 "AppDefaults\\\\$2\\\\DllOverrides" "$1/user.reg" 2>/dev/null | grep -q "^\"$3\"=\"$4\""; }
set_override() {   # set_override <pfx> <exe> <dll> <value>
    has_override "$1" "$2" "$3" "$4" && return 0
    inprefix "$1" reg add "HKCU\\Software\\Wine\\AppDefaults\\$2\\DllOverrides" /v "$3" /t REG_SZ /d "$4" /f && SERVER_USED=1
    has_override "$1" "$2" "$3" "$4" && echo "    override: $2 loads $3 as $4" || echo "    override for $2/$3 did not land (is the game running?)"
}

wine_env
TOUCHED=""     # prefixes whose Wine server was started

# ---- which games ----------------------------------------------------------------------
IDS="$(awk '/"CompatToolMapping"/{f=1} f && /^\t+"[0-9]+"[[:space:]]*$/{gsub(/[\t" ]/,""); id=$0} f && /"name"/ && /"notproton"/{print id} f && /^\t{4}\}/{f=0}' "$STEAM/config/config.vdf" 2>/dev/null)"
for d in "$APPS"/compatdata/*/pfx; do [ -d "$d" ] && IDS="$IDS $(basename "$(dirname "$d")")"; done
IDS="$(printf '%s\n' $IDS | sort -un)"

echo "SpeechBridge for NotProton"
for ID in $IDS; do
    M="$APPS/appmanifest_$ID.acf"; [ -f "$M" ] || continue
    NAME="$(manifest_value "$M" name)"; DIR="$COMMON/$(manifest_value "$M" installdir)"
    [ -d "$DIR" ] || continue
    [ "$ID" = 228980 ] && continue   # Steamworks Common Redistributables
    PFX="$APPS/compatdata/$ID/pfx"
    echo "$NAME:"
    SERVER_USED=0

    # 1. The prefix.
    if [ ! -f "$PFX/system.reg" ]; then
        if [ -d "$TPL" ] && ! game_running "$ID"; then
            mkdir -p "$PFX"
            cp -c -R -n "$TPL/." "$PFX/" 2>/dev/null || cp -R -n "$TPL/." "$PFX/"
            [ -f "$SBDIR/template-notproton-msync" ] && cp -n "$SBDIR/template-notproton-msync" "$APPS/compatdata/$ID/notproton-msync" 2>/dev/null
            echo "    prefix made from the template (any Steam Cloud files already there were kept)"
        else
            echo "    no prefix yet: start the game once from Steam (NotProton makes its prefix), then run this again"
            continue
        fi
    fi
    S32="$PFX/drive_c/windows/system32"; S64="$PFX/drive_c/windows/syswow64"

    # 2. Stand-ins into Windows' own folders, and their registration.
    mkdir -p "$PFX/drive_c/SpeechBridge" "$S64"
    cp "$HERE/SapiBridge/SapiBridge64.dll" "$HERE/SpVoice/SpVoiceBridge64.dll" "$HERE/SAAPI64/SAAPI64.dll" "$HERE/ZDSR/ZDSRAPI_x64.dll" "$S32/"
    cp "$HERE/SapiBridge/SapiBridge32.dll" "$HERE/SpVoice/SpVoiceBridge32.dll" "$HERE/ZDSR/ZDSRAPI.dll" "$S64/"
    cp "$HERE/NVDA/nvdaControllerClient64.dll" "$S32/nvdaControllerClient64.dll"; cp "$HERE/NVDA/nvdaControllerClient64.dll" "$S32/nvdaControllerClient.dll"
    cp "$HERE/NVDA/nvdaControllerClient32.dll" "$S64/nvdaControllerClient32.dll"; cp "$HERE/NVDA/nvdaControllerClient32.dll" "$S64/nvdaControllerClient.dll"
    [ -f "$HERE/RenPy/sbsay.exe" ] && cp "$HERE/RenPy/sbsay.exe" "$HERE/RenPy/renpy.reg" "$PFX/drive_c/SpeechBridge/"
    need=""
    grep -q 'system32\\\\SapiBridge64.dll' "$PFX/system.reg" && grep -q 'Tokens\\\\SpeechBridge\]' "$PFX/system.reg" || need="$need sapi"
    grep -q 'system32\\\\SpVoiceBridge64.dll' "$PFX/system.reg" || need="$need spvoice"
    grep -q 'zhiduo\\\\zdsr\]' "$PFX/system.reg" || need="$need zdsr"
    grep -q 'RENPY_TTS_COMMAND' "$PFX/user.reg" || need="$need renpy"
    if [ -n "$need" ]; then
        if game_running "$ID"; then echo "    the game is running: registrations ($need) wait until it is closed"
        elif [ ! -x "$W" ]; then echo "    NotProton's Wine not found: registrations ($need) skipped"
        else
            for n in $need; do case "$n" in
                sapi)    inprefix "$PFX" regsvr32 /s 'C:\windows\system32\SapiBridge64.dll'; inprefix "$PFX" 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\SapiBridge32.dll' ;;
                spvoice) inprefix "$PFX" regsvr32 /s 'C:\windows\system32\SpVoiceBridge64.dll'; inprefix "$PFX" 'C:\windows\syswow64\regsvr32.exe' /s 'C:\windows\syswow64\SpVoiceBridge32.dll' ;;
                zdsr)    inprefix "$PFX" reg add 'HKLM\SOFTWARE\WOW6432Node\zhiduo\zdsr' /v Path /t REG_SZ /d 'C:\SpeechBridge' /f ;;
                renpy)   [ -f "$PFX/drive_c/SpeechBridge/renpy.reg" ] && inprefix "$PFX" regedit /S 'C:\SpeechBridge\renpy.reg' ;;
            esac; done
            SERVER_USED=1; stop_server "$PFX"; SERVER_USED=0
            left=""
            grep -q 'system32\\\\SapiBridge64.dll' "$PFX/system.reg" || left="$left sapi"
            grep -q 'system32\\\\SpVoiceBridge64.dll' "$PFX/system.reg" || left="$left spvoice"
            grep -q 'zhiduo\\\\zdsr\]' "$PFX/system.reg" || left="$left zdsr"
            grep -q 'RENPY_TTS_COMMAND' "$PFX/user.reg" || left="$left renpy"
            [ -z "$left" ] && echo "    stand-ins registered ($need)" || echo "    registration did not land for:$left (run again)"
        fi
    else
        echo "    stand-ins in place and registered"
    fi

    # 3. Speech DLLs the game ships.
    find "$DIR" -maxdepth 8 \( -iname "nvdaControllerClient.dll" -o -iname "nvdaControllerClient64.dll" -o -iname "nvdaControllerClient32.dll" -o -iname "WindowsTTS.dll" -o -iname "Tolk.dll" \) 2>/dev/null | sort | while IFS= read -r f; do
        name="$(basename "$f" | tr '[:upper:]' '[:lower:]')"; dir="$(dirname "$f")"; bits="$(bits_of "$f")"
        case "$name" in
            nvdacontrollerclient*.dll) replace "$f" "$HERE/NVDA/nvdaControllerClient$bits.dll" ;;
            windowstts.dll)            replace "$f" "$HERE/WindowsTTS/WindowsTTS$bits.dll" ;;
            tolk.dll)
                if [ "$bits" = 64 ] && [ -f "$dir/SAAPI64.dll" ]; then
                    is_ours "$dir/SAAPI64.dll" || { [ -f "$dir/SAAPI64.dll.orig" ] || cp "$dir/SAAPI64.dll" "$dir/SAAPI64.dll.orig"; }
                    cmp -s "$HERE/SAAPI64/SAAPI64.dll" "$dir/SAAPI64.dll" || { cp "$HERE/SAAPI64/SAAPI64.dll" "$dir/SAAPI64.dll"; echo "    SAAPI64.dll replaced beside Tolk.dll"; }
                fi ;;
        esac
    done
    # Diablo IV: nothing in its folder; its protection layer ends the game two minutes after a DLL loads from there.
    [ -f "$DIR/SAAPI64.dll" ] && [ -f "$DIR/Diablo IV.exe" ] && { rm -f "$DIR/SAAPI64.dll" "$DIR/SAAPI64.log"; echo "    removed SAAPI64.dll from the game folder (served from system32)"; }

    # 4. Overrides the mod loaders need, by the game's executable.
    if game_running "$ID"; then echo "    the game is running: overrides checked next time"
    else
        [ -f "$DIR/Ship/Hades2.exe" ] && [ -f "$DIR/Ship/d3d12.dll" ] && set_override "$PFX" Hades2.exe d3d12 native,builtin
        [ -f "$DIR/FINAL FANTASY VI.exe" ] && [ -f "$DIR/version.dll" ] && set_override "$PFX" "FINAL FANTASY VI.exe" version native,builtin
        [ -f "$DIR/bin/x64/Cyberpunk2077.exe" ] && [ -f "$DIR/bin/x64/winmm.dll" ] && set_override "$PFX" Cyberpunk2077.exe winmm native,builtin
        if [ -f "$DIR/Fallout4.exe" ]; then
            if [ "$(stat -f %z "$S32/xaudio2_7.dll" 2>/dev/null || echo 0)" -lt 400000 ]; then
                if [ -f "$TPL/drive_c/windows/system32/xaudio2_7.dll" ] && [ "$(stat -f %z "$TPL/drive_c/windows/system32/xaudio2_7.dll")" -gt 400000 ]; then
                    for f in xaudio2_7 x3daudio1_7 xapofx1_5 xactengine3_7; do cp "$TPL/drive_c/windows/system32/$f.dll" "$S32/"; cp "$TPL/drive_c/windows/syswow64/$f.dll" "$S64/" 2>/dev/null; done
                    echo "    Microsoft's XAudio2 copied in from the template (sound fix)"
                elif command -v cabextract >/dev/null && [ -d "$COMMON/Steamworks Shared/_CommonRedist/DirectX/Jun2010" ]; then
                    DXC="$COMMON/Steamworks Shared/_CommonRedist/DirectX/Jun2010"; T="$(mktemp -d)"
                    for c in Jun2010_XAudio_x64 Jun2010_XACT_x64 Feb2010_X3DAudio_x64; do cabextract -q -d "$T/64" "$DXC/$c.cab" 2>/dev/null; done
                    for c in Jun2010_XAudio_x86 Jun2010_XACT_x86 Feb2010_X3DAudio_x86; do cabextract -q -d "$T/32" "$DXC/$c.cab" 2>/dev/null; done
                    for f in XAudio2_7 XAPOFX1_5 xactengine3_7 X3DAudio1_7; do
                        [ -f "$T/64/$f.dll" ] && cp "$T/64/$f.dll" "$S32/$(echo "$f" | tr 'A-Z' 'a-z').dll"
                        [ -f "$T/32/$f.dll" ] && cp "$T/32/$f.dll" "$S64/$(echo "$f" | tr 'A-Z' 'a-z').dll"
                    done; rm -rf "$T"; echo "    Microsoft's XAudio2 extracted from Steam's DirectX redistributable (sound fix)"
                else echo "    sound: Microsoft's XAudio2 not available (no template, no cabextract)"; fi
            fi
            for v in xaudio2_7 x3daudio1_7 xapofx1_5 xactengine3_7; do set_override "$PFX" Fallout4.exe "$v" native; done
            if [ -f "$DIR/f4se_loader.exe" ] && ! cmp -s "$DIR/f4se_loader.exe" "$DIR/Fallout4Launcher.exe"; then
                [ -f "$DIR/Fallout4Launcher.exe.orig" ] || cp "$DIR/Fallout4Launcher.exe" "$DIR/Fallout4Launcher.exe.orig"
                cp "$DIR/f4se_loader.exe" "$DIR/Fallout4Launcher.exe"; echo "    F4SE loader put in the launcher's place (original kept as .orig)"
            fi
            # Settings and plugin list, if the Mac's own Documents still has them from the CrossOver days.
            U="$PFX/drive_c/users/steamuser"
            [ -d "$U/Documents/My Games/Fallout4" ] || { [ -d "$HOME/Documents/My Games/Fallout4" ] && mkdir -p "$U/Documents/My Games" && cp -R "$HOME/Documents/My Games/Fallout4" "$U/Documents/My Games/" && echo "    Fallout 4 settings and saves copied in"; }
            [ -f "$U/AppData/Local/Fallout4/plugins.txt" ] || { mkdir -p "$U/AppData/Local/Fallout4"; printf '*XDI.esm\n*fallout4access.esp\n' > "$U/AppData/Local/Fallout4/plugins.txt"; echo "    plugins.txt written (XDI, Fallout 4 Access)"; }
        fi
        [ "$SERVER_USED" = 1 ] && stop_server "$PFX"
    fi
done

# ---- launch options (Steam must be closed) ----------------------------------------------
LO_IDS=""; LO_OPTS=""
[ -f "$COMMON/Stardew Valley/StardewModdingAPI.exe" ] && LO_IDS="$LO_IDS 413150"
[ -f "$COMMON/Periphery Synthetic EP/periphery-synthetic-ep.exe" ] && LO_IDS="$LO_IDS 2121790"
if [ -n "$LO_IDS" ] && [ -f "$USERCFG/localconfig.vdf" ]; then
    if pgrep -x steam_osx >/dev/null; then
        missing=""
        for id in $LO_IDS; do
            case "$id" in 413150) pat='StardewModdingAPI.exe';; 2121790) pat='remote-debugging-port=9223';; esac
            awk -v id="\"$id\"" '$1==id{f=1} f&&/"LaunchOptions"/{print; exit} f&&/^\t{5}\}/{exit}' "$USERCFG/localconfig.vdf" | grep -q "$pat" || missing="$missing $id"
        done
        [ -n "$missing" ] && echo "Launch options still to set for app(s):$missing. Quit Steam and run Setup again."
    elif ! xcode-select -p >/dev/null 2>&1; then
        echo "Launch options: without Apple's Command Line Tools they can't be written here. In Steam, each game's Properties, Launch options:"
        for id in $LO_IDS; do case "$id" in
            413150)  echo "  Stardew Valley:      bash -c 'exec \"\${@/Stardew Valley.exe/StardewModdingAPI.exe}\"' -- %command%" ;;
            2121790) echo "  Periphery Synthetic: %command% --remote-debugging-port=9223" ;;
        esac; done
    else
        python3 -I - "$USERCFG/localconfig.vdf" $LO_IDS <<'PY'
import re, sys
p = sys.argv[1]; ids = sys.argv[2:]
want = {"413150": "bash -c 'exec \\\"${@/Stardew Valley.exe/StardewModdingAPI.exe}\\\"' -- %command%",
        "2121790": "%command% --remote-debugging-port=9223"}
s = open(p, encoding='utf-8', errors='surrogateescape').read()
m = re.search(r'("Steam"\s*\{\s*)("apps"\s*\{)', s)
if not m: print("Launch options: apps block not found in localconfig.vdf"); sys.exit(0)
a0 = m.end(2); depth = 1; i = a0
while depth:
    c = s[i]; depth += (c == '{') - (c == '}'); i += 1
a1 = i - 1; apps = s[a0:a1]; changed = []
for appid in ids:
    lo = want[appid]
    bm = re.search(r'(\n(\t*)"%s"\s*\{\n)' % appid, apps)
    if bm:
        ind = bm.group(2) + '\t'; b0 = bm.end(1); d = 1; j = b0
        while d:
            d += (apps[j] == '{') - (apps[j] == '}'); j += 1
        body = apps[b0:j-1]
        cur = re.search(r'"LaunchOptions"\s*"((?:[^"\\]|\\.)*)"', body)
        if cur and cur.group(1) == lo: continue
        body = re.sub(r'"LaunchOptions"\s*"(?:[^"\\]|\\.)*"', '"LaunchOptions"\t\t"%s"' % lo, body) if cur else ind + '"LaunchOptions"\t\t"%s"\n' % lo + body
        apps = apps[:b0] + body + apps[j-1:]
    else:
        ind = '\t' * 5
        apps += '%s"%s"\n%s{\n%s\t"LaunchOptions"\t\t"%s"\n%s}\n' % (ind, appid, ind, ind, lo, ind)
    changed.append(appid)
if changed:
    open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s[:a0] + apps + s[a1:])
    print("Launch options set for app(s): " + " ".join(changed))
PY
    fi
fi

# ---- TurnOver ------------------------------------------------------------------------------
# TurnOver's speech port listens whenever TurnOver runs (its executable is "turnover").
if lsof -nP -iTCP:52134 -sTCP:LISTEN 2>/dev/null | grep -q turnover; then echo "TurnOver is listening for game speech (port 52134). A game asks to speak through it the first time; answer Allow."
elif lsof -nP -iTCP:52134 -sTCP:LISTEN 2>/dev/null | grep -q .; then echo "Something other than TurnOver holds port 52134: $(lsof -nP -iTCP:52134 -sTCP:LISTEN | tail -1 | awk '{print $1}'). Quit it (the old SpeechBridge Listener: sh listener/login-item.sh --remove), or the two fight."
else echo "TurnOver is not running, so nothing is listening on port 52134: start TurnOver."; fi
