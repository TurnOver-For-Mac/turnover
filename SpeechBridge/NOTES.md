# SpeechBridge: the engineering notes

This is the working log of September 2026, kept as it was written: what was measured, what failed and why, with
dates. The listener it describes (`listener/`) spoke through VoiceOver; since October 2026 TurnOver's speech port
takes the same lines on the same port (`Sources/Core/Speech/SpeechPort.swift`), and TurnOver reads Big Picture
itself, so "the listener" below reads as "TurnOver" for anyone using TurnOver. [README.md](README.md) is the
current, ordered account; this file is where its claims come from.

# SpeechBridge — Diablo IV's screen reader, out of the bottle and into VoiceOver

Diablo IV's reader speaks through Windows TTS, or through Tolk's screen-reader
drivers when "third-party screen reader" is on. Under Wine neither has anything to
talk to, so the game runs and says nothing. Tolk's System Access driver only
needs a `SAAPI64.dll` beside the game that answers four calls; this is that DLL,
plus a Mac process it talks to over loopback. D4TTS on Windows works the same way,
which is how we know the game takes this path.

    game ─ Tolk ─ SAAPI64.dll ─ 127.0.0.1:52134 ─ d4bridge ─ VoiceOver / system voice

The DLL also appends every call to `SAAPI64.log` beside itself, so the first test
needs no listener at all.

## Before anything else

- Apple Silicon, macOS 26.4 or later, CrossOver 26 or later with D3DMetal and
  MSync on in the bottle's Advanced settings. The Season 12 update broke the game
  under CrossOver until 26.4; an older macOS reads as "Wine doesn't work".
- The game must reach its options menu at all. Do that first, with nothing from
  here installed.

## Step 1 — proof the game talks to the DLL

1. Build the DLL, or use the committed `SAAPI64/SAAPI64.dll`:

       brew install mingw-w64
       SpeechBridge/SAAPI64/build.sh

2. Copy it next to `Diablo IV.exe` in the bottle. For the Steam copy:

       ~/Library/Application Support/CrossOver/Bottles/<bottle>/drive_c/Program Files (x86)/Steam/steamapps/common/Diablo IV/

3. Start the game. Options → Accessibility → Screen Reader on, and
   "Third-party screen reader" on. Move through a menu.
4. Read `SAAPI64.log` in that folder. Lines of menu text mean the whole design
   holds. `# SpeechBridge SAAPI64 loaded` alone means the game loaded the DLL but sent
   nothing — check the two toggles. No file at all means Tolk never loaded it.

### Step 1 result, 28 September 2026: it talks

Verified on the owner's M4 MacBook Air, CrossOver 26.3, D3DMetal + MSync: Diablo IV
(Steam, 161 GB) launched, logged in, and at its first-run "Screen Reader Enable/Disable"
prompt Enable was taken; from then on every line goes game → Tolk → `SAAPI64.dll` →
listener → VoiceOver ("BRIGHTNESS. Adjust the brightness slider until the logo is
barely visible."). Three things had to be true first, and none of them is the DLL:

1. **The game's reader initialises SAPI before it will touch Tolk**, and it wants a voice
   whose Language is exactly "409". With no such voice it logs `[ScreenReader] ERROR:
   SAPI does not contain a voice that supports "en-us"` / `kMissingVoice` in
   `FenrisDebug.txt` and never loads Tolk at all. `SapiBridge` now registers two tokens,
   en-US (409) and en-GB (809), rather than one with "809;409".
2. **`LocalPrefs.txt`** (Documents\Diablo IV) holds `UseScreenReader`, `UseThirdPartyReader`
   and `SkipIntroMovie`; the game rewrites `UseScreenReader` at start-up until the first-run
   prompt has been answered, so the prompt is the real switch. `UseThirdPartyReader "1"` is
   what makes it use Tolk.
3. **The first-run prompt is not spoken** (the reader is not on yet), so a blind player
   needs it answered for them once: Enable is the highlighted button, Return takes it.

Once the first-run flow has been completed the prompt stops and `UseScreenReader "1"` and
`FirstTimeFlowCompleted "1"` stay in LocalPrefs; the log then reads
`[ScreenReader] voice Enabled "...Tokens\SpeechBridge"` at start-up. The owner reached the
open world with the UI read ("Left shoulder button", "Stash"). **One crash seen**: ten seconds
after the game lost focus and regained it ("Application Deactivated" … "Application
Activated" … "[Crash] Thread '' handling fatal error", nothing more) — the usual
fullscreen-and-focus failure under D3DMetal. Avoid switching apps mid-game; if it recurs,
change Display Mode in the game's graphics options (now readable) to a windowed mode.

**The crashes, solved (28 Sep 2026, evening).** Every speaking run died 123 s after the
process started; silent runs lived. WINEDEBUG=+seh,+sapi showed two things. (1) The fatal
error is raised by `diablo_iv_loader.dll`, the game's protection layer, about two minutes
after a DLL is loaded from anywhere but Windows' own folders — `SAAPI64.dll` in the game
folder, `SapiBridge64.dll` in `C:\SpeechBridge`, even a do-nothing DLL. The same DLLs in
`C:\windows\system32` (and `syswow64`) are accepted, and Tolk finds `SAAPI64.dll` there
through the normal search order. (2) The game's own SAPI voice hands Wine an `ISpStream` of
its own to render into; Wine's `speak_proc` fails every Speak with "failed setting output
format: E_NOTIMPL". `SpVoice/` is a stand-in for SAPI's SpVoice object, registered over
CLSID_SpVoice from system32: it implements ISpVoice, forwards Speak to the listener, reports
done at once and never touches audio. With both in place the game ran past ten minutes in the
world, reading as it went ("Spawn of the Damned"). `install.sh` now places the bottle-wide
DLLs in system32/syswow64 and keeps Diablo IV's folder clean. Tolk chose System Access over
the NVDA stand-in; the game's reader picks the first voice token alphabetically.

The game's own log is `FenrisDebug.txt` in the game folder; `[ScreenReader]` lines there
say why the reader did or did not come up. Tolk's own choice can be checked with
`SpeechBridge/Tolk/tolktest.c` run from the game folder.

## Step 2 — first words

Either listener works; start one before the game.

    python3 SpeechBridge/listener/d4bridge.py          # system voice via `say`, no build

    swiftc -O -o d4bridge SpeechBridge/listener/d4bridge.swift
    ./d4bridge                                          # VoiceOver when running, else system voice
    ./d4bridge --voice                                  # system voice regardless

Test without the game:

    printf 'S Hello from the bridge\n' | nc 127.0.0.1 52134

Then move through the game's menus. The listener prints every line it speaks.

## SapiBridge — games that use the built-in Windows voice

Many smaller games speak through SAPI 5 (`SpVoice`) rather than a screen reader.
Wine implements SAPI, but its only voice's engine is a stub (`msttsengine.dll`:
"Speak … stub"), so the game runs and says nothing. `SapiBridge/` is a SAPI
engine DLL that registers itself as a voice — and as the *default* voice — and
forwards each utterance to the same listener on port 52134. Wine's speak thread
waits for the engine's audio to finish before the game's call returns, so the
engine writes 40 ms of silence per utterance and nothing else touches audio.

    game ─ sapi.dll (Wine) ─ SapiBridge64.dll / SapiBridge32.dll ─ 127.0.0.1:52134 ─ d4bridge

1. Build both DLLs and the test programs: `SpeechBridge/SapiBridge/build.sh`.
2. Copy `SapiBridge64.dll` and `SapiBridge32.dll` somewhere permanent in the
   bottle, e.g. `drive_c/SpeechBridge/`, and register each one **from inside the
   bottle** (a 32-bit game reads the 32-bit registry view):

       regsvr32 C:\SpeechBridge\SapiBridge64.dll
       C:\windows\syswow64\regsvr32 C:\SpeechBridge\SapiBridge32.dll

3. Run `sapitest64.exe` (or `32`) in the bottle. It writes `sapitest.log` beside
   itself with each SAPI call's result and timing, the engine appends to
   `SpeechBridge.log` beside the DLL, and the listener prints what it speaks.

**Verified 28 Sep 2026, 64- and 32-bit:** `sapitest` found the SpeechBridge token as
the default voice, both Speak calls returned S_OK, the engine logged both lines and the
listener spoke them. The first Speak in a process takes ~2.5 s (Wine opening its audio
output); later ones ~80 ms. One Wine-specific fact the registration depends on: Wine's
`token_category_GetDefaultTokenId` reads a value named **`DefaultDefaultTokenId`** under
`HKLM\SOFTWARE\Microsoft\Speech\Voices`, not Windows' `DefaultTokenId`, and a fresh
bottle has neither — so before this DLL *every* default-voice lookup failed with
SPERR_NOT_FOUND (0x8004503A), which is also why Wine's own stub voice was never reached.
`DllRegisterServer` writes both names.

Two things measured on 28 Sep 2026 while setting this up. **Anything started in
the bottle from a shell that is not part of the GUI login session hangs or
dies**: with MSync on, Wine clients find the server through a Mach bootstrap
port, and a shell in another bootstrap namespace never meets it (the symptom is
a launch wrapper that waits forever, or Steam exiting after three minutes with
"stalled cross-thread pipe"). Run things through `open -a CrossOver <exe>` or
through a small script app launched with `open`. **A VBScript SAPI test hangs
in `GetVoices`** under this Wine (the scripting host's apartment, most likely);
use the compiled `sapitest` instead of `cscript`.

## Games that ship NVDA's client or the UAP WindowsTTS plugin

Unity games built on the Unity Accessibility Plugin (UAP) carry
`nvdaControllerClient.dll` and `WindowsTTS.dll` in `<game>_Data/Plugins/x86_64/`.
`NVDA/` and `WindowsTTS/` are stand-ins for both, on the same bridge core: the NVDA one
answers "NVDA is running" and forwards `speakText` / `cancelSpeech`; the WindowsTTS one
has the plugin's exports (both generations — the WinRT one with `IsScreenReaderActive` /
`SetCultureInfo`, and the older SAPI one with `SetVoiceSAPI`) and does nothing dangerous.
Copy them over the game's copies, keeping the originals as `.orig` (Steam's "verify
integrity" restores them). Each logs beside itself.

Verified 28 Sep 2026: **Bits & Bops** (crashed at start-up inside its WinRT WindowsTTS
plugin under Wine every time, even with NVDA present, because it initialises the plugin
regardless; both stand-ins fix it) and **Rhythm Doctor** (no crash; its managed SAPI init
throws a COMException it survives, and the NVDA stand-in carries every line).

**Listener**: `listener/build.sh` builds `/Applications/SpeechBridge Listener.app`, which
speaks through VoiceOver when it is running: each batch of lines goes to VoiceOver's
`output` command as a raw Apple event (class VOAS, id outp) sent from the app on a serial
queue with a 3 s timeout — a child `osascript` per line cost ~500 ms each, measured 28 Sep
2026, and that was the lag heard in Diablo IV; lines within 40 ms are one utterance, and a
batch older than 1.5 s is dropped and the system voice otherwise. It needs the
Automation permission for VoiceOver once. Build with `-target arm64-apple-macos14.0`:
the toolchain's default minimum OS was newer than the installed macOS and Launch Services
refused the app with error -10825.

## Keeping it working: install.sh and the login agent

`SpeechBridge/install.sh [bottle]` scans every game in the bottle's `steamapps/common`
and puts the right stand-ins in place — the NVDA and WindowsTTS ones over a game's own
copies (originals kept as `.orig`, ownership told apart by a "SpeechBridge" marker string
in ours), `SAAPI64.dll` beside any `Tolk.dll` and in Diablo IV's folder — and copies the
SAPI voice DLLs into `C:\SpeechBridge`, reporting whether they are registered. It only
copies files, so it is safe from a Mac shell (nothing runs in the bottle), and it is a
no-op when everything is already in place. **Run it after installing a game and after any
Steam "verify integrity".** `--uninstall` puts every `.orig` back.

**"SpeechBridge Setup" in /Applications** is the installer as an app: `setup-app/build.sh`
bundles `install.sh` and every stand-in DLL into it, so opening it runs the installer and
shows a dialog with what changed. It must be self-contained — an app that reads its script
from `~/Desktop` sits forever in a macOS privacy prompt (measured 29 Sep 2026). Rebuild it
after changing `install.sh` or any DLL.

`listener/login-item.sh` installs a launchd agent (`~/Library/LaunchAgents/
com.oliverkennett.speechbridge-listener.plist`, RunAtLoad + KeepAlive) so the listener
starts at login and comes back if it stops; `--remove` takes it out. Verified 28 Sep 2026:
the launchd-started copy keeps the VoiceOver Automation permission.

## Stardew Valley with Stardew Access (verified 28 Sep 2026)

The Windows game in the bottle, SMAPI 4.5.2 installed by hand (unzip
`internal/windows/install.dat` into the game folder, copy `Stardew Valley.deps.json` to
`StardewModdingAPI.deps.json`), and in `Mods/`: Stardew Access 1.6.2 with its dependencies
Kokoro 3.0.0 and Project Fluent 2.0.0 (both from Shockah's GitHub releases). Stardew Access
speaks through Tolk, whose drivers live in `Mods/stardew-access/lib/screen-reader-libs/windows/`;
`install.sh` swaps its `nvdaControllerClient64.dll` for the NVDA stand-in and its `SAAPI64.dll`
for ours (originals kept). First run: "Stardew Access version 1.6.2 Loaded", then the title
screen and menu buttons, via SAAPI64. Launch with `open -a CrossOver …/StardewModdingAPI.exe`
(the app "Stardew Valley (Stardew Access)" in /Applications does exactly that), or set
Steam's launch option to `"…\StardewModdingAPI.exe" %command%` so Big Picture launches SMAPI.
CrossOver's trial dialog, when it is up, swallows any `open -a CrossOver` launch silently.

## Web games in an Electron shell (Periphery Synthetic EP)

Some games speak through nothing at all: they are web pages in Electron that write to
`aria-live` regions and expect a screen reader to read them. In the bottle there is none,
so the listener carries a **web reader**: it polls `127.0.0.1:9223/json/list`, attaches to
every page there, installs a MutationObserver on the live regions (and role alert/status/log)
plus a focus listener, and speaks what changes — Steam Speak's Big Picture technique, made
generic. The game has to be started with `--remote-debugging-port=9223`; for a Steam game
that is the launch option `%command% --remote-debugging-port=9223`. Verified 29 Sep 2026:
the listener attached to Periphery Synthetic's page and a binding call came back as speech.
`tools/run-in-bottle.applescript` is the applet that starts a command in the bottle from the
GUI session (built into ~/Library/Application Support/SpeechBridge/run-in-bottle/), with
`cdpkeys.py` / `cdpeval.py` beside it for driving and inspecting a page over the port.

## Hades II with the blind accessibility mods (installed 29 Sep 2026)

Three Thunderstore mods, installed by hand (r2modman is not usable from here): Lirin's
**Blind Accessibility** 1.0.7, Lirin's **Hades 2 TOLk Compatibility** 2.0.0 and FlatArther's
**HadesIIAccess** 0.6.1, with their seven dependencies (Hell2Modding 1.0.112, LuaENVY-ENVY,
SGG_Modding ENVY / Chalk / ReLoad / SJSON / ModUtil / DemonDaemon). Layout, in the game's
`Ship` folder: Hell2Modding's `d3d12.dll` beside `Hades2.exe`; each package unpacked into
`ReturnOfModding/plugins/<Team-Name>/`; HadesIIAccess's `plugins_data` moved to
`ReturnOfModding/plugins_data/FlatArther-HadesIIAccess/` (its `config` folder stays inside the
plugin, the code loads it relative to itself). Wine loads the loader only with
`HKCU\Software\Wine\AppDefaults\Hades2.exe\DllOverrides` `d3d12 = native,builtin`; the proxy
loads the real d3d12 from system32 by path, which resolves to CrossOver's, so D3DMetal is
untouched. Hell2Modding has Tolk compiled in and picks "System Access" — the SAAPI64 stand-in
in system32 — so speech arrives at the listener with nothing else installed. Verified: the
loader's `ReturnOfModding/LogOutput.log` lists every package, and the listener spoke the main
menu. To update a mod, unpack the new zip over its plugin folder; to play unmodded, rename
`d3d12.dll`.

## Fallout 4 with Fallout 4 Access (installed 29 Sep 2026)

Fallout 4 is 1.11.240 in the bottle, so: **F4SE 0.7.9** (loader, DLL and its Data\Scripts in
the game folder), **Address Library** (only `version-1-11-240-0.bin` from the all-in-one),
**Extended Dialogue Interface**, **Mod Configuration Menu** (a requirement the mod's own
download dialog lists) and **Fallout 4 Access 0.1.0** by alex19EP, all in `Data`. Loose files
need `Fallout4Custom.ini` (`bInvalidateOlderFiles=1`, empty `sResourceDataDirsFinal`) in
Documents\My Games\Fallout4, and the plugin list is `AppData\Local\Fallout4\plugins.txt`
(`*XDI.esm`, `*fallout4access.esp`). **No launch option**: `"f4se_loader.exe" %command%` fails
under F4SE 0.7.9 with "too many free args" (Steam expands `%command%` to the launcher's path
and the loader refuses it), so `f4se_loader.exe` is copied over `Fallout4Launcher.exe` with
the original kept as `.orig`; install.sh re-applies that after a Steam verify. **Controller:**
Fallout 4 wants XInput, which a DualSense under Wine is not; Steam Input forced on fixes it.
That setting is `UseSteamControllerConfig "2"` under the top-level `apps` block of
`localconfig.vdf` (with `SteamControllerRumble "-1"`, `SteamControllerRumbleIntensity "320"`),
the same three lines Diablo IV and Stardew got from the Big Picture UI; set 29 Sep 2026.
**Sound:** the owner heard static and no footsteps. Wine's own XAudio2 (FAudio) is the known
cause with this game (CodeWeavers' Fallout 4 tip and AppleGamingWiki both prescribe overrides
for xaudio2_6/7 and x3daudio1_6/7); the fix is Microsoft's real XAudio2 2.7, XAPOFX 1.5,
XACT 3.7 and X3DAudio 1.7, taken from the DirectX June 2010 cabinets every Steam install has
under `Steamworks Shared/_CommonRedist/DirectX/Jun2010` (cabextract), copied into
system32/syswow64, with `native` overrides scoped to `Fallout4.exe`. install.sh does the copy
and checks the overrides. Verified only that `X3DAudio1_7.dll` loads native (`+loaddll`);
XAudio2 is created through COM at audio start and takes the same override. **Do not test by
launching `Fallout4.exe` or the loader from the applet**: started outside Steam the game
re-launches itself through Steam and exits, and the applet's working directory is not the
game folder, so F4SE cannot find the Address Library and shows "address library needs to be
updated" — a dialog that reached the owner once. Test through Steam, by ear. All four Nexus files were fetched through the owner's Chrome
login; Chrome's own download manager stalled on the 55 MB one, so the page fetched it and
saved it through a button clicked as a real click (a script-started save is blocked as an
"automatic download").

**How it speaks: through the ZDSR stand-in.** Fallout 4 Access uses the Prism speech library
(github.com/ethindp/prism), which tries screen readers first and Windows voices last. Under
Wine every route it prefers is closed: NVDA is spoken to over RPC (`NvdaCtlr.<session>`), so
the nvdaControllerClient stand-in is never loaded; JAWS wants a COM server; OneCore is not
implemented; and SAPI is skipped because Prism's support check calls `CoGetClassObject` on a
thread that has not initialised COM (`tools/prism/prismtest.c` reproduces every SAPI call:
all pass once COM is up, except the cross-thread marshal, which newer Prism tolerates).
The ZDSR backend needs only a registry key (`HKLM\SOFTWARE\WOW6432Node\zhiduo\zdsr`, older
Prism) or a ZDSR process (newer) and a `ZDSRAPI_x64.dll` with five exports. `ZDSR/zdsrapi.c`
is that DLL, forwarding to the listener; install.sh puts it in system32/syswow64 and checks the
key. Verified: `Prism initialized, speaking through ZDSR`, and the listener read the main
menu. Anything else built on Prism will take the same door. If a future Prism drops the
registry check, a stand-in process named `ZDSRDaemon.exe` is the answer.

## Final Fantasy VI Pixel Remaster with the FF6 Screen Reader mod (installed 29 Sep 2026)

BlindGuyNW's **FF6 Screen Reader v2.0** (github.com/BlindGuyNW/FF6ScreenReader) on **MelonLoader
0.7.3**. The game is Unity 2019.4.26, Il2Cpp. Layout in the game folder: MelonLoader's
`version.dll` and `MelonLoader/` from `MelonLoader.x64.zip`; `Mods/FFVI_ScreenReader.dll`,
`Tolk.dll` and `nvdaControllerClient64.dll` from the mod's zip (the stand-in replaces the
latter; the Setup app does that). Wine needs `HKCU\Software\Wine\AppDefaults\FINAL FANTASY
VI.exe\DllOverrides` `version = native,builtin`. **First launch does a lot on its own:**
MelonLoader downloads and runs Microsoft's .NET 6 runtime installer inside the bottle (it
went into `C:\Program Files\dotnet`, hostfxr found), then fetches Cpp2IL, its plugin and
the Unity dependencies and generates the interop assemblies — about nine minutes on this
slow line, 30 seconds of it work. It logs `OS: Wine/Proton 11.0` and carries on. The mod then
loads and Tolk picks the System Access stand-in; the game read its opening crawl into the
listener. Log: `MelonLoader/Latest.log` in the game folder.

**Launching through Steam without the Steam window:** started directly, the game hands
itself to Steam and quits (as Fallout 4 does); `steam.exe -applaunch` as a second process
hung the applet. What works is Steam's own interface call over its debugging port:
`tools/cdpsteam.py 8080 'SteamClient.Apps.RunGame("<appid>", "", -1, 100)'` (SharedJSContext).
Steam's first launch of a controller game parks at an **"On-Screen Keyboard" notice** in Big
Picture ("LaunchApp waiting for user response to ShowInterstitials" in `logs/console_log.txt`);
`tools/cdptitle.py 8080 '<js>' "Steam Big Picture Mode"` reads and clicks it — tick "Don't
show this on future games" and OK, done once.

## Cyberpunk 2077 with Cyberpunk Access (installed 29 Sep 2026)

Game 2.31 (Windows build in the bottle; the native Mac version cannot take these mods).
**Cyberpunk Access 1.4.1** by Ludark (Nexus 31539) and its nine requirements: **Cyber TTS
Engine 1.1** (31500), **RED4ext 1.30.0** (2380), **redscript 0.5.31** (1511), **Codeware
1.20.5** (7780), **TweakXL 1.11.4** (4197), **ArchiveXL 1.27.3** (4198), **Input Loader
0.2.3** (4575), **Mod Settings 0.2.21** (4885), and **Audioware 1.9.4** from GitHub
(cyb3rpsych0s1s/audioware — the mod asks for that exact version, not Nexus's). Every archive
unpacks over the game folder (Cyberpunk Access from its own top folder). RED4ext loads through
`bin\x64\winmm.dll`, so `HKCU\Software\Wine\AppDefaults\Cyberpunk2077.exe\DllOverrides`
`winmm = native,builtin`. **Cyber TTS Engine speaks through Prism**, so the ZDSR stand-in
carries it with nothing new: on launch through Steam, RED4ext logged all seven plugins,
redscript compiled, and the listener read "Text to speech enabled", the user agreement and
"Main Menu". The Nexus files were fetched by generating each file's download link in the
owner's logged-in Chrome (`GenerateDownloadUrl` with the file id and game id 3333, read off
the `?tab=files` page) and pulling it with curl. Untested: performance on the M4 Air, and the
mod's beacons in play.

## Rumble over Bluetooth (fixed 29 Sep 2026)

Over USB the pad rumbled in Steam games; over Bluetooth it did not. Measured with a Windows
test program in the bottle (`tools/rumble/hidrumble.c`) and a Mac-side motion monitor
(`tools/rumble/motion.swift`, which watches the pad's own gyro and accelerometer — the motors
shake them, so a pulse reads as a jump from ~150 to ~6000):

- Wine hands a Bluetooth DualSense to Windows programs raw: the Bluetooth report descriptor
  (input 78 bytes, output 547), serial `24:A6:FA:4F:5A:91`, and a parent device under
  `Enum\BTHENUM`. A Bluetooth-format output report (id 0x31 with CRC-32) written through the
  Windows HID API rumbles the pad; a USB-format one (id 0x02) is refused with error 87.
- Wine's own "report fixup" for Bluetooth DualSense (winebus.sys) only rewrites *input*
  reports for naive programs and switches itself off at the first feature or output report.
  It never helps rumble.
- Steam's controller code is SDL 3 (`SDL3.dll`). SDL decides Bluetooth or USB by asking the
  device manager for the HID device's **parent** and reading the parent's compatible ids
  (`BTHENUM…` or `USB…`). Wine's `CM_Get_Parent` answers CR_NO_SUCH_DEVNODE, so the bus stays
  unknown, SDL treats the pad as wired and sends 0x02 reports the pad ignores. Steam's log
  shows it: the SDL mapping GUID began `0300` (USB bus); it now begins `0500` (Bluetooth).

**The fix is `BusType/cfgmgr32.dll`, a shim beside `steam.exe`.** Every export passes through
to Wine's own cfgmgr32 (thunks generated from Wine's export list) except `CM_Get_Parent`,
which — when Wine has no answer — looks the HID device's id up under `Enum\USB` and then
`Enum\BTHENUM` and returns a stand-in parent whose compatible ids say which. Wine loads a
native DLL in the program's folder only with an override, so the bottle has
`HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides` `cfgmgr32 = native,builtin` — scoped to
steam.exe, so games are untouched. install.sh copies the shim and checks the override; the
shim logs to `C:\SpeechBridge\bustype.log`. Games launched by Steam get rumble through Steam
Input (Diablo IV uses the Xbox template), which is what needed fixing; a game driving the
DualSense itself over Bluetooth would still need its own Bluetooth handling.

## Starting Steam without CrossOver's window (29 Sep 2026)

`open -a CrossOver steam.exe` brings CrossOver's own window up every time, and the owner did
not want it. `tools/steam-launcher.applescript` (compiled with `osacompile -o
/Applications/Steam.app`) starts Steam with CrossOver's command-line starter instead:
`cxstart --bottle Steam --no-update --no-wait --no-gui <steam.exe>` from the applet's own
`do shell script`. Measured: with CrossOver quit, Steam and Big Picture come up in six seconds,
CrossOver's app never launches, Steam Speak reads the page. The old rule "never from a shell"
was about a shell without a window-server session (an AI's terminal); an applet has one. **Game names in the app switcher (30 Sep 2026):** CrossOver runs each Windows program through
a file named after it in `$TMPDIR/winetemp-…`; macOS names the process from that file. Most
get a hard link to CrossOver's `wineloader` stub and read as "Hades2.exe"; some — Diablo IV,
Cyberpunk 2077, programs a launcher spawns, Wine's own notepad/cmd — get a bare symlink to the
`wine` binary and read as "wine". The rule CrossOver uses is unknown, but measured: **if a stub
already exists under the exe's name, CrossOver reuses it**, and Diablo then reads
"Diablo IV.exe". `tools/name-stubs.sh` links a stub for every .exe in the Steam library; the
Steam launcher runs it after starting Steam (the folder is per boot), install.sh runs it too.
`.exe` in the name is CrossOver's; there is no lever for that.

**Names in the app switcher (earlier):** a program cxstart starts directly runs on the bare Wine
binary and the app switcher (and VoiceOver) call it "wine", as they did Steam's Big Picture
helper. A program started *by another Windows program* gets CrossOver's per-process package
and its own name. So the launcher starts Steam through the bottle's script host
(`wscript.exe C:\SpeechBridge\steam.vbs`, `tools/steam.vbs`); measured after: both `steam.exe`
and the Big Picture `steamwebhelper.exe` are packaged and named, no "wine" in the switcher,
and no console host (a `cmd /c start` did the same but left `conhost.exe` in the switcher). CrossOver's own game launchers (`~/Applications/CrossOver/Steam/*.app`, made
by cxmenu from the Start Menu) go through its "Menu Helper".

## One-shot install for other people (30 Sep 2026)

The public repository's root `install.sh` (`tools/root-install.sh` here, copied out by
`tools/publish.sh` together with `tools/get.sh`) does the whole job on a fresh Mac with only
Apple's Command Line Tools: builds the listener and Steam Speak with `swiftc` (Steam Speak's
`build-lite.sh` — no Xcode), compiles the two applets and the Setup app, runs this folder's
`install.sh`, then performs the in-bottle registrations itself with `cxstart` (regsvr32 ×4,
the ZDSR key, the cfgmgr32 override, the Ren'Py registry file). Measured: `cxstart` returns
normally from the owner's own Terminal (8 s for `cmd /c exit`); the old "never from a shell"
rule was about an AI tool's sandboxed shell. `get.sh` is the `curl | sh` line that fetches
the tarball into `~/SpeechBridge` and runs it. Not yet run end to end on this Mac — each part
was, and the full run would rebuild the owner's Steam Speak under an ad-hoc signature and
re-prompt its VoiceOver permission. Game-agnostic since the same day: the NVDA controller
stand-in also lives in system32/syswow64 under both names, so a game that asks for it
without shipping it finds it.

## Protocol

    S <utf-8 text>\n   speak (newlines in the text are folded to spaces)
    X\n                stop; the DLL also drops anything it had queued

## Known limits, to settle by ear

- VoiceOver's `output` queues; it cannot be cut off by the next line. If menus
  lag behind the cursor, the next step is Muteny posting each line as a
  high-priority accessibility announcement on a real window, which the Steam
  work measured VoiceOver honours from a non-active app. The system-voice route
  interrupts already.
- The DLL never blocks the game: a worker thread owns the socket, reconnects
  every two seconds while no listener is up, and the log keeps going regardless.

## Then

Fold the listener into Muteny (Keel's Announcer, opened when a game surface is on
screen) and let Cross on the CrossOver stub for Diablo IV be the whole launch.

## NotProton and TurnOver (October 2026)

Since 8 October 2026 the Mac side of this project lives inside **TurnOver**: it listens on port 52134, reads Big
Picture over port 8080 and Electron games over 9223, and speaks with its own voice. SpeechBridge Listener and Steam
Speak are retired (their launch agent and login item removed, the apps deleted on 9 October). What remains of
SpeechBridge is the stand-ins and the Setup app.

Games now run through **NotProton** (Steam Play in the Mac Steam client, with CrossOver 26.3 as the runner) rather
than the CrossOver bottle; each gets a Wine prefix at `steamapps/compatdata/<appid>/pfx`. Opening **SpeechBridge
Setup** (in Applications) runs `install-notproton.sh`, which for every game Steam has set to NotProton:

- makes a prefix from the template (`~/Library/Application Support/SpeechBridge/template-pfx`, a copy of the
  CrossOver bottle without its games) if the game has none yet, keeping any Steam Cloud files already there; on a
  Mac without the template, the game is started once so NotProton makes the prefix, and Setup runs again;
- puts the stand-ins into the prefix's `system32`/`syswow64` and registers them (SAPI voice, SpVoice, ZDSR for
  Prism, the Ren'Py voice command), with NotProton's own Wine (`runners/current`) and that prefix's `WINEPREFIX`;
- replaces the speech DLLs a game ships (NVDA's controller client, WindowsTTS, SAAPI64 beside Tolk) with the
  stand-ins, originals kept as `.orig`;
- sets the Wine overrides the mod loaders need (Hades II `d3d12`, Final Fantasy VI `version`, Cyberpunk 2077
  `winmm`, Fallout 4's XAudio2 set) and F4SE in Fallout 4's launcher's place;
- sets the launch options for Stardew Valley (SMAPI, as `bash -c 'exec "${@/Stardew Valley.exe/StardewModdingAPI.exe}"' -- %command%`,
  since NotProton hands the game's path to a shell) and Periphery Synthetic (port 9223), which needs Steam closed:
  if Steam is open it says so and leaves them for the next run;
- reports whether TurnOver is listening on port 52134.

It skips a game that is running and says so. The bottle installer (`install.sh`) still runs after it if a bottle
called Steam exists.

**Diablo IV under NotProton, verified 7 November 2026:** the same hook as in the bottle, and nothing else: `SAAPI64.dll`
and `SpVoiceBridge64.dll` in the prefix's `windows/system32` (never the game folder; the protection layer ends the
game two minutes after a DLL loads from there), the SAPI token registered, `UseThirdPartyReader "1"` in
`LocalPrefs.txt`. `system32/SAAPI64.log` that day: "S Kurast Docks. Waypoint", "S Bottom action button", "S Interact".
Steam's launch options for the game carry `CX_GRAPHICS_BACKEND=d3dmetal WINEMSYNC=1 %command%`.

**Diablo 4 Assist (d4-assist, by Ali-Bueno; 7 November 2026, not yet verified in play):** installed into the
prefix at `C:\D4Assist`, started by `start-d4assist.sh --wait` from the game's launch options (it must start after
the game: NotProton runs `wineserver -k` while it sets the game up). Two Wine workarounds: `--restarted`, because
under msync its zero-timeout single-instance mutex wait always fails; and `--no-speech` with `speech-relay.exe`
(mingw-built, source beside it) tailing `d4assist-log.txt` and sending `X` / `S <text>` to TurnOver's port, because
its Prism picks NVDA under Wine and stays silent. The relay must be a Wine process: TurnOver speaks for a Wine
speaker while a game is in front, not for a Mac one.
