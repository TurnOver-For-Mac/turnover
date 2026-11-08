# SpeechBridge: Windows games speaking through TurnOver

Windows games run on an Apple-silicon Mac through Wine (CrossOver's), and their speech, and the speech of the
Windows accessibility mods made for them, is caught by small stand-in Windows DLLs and sent to TurnOver, which says it
in its own voice. Steam's Big Picture, which no Mac screen reader could read, TurnOver reads itself.

This folder is the Windows side of that: the stand-in DLLs with their sources, the installers that put them in place,
a Setup app, and the notes. The Mac side is TurnOver (`Sources/Core/Speech/SpeechPort.swift` and
`Sources/Apps/Games`). It began as a separate project in September 2026 (github.com/Doll-Eye/SpeechBridge, where its
own listener spoke through VoiceOver and a second app read Big Picture); TurnOver took both jobs in October 2026 and
the Windows side moved here in November 2026, so that TurnOver's repository holds the whole of what a blind player
needs.

Two readers: a blind Mac user who wants to play should read the guide, **Windows games on your Mac**
([Guides/14-windows-games.md](../Guides/14-windows-games.md)), which has the steps in order and each game's mods. An
engineer or AI picking the problem up should read this file and then [NOTES.md](NOTES.md), the engineering log: what
was measured, what failed and why, with dates.

## Quick start

You need an Apple-silicon Mac, TurnOver, Steam for the Mac, [CrossOver](https://www.codeweavers.com/crossover) 26.3
or later, and [NotProton](https://github.com/NotProtonNot/NotProton), which switches Steam Play on in the Mac Steam
client so Windows games install and run from it, through CrossOver's Wine. Install a Windows game, start it once, then,
in Terminal:

```bash
git clone https://github.com/TurnOver-For-Mac/turnover.git
sh turnover/SpeechBridge/setup.sh
```

That puts the stand-ins into every NotProton game's Wine prefix and registers them there, swaps the speech files the
games ship, allows the mod loaders the accessibility mods ride on, writes the launch options two games need, and
builds **SpeechBridge Setup** in Applications, the same installer as an app to open after the next game installs. Run
the same line again any time: after a game installs and has been started once, after a Steam "verify integrity",
after a new mod. If a CrossOver bottle called Steam with Windows Steam in it exists as well (the way of September
2026), it is set up too.

**It is game-agnostic.** Nothing here is written for one game: the stand-ins answer the speech interfaces games and
their mods use (Microsoft SAPI, Tolk, NVDA's controller client, Prism, the UAP `WindowsTTS` plugin, Ren'Py's
external voice), so anything that talks to one of those talks through TurnOver. What is per game is only whether the
game ships its own copy of such a DLL (the installer swaps those), whether its mod loader needs a Wine override (the
installer sets those), and the mods themselves, which the sections below cover for the games tried so far.

## What plays today

| Game | Speech route | Notes |
|---|---|---|
| Diablo IV | its own screen reader, Tolk, SAAPI64 stand-in | the big one; see its section, it has rules |
| Hades II | Blind Accessibility and HadesIIAccess mods, Tolk, SAAPI64 | mods installed by hand |
| Fallout 4 | Fallout 4 Access (F4SE), Prism, ZDSR stand-in | F4SE, Address Library, XDI, MCM |
| Stardew Valley | Stardew Access via SMAPI, Tolk, SAAPI64 | launch option points at SMAPI |
| Final Fantasy VI Pixel Remaster | FF6 Screen Reader mod via MelonLoader, Tolk, SAAPI64 | MelonLoader installs .NET 6 itself on first run |
| Cyberpunk 2077 | Cyberpunk Access via RED4ext, Cyber TTS Engine (Prism), ZDSR stand-in | nine prerequisites; Windows build, not the native Mac one |
| Bits & Bops, Rhythm Doctor, Blind Drive | UAP plugin, NVDA and WindowsTTS stand-ins | run the installer after installing |
| Slay the Princess (and any Ren'Py game) | Ren'Py self-voicing, `sbsay.exe` | one registry value |
| Periphery Synthetic EP (Electron) | aria-live regions, TurnOver's web reader | launch option opens a debugging port |
| Steam Big Picture | Chromium debugging port, TurnOver | the Mac client's, and a bottle's |
| Any game that uses Windows' built-in voice (SAPI) | SapiBridge engine and SpVoice stand-in | nothing per game |

Not working: SEQUENCE STORM (needs an OpenGL 3.3 compatibility context, which macOS does not have; not a speech
problem). Untested: anything not in the table. Everything was first verified in September 2026 in a CrossOver bottle
on an M4 MacBook Air with 24 GB, macOS 27, CrossOver 26.3; the games moved to NotProton on 8 and 9 October 2026 with
the same stand-ins in each game's prefix, and Diablo IV was heard that way on 7 November 2026.

A DualSense works wired and over Bluetooth. Under NotProton the Mac Steam client handles the controller; in a bottle,
rumble over Bluetooth needed a fix of its own (below).

## How it works, in one paragraph

A Windows game asks a speech API to talk: a screen reader through Tolk, NVDA's controller client, the UAP
`WindowsTTS.dll`, Microsoft SAPI, the Prism library, Ren'Py's external TTS command. SpeechBridge puts a **stand-in
DLL** where each of those is looked for. Each stand-in does nothing but send the text as one line, `S <text>`, to
`127.0.0.1:52134` (`X` to stop). Wine shares the Mac's loopback, so TurnOver's speech port hears it. TurnOver works
out which program is on the other end from the Mac's own record of processes, asks you once whether that program may
speak through it, and from then on says its lines in TurnOver's voice while the game is the app in front. No screen
reader for Windows is installed, and nothing in the game needs one.

## What you need

- A Mac with Apple silicon. Tested on an M4 MacBook Air with 24 GB; Diablo IV wants that much memory and a lot of
  disk (about 160 GB with expansions).
- **TurnOver**, build 20 or later (the speech port). TurnOver's own guide covers installing it.
- **Steam for the Mac**, signed in.
- **CrossOver 26.3** or later (paid, with a trial), installed in Applications. Its "D3DMetal" graphics backend is what
  runs DirectX 12 games such as Diablo IV and Hades II. NotProton uses CrossOver's Wine; it doesn't replace it.
- **NotProton** ([github.com/NotProtonNot/NotProton](https://github.com/NotProtonNot/NotProton); GPL-3.0; a brew
  cask, `brew install --cask notprotonnot/notproton/notproton`, or its releases page). It turns Steam Play on in the
  Mac Steam client, so a game's Windows build can be installed and run; each game gets its own Wine prefix at
  `~/Library/Application Support/Steam/steamapps/compatdata/<appid>/pfx`. Its README names the Steam client builds it
  supports. Choose it as the compatibility tool in Steam's Settings, Compatibility (for everything), or in a game's
  Properties, Compatibility (for one game); it is listed by its CrossOver version, "CrossOver 26.3" here. The Rosetta
  flavour has D3DMetal; the FEX flavour does not.
- The Windows games you own. A game bought for the Mac usually includes its Windows build; it's the Windows one Steam
  installs once the compatibility tool is set.
- To rebuild the DLLs (optional; prebuilt copies are here): Homebrew and `mingw-w64` (`brew install mingw-w64`).
  Each folder's `build.sh` builds its DLL.

## Install, with NotProton

### 1. Steam, CrossOver and NotProton

Install Steam for the Mac and sign in. Install CrossOver into Applications (it needn't be running). Install NotProton
and open it once: it sets up its copy of CrossOver's runner under `~/Library/Application Support/notproton/runners`
and registers itself with Steam as a compatibility tool. In Steam's Settings, Compatibility, make it the default tool,
so Windows-only games can be installed; or set it per game in the game's Properties, Compatibility.

Steam's own windows are web pages that VoiceOver reads badly, which is what kept blind players off Steam on the Mac.
TurnOver reads Big Picture, Steam's full-screen interface, once you let it: TurnOver's Settings, Other apps' speech,
Read Steam's Big Picture, then Restart Steam there. It writes an empty `.cef-enable-remote-debugging` file into
Steam's folder, which makes Steam expose its Chromium debugging port on `localhost:8080`, and reads whichever Big
Picture is there. Steam updates delete that file; TurnOver tells you and offers the restart again. It is off to begin
with because the port is open to every program on the same Mac while Steam runs.

### 2. TurnOver speaks

Nothing to build: TurnOver's speech port listens on `127.0.0.1:52134` whenever TurnOver runs. The first time a game
sends a line while it is the app in front, TurnOver asks "<the game> wants TurnOver to speak for it. Do you trust
it?" with Allow, Don't allow and Not now; the answer is kept and can be changed in Settings, Apps that speak through
TurnOver. An allowed game is heard only while it is in front; it can do nothing but speak and stop speaking. A Wine
game counts as in front while any game is, because CrossOver's processes come and go.

Every line is logged in TurnOver's log (`~/Library/Application Support/TurnOver/logs`) as "speech port (<game>)",
with the words only when "keep what was read" is on, which is how you check a silent game without ears. The stand-ins
each log beside themselves too (`SAAPI64.log`, `SpVoiceBridge.log` and so on in the prefix's `windows/system32`, and
beside a game's own Tolk).

If TurnOver's log says the speech port could not listen and asks "Is the old SpeechBridge Listener still running?",
it is: the listener of September 2026 held the same port. setup.sh retires it when TurnOver is installed.

### 3. The stand-ins, into each game's prefix

Install a game and start it once (NotProton makes its prefix on the first start; the game needn't get far). Then
`sh SpeechBridge/setup.sh`, or open **SpeechBridge Setup** in Applications once setup.sh has built it. For every game
Steam has set to NotProton, `install-notproton.sh`:

- puts the SAPI engine, the SpVoice stand-in, SAAPI64, NVDA's controller client and the ZDSR client into the prefix's
  `windows/system32` (and 32-bit copies into `syswow64`), and `sbsay.exe` with the Ren'Py registry file into
  `C:\SpeechBridge`;
- registers them inside the prefix with NotProton's own Wine (SAPI voice and SpVoice over `regsvr32`, the ZDSR key,
  the Ren'Py environment variable), then stops that prefix's Wine server; a game that is running is skipped and said;
- replaces `nvdaControllerClient*.dll`, `WindowsTTS.dll` and a `SAAPI64.dll` beside the game's own `Tolk.dll` with the
  stand-ins, keeping the originals as `.orig`, and removes any SAAPI64 from Diablo IV's folder;
- sets the Wine override each mod loader needs, when the loader's DLL is there: Hades II (`d3d12`), Final Fantasy VI
  (`version`), Cyberpunk 2077 (`winmm`), and Fallout 4's four XAudio2 DLLs as `native`, with Microsoft's copies put in
  place and F4SE in the launcher's place;
- writes the launch options for Stardew Valley (SMAPI) and Periphery Synthetic (port 9223) when Steam is closed, and
  says so when it isn't (it edits `userdata/<id>/config/localconfig.vdf`, which Steam re-reads on start);
- reports whether TurnOver is listening on the port.

It only copies files and runs `reg`/`regsvr32` in the prefix, so it is safe to repeat, and a Steam "verify integrity",
which puts a game's original speech files back, is undone by running it again. There is no uninstall: delete
`compatdata/<appid>` and Steam makes a fresh prefix, and the `.orig` files beside the game are its originals.

### Install, with a CrossOver bottle (the way of September 2026)

Windows Steam in a CrossOver bottle still works, and setup.sh sets it up when a bottle called Steam (or the name
passed) exists. Make the bottle Windows 10, turn on **MSync** and **D3DMetal** in its settings (DXMT lacks Direct3D
12 and Diablo IV cannot create a device on it), and install Steam into it with CrossOver's installer; sign in with
"remember me". CrossOver's own interface is only partly readable, which is one reason NotProton won. The pieces
particular to the bottle:

- `install.sh` puts the stand-ins into the bottle's `system32`/`syswow64` and `C:\SpeechBridge`, swaps the games' own
  speech files, puts F4SE in Fallout 4's launcher's place, extracts Microsoft's XAudio2 with `cabextract`, and installs
  the Bluetooth-rumble shim beside `steam.exe`. `install.sh --uninstall` puts every `.orig` back.
- setup.sh then does the registrations inside the bottle with CrossOver's `cxstart` (SAPI voice and SpVoice over
  `regsvr32`, the ZDSR key, the `cfgmgr32` override for Steam, the Ren'Py registry file) and the per-game overrides.
- **Windows Steam** in Applications (`tools/steam-launcher.applescript`) starts the bottle's Steam with `cxstart
  --bottle Steam --no-update --no-wait --no-gui wscript.exe C:\SpeechBridge\steam.vbs`, so CrossOver's own window
  never opens. Going through the script host matters: a program started by another Windows program gets CrossOver's
  per-process package and its own name in the app switcher, where one started directly is just "wine". The launcher
  then runs `tools/name-stubs.sh`, which does the same for every game in the library.
- **A rule that cost an afternoon:** never start anything in the bottle from a terminal that an AI runs, or from a
  login shell without a window server session. With MSync on, the bottle's server is started under that shell's
  namespace, later launches attach to it, TLS fails, no window appears and Steam dies after three minutes with
  "fatal stalled cross-thread pipe". Your own Terminal is fine (measured 30 September 2026), and so is an applet:
  `tools/run-in-bottle.applescript`, which setup.sh compiles, runs the command written in a file called `cmd`. If the
  bottle is wedged: `pkill -9` every `.exe`, `winetemp-` and `bin/wineserver`, then relaunch with `open`.
- Big Picture in the bottle is read by TurnOver like the Mac client's; "Read Steam's Big Picture" writes the
  debugging-port file into every bottle holding a `steam.exe` too.

The registrations, for checking or doing by hand inside the bottle (with the applet, or CrossOver's Run Command):

```
regsvr32 C:\windows\system32\SapiBridge64.dll
C:\windows\syswow64\regsvr32 C:\windows\syswow64\SapiBridge32.dll
regsvr32 C:\windows\system32\SpVoiceBridge64.dll
C:\windows\syswow64\regsvr32 C:\windows\syswow64\SpVoiceBridge32.dll
reg add HKLM\SOFTWARE\WOW6432Node\zhiduo\zdsr /v Path /t REG_SZ /d C:\SpeechBridge /f
reg add HKCU\Software\Wine\AppDefaults\steam.exe\DllOverrides /v cfgmgr32 /t REG_SZ /d native,builtin /f
reg import C:\SpeechBridge\renpy.reg
```

The SAPI engine registers itself as the default voice with two tokens, one with Language exactly `409` (Diablo IV
insists) and one `809`. Wine reads the default voice from `DefaultDefaultTokenId`, which a fresh prefix does not
have; the registration writes it.

### Without TurnOver: VoiceOver and the listener

`listener/` is the Mac app of September 2026 that speaks the same lines through VoiceOver (or the system voice).
`listener/build.sh` builds it (Apple's Command Line Tools needed), `listener/login-item.sh install` keeps it running.
The games then speak, but Steam itself does not: Big Picture needs TurnOver (or Steam Speak, retired, in the old
repository). It is kept for anyone who wants the games with VoiceOver alone; it and TurnOver can't both hold the
port.

## Game by game

The mods go where their own instructions say, inside the game's folder under
`~/Library/Application Support/Steam/steamapps/common` (NotProton) or the bottle's `steamapps/common`. A game's
Windows user folders (Documents, AppData) are in its prefix at `drive_c/users/steamuser`; in a bottle, Documents is
the Mac's own Documents folder.

### Diablo IV

Diablo IV has its own screen reader; it wants a SAPI voice and, with "third party reader" on, speaks through Tolk.
What it took, in order:

1. In the game's `LocalPrefs.txt` (Documents, Diablo IV): `UseScreenReader "1"`, `UseThirdPartyReader "1"`, and
   `SkipIntroMovie "1"`, `PlayInBackground "1"`, `LimitBackgroundFPS "0"`, `DisplayModeWindowMode "1"` for comfort.
   The game writes the file on its first start.
2. The first run shows a "Screen Reader Enable / Disable" prompt that nothing reads. Press Return; Enable is
   highlighted.
3. **The hook lives outside the game folder. Every DLL the game loads must be in `C:\windows\system32` or
   `syswow64`.** The game's protection layer (`diablo_iv_loader.dll`) ends the process about 123 seconds after any DLL
   is loaded from anywhere else, with nothing in the game's log. Ten crashes were spent on that. So `SAAPI64.dll`
   (what Tolk's System Access driver loads) and the SpVoice stand-in sit in the prefix's `system32`, where Windows'
   normal DLL search finds them, and nothing of SpeechBridge goes in the game folder; the installer removes an old
   copy if it finds one. That is "putting a hook outside the main game folder", and it is why Diablo IV speaks at all.
4. Wine's own SpVoice cannot render into the stream the game supplies and fails every Speak; the SpVoice stand-in
   replaces the class (CLSID `{96749377-…}`) and forwards the text.
5. The game's reader initialises SAPI before it will touch Tolk, and wants a voice whose Language is exactly `409`;
   the SAPI engine registers one.
6. Over Bluetooth, the game's native DualSense support fails under Wine. Turn **Steam Input** on for the game with the
   Xbox "Gamepad" template; the game then sees an XInput pad.

Under NotProton the game's launch options carry `CX_GRAPHICS_BACKEND=d3dmetal WINEMSYNC=1 %command%` on the author's
Mac (newer NotProton versions offer D3DMetal and such as compatibility options instead). The game's own log is
`FenrisDebug.txt` in the game folder (`[ScreenReader]` lines). Needs macOS 26.4 or later under CrossOver 26.4 or
later: the Season 12 update broke the game under older ones. Verified under NotProton on 7 November 2026: the
waypoint list and the action bar read ("Kurast Docks. Waypoint", "Bottom action button", "Interact").

**Diablo 4 Assist** (Ali-Bueno's memory-reading aid, github.com/Ali-Bueno/d4-assist) runs in the same prefix from the
game's launch options, with two Wine workarounds and a small relay (`speech-relay.exe`) that sends its lines to
TurnOver because its Prism stays silent under Wine; NOTES.md has it. Not yet verified in play.

### Hades II

Three Thunderstore mods, installed by hand because r2modman does not run here: Lirin's **Blind Accessibility** and
**Hades 2 TOLk Compatibility**, FlatArther's **HadesIIAccess**, plus their dependencies (Hell2Modding, LuaENVY-ENVY,
SGG_Modding's ENVY, Chalk, ReLoad, SJSON, ModUtil, DemonDaemon). Layout, all inside the game's `Ship` folder:

- Hell2Modding's `d3d12.dll` beside `Hades2.exe`;
- each package unpacked into `ReturnOfModding/plugins/<Team-Name>/`;
- HadesIIAccess's `plugins_data` folder moved to `ReturnOfModding/plugins_data/FlatArther-HadesIIAccess/`.

Wine loads a DLL from a program's folder only when told to, so the installer sets, for the prefix:
`reg add HKCU\Software\Wine\AppDefaults\Hades2.exe\DllOverrides /v d3d12 /t REG_SZ /d native,builtin /f`.
The loader finds the real d3d12 by path, so D3DMetal is untouched. Hell2Modding has Tolk built in and picks the
SAAPI64 stand-in on its own. To play unmodded, rename `d3d12.dll`.

### Fallout 4

Game version 1.11.240 needs **F4SE 0.7.9**; also **Address Library for F4SE Plugins** (only `version-1-11-240-0.bin`
is needed), **Extended Dialogue Interface**, **Mod Configuration Menu** and **Fallout 4 Access** by alex19EP. All
are Nexus downloads, which need a Nexus account. Put F4SE's loader, DLL and `Data\Scripts` in the game folder and the
mods' `Data` contents in `Data`. Then:

- `Documents\My Games\Fallout4\Fallout4Custom.ini` with `[Archive]`, `bInvalidateOlderFiles=1`,
  `sResourceDataDirsFinal=` (empty), so loose files load;
- `AppData\Local\Fallout4\plugins.txt` with `*XDI.esm` and `*fallout4access.esp` (the NotProton installer writes
  it when missing);
- sound: Wine's own XAudio2 gives static in this game. Microsoft's XAudio2 2.7, XAPOFX 1.5, XACT 3.7 and X3DAudio
  1.7 come from the DirectX June 2010 cabinets Steam ships (under `Steamworks Shared/_CommonRedist/DirectX/Jun2010`);
  the installer unpacks them with `cabextract` (Homebrew) into `system32`/`syswow64` and gives `Fallout4.exe` `native`
  overrides for `xaudio2_7`, `x3daudio1_7`, `xapofx1_5`, `xactengine3_7`;
- controller: force Steam Input on for the game (Big Picture, or `UseSteamControllerConfig "2"` under the top-level
  `apps` block of `localconfig.vdf`), as for Diablo IV;
- no Steam launch option: F4SE 0.7.9 refuses the launcher path Steam appends through `%command%` ("too many free
  args"), so the installer copies `f4se_loader.exe` over `Fallout4Launcher.exe` (keeping the original as `.orig`) and
  re-applies that after a Steam verify.

Fallout 4 Access speaks through the **Prism** library, which tries screen readers first. Under Wine every route it
prefers is closed (NVDA over RPC, JAWS over COM, OneCore missing, SAPI probed on a thread without COM). Its ZDSR
backend needs only a registry key and a client DLL, so SpeechBridge provides `ZDSRAPI_x64.dll`; the mod logs
`Prism initialized, speaking through ZDSR`. Anything else built on Prism will take the same door.

### Final Fantasy VI Pixel Remaster

BlindGuyNW's **FF6 Screen Reader** (GitHub, v2.0) on **MelonLoader 0.7.3**. Unpack `MelonLoader.x64.zip` into the game
folder (`version.dll` and `MelonLoader/`), the mod's `FFVI_ScreenReader.dll` into `Mods`, and its `Tolk.dll` and
`nvdaControllerClient64.dll` beside the game (then run the installer, which swaps in the stand-in and sets the
override: `reg add "HKCU\Software\Wine\AppDefaults\FINAL FANTASY VI.exe\DllOverrides" /v version /t REG_SZ /d native,builtin /f`).
The first launch takes several minutes: MelonLoader downloads and installs the .NET 6 runtime in the prefix and
generates the game's assemblies, all on its own. Steam's first launch of a controller game shows an "On-Screen
Keyboard" notice that wants an OK. The same recipe should serve the other Pixel Remasters and their mods by
bladestorm360.

### Cyberpunk 2077

**Cyberpunk Access** by Ludark (Nexus) with its requirements: Cyber TTS Engine, RED4ext, redscript, Codeware, TweakXL,
ArchiveXL, Input Loader, Mod Settings (all Nexus) and Audioware 1.9.4 from GitHub (the version the mod names). Each
unpacks over the game folder; Cyberpunk Access's archive has a top folder whose contents go in the game root. RED4ext
loads through `bin\x64\winmm.dll`, so the installer sets
`reg add HKCU\Software\Wine\AppDefaults\Cyberpunk2077.exe\DllOverrides /v winmm /t REG_SZ /d native,builtin /f`.
Cyber TTS Engine speaks through Prism, so the ZDSR stand-in from the Fallout 4 section carries it: the mods want
NVDA, and get TurnOver. Launch from Steam; the game's user agreement is read aloud with Decline and Accept. This
needs the Windows build of the game, which the compatibility tool makes Steam install; the native macOS version
cannot load these mods. After a game update every RED4ext plugin must match the game's patch: check `red4ext\logs`
and `r6\logs\redscript_rCURRENT.log` for "Compilation complete".

### Stardew Valley

Install SMAPI by hand (unzip its `install.dat` into the game folder, copy `Stardew Valley.deps.json` to
`StardewModdingAPI.deps.json`), then the **Stardew Access** mod and its dependencies (Project Fluent, Kokoro) into
`Mods`. Stardew Access ships its own `SAAPI64.dll`; the installer replaces that one with the stand-in. The launch
option, which the NotProton installer writes: `bash -c 'exec "${@/Stardew Valley.exe/StardewModdingAPI.exe}"' -- %command%`
(NotProton hands the game's path to a shell, so the swap is done there); in a bottle it is
`"C:\Program Files (x86)\Steam\steamapps\common\Stardew Valley\StardewModdingAPI.exe" %command%`.

### Bits & Bops, Rhythm Doctor, Blind Drive and other UAP games

These ship `nvdaControllerClient.dll` and `WindowsTTS.dll` in `<game>_Data\Plugins\x86_64`. The installer replaces
both; the WinRT `WindowsTTS.dll` crashes under Wine, the stand-in does not. Nothing else to do.

### Ren'Py games (Slay the Princess)

Ren'Py's self-voicing runs an external command when set. The registration adds
`RENPY_TTS_COMMAND=C:\SpeechBridge\sbsay.exe` to the prefix's environment. Turn self-voicing on in the game with `v`.

### Electron games that use aria-live (Periphery Synthetic EP)

TurnOver's Steam program has a web reader on port 9223: it attaches to a Chromium page, watches `aria-live` regions
and focus, and speaks the changes. Launch option, which the NotProton installer writes: `%command% --remote-debugging-port=9223`.

### Steam launch options without the Steam window

Launch options live in `userdata/<your id>/config/localconfig.vdf`, under `Software\Valve\Steam\apps\<app id>`, as
`"LaunchOptions"`, editable with Steam closed (quotes as `\"`, backslashes doubled). Steam re-reads the file on
start. The NotProton installer edits that file itself.

### Rumble over Bluetooth, in a bottle

Over Bluetooth a DualSense rumbled in nothing until this was found: Steam's controller code (SDL 3) asks Windows'
device manager for the pad's parent device to learn its bus, and Wine's `CM_Get_Parent` has no answer, so every pad
counts as wired and gets USB-format reports the pad ignores. `BusType/cfgmgr32.dll` sits beside the bottle's
`steam.exe`, passes every call through to Wine's cfgmgr32 and answers that one from the registry. The override
registered above makes Wine load it. Steam's controller log then shows the mapping GUID starting `0500` (Bluetooth)
instead of `0300`. Under NotProton the Mac Steam client talks to the controller, so none of this applies.

## Traps, briefly

Each is told in full in [NOTES.md](NOTES.md); here is the list to check against.

- **Diablo IV kills itself two minutes after a foreign DLL loads.** system32 only.
- **A SAPI voice token's Language must be exactly `409`** for Diablo IV; `809;409` fails as "no voice".
- **Wine loads its own DLL over a native one in the program folder** unless an override says `native,builtin`. This
  is true of proxies (`d3d12.dll` loaders) and shims alike.
- **A running game holds its prefix:** registrations and overrides wait until it is closed; the installer says so.
- **Launching a bottle from an AI's shell** poisons the bottle for the session (above).
- **`cscript` SAPI tests hang** in `GetVoices` under Wine; use a compiled test.
- **Wine's DualSense "report fixup" is input-only** and switches itself off at the first feature report; it never
  helps rumble.
- **Chrome's download manager stalls on large files while Steam is downloading**; a page can fetch the file itself
  and save it through a button clicked as a real click (a script-started save is blocked as an automatic download).
- **Two listeners on one port**: the old SpeechBridge Listener and TurnOver can't both hold 52134. setup.sh retires
  the listener when TurnOver is installed.
- **The Setup app must carry its own copy of everything**; an applet that reads from `~/Desktop` blocks on a privacy
  prompt no one sees.

## For AIs and engineers

[NOTES.md](NOTES.md) is the primary source: it records what was measured, what failed and why, with dates, for
everything on the Windows side. For Big Picture and the Mac side, TurnOver's own `Sources/Apps/Games` and
`Helpers/steam-speech`. Working rules that held up:

- **Instrument before reasoning.** Every stand-in logs beside itself; TurnOver logs every line it speaks;
  `cxstart --debugmsg +hid --cx-log <file> '<exe>'` from the applet gives a Wine trace of one program in a bottle;
  `screencapture -x` from a shell shows the game when computer-use tools cannot target Wine windows.
- **Test the interface, not the game.** `SapiBridge/sapitest.c`, `Tolk/tolktest.c`, `tools/prism/prismtest.c` and
  `tools/rumble/hidrumble.c` each replay exactly the calls a game or library makes, so a failure is placed in one
  layer.
- **Measure the hardware.** `tools/rumble/motion.swift` reads the pad's own gyro from the Mac, so a rumble pulse is a
  number, not a feeling.
- **Read the source when it is open.** Prism, SDL, Wine, Hell2Modding and hidapi are all on GitHub; the SDL bus check
  and Prism's SAPI probe were both settled by reading, not guessing.
- **Keep the owner in the loop only where only they can act:** ears, a Nexus login, a controller in the hand.
  Everything else, verify from the log.

## Credits

Tolk (Davy Kager), NVDA and its controller client, Prism (Ethin Probst), Hell2Modding, ReturnOfModding, Lirin and
erumi321 (Hades II Blind Accessibility), FlatArther (HadesIIAccess), F4SE, alex19EP (Fallout 4 Access), Stardew
Access, SMAPI, Ali-Bueno (Diablo 4 Assist), NotProton, Wine and CodeWeavers' CrossOver, AWDLControl, and Blizzard for
shipping a screen reader in Diablo IV. The stand-ins reproduce interfaces only; see [THIRD-PARTY.md](THIRD-PARTY.md).

This folder is MIT licensed ([LICENSE](LICENSE)); TurnOver around it is GPL-3.0-or-later. Built by Oliver Kennett
with Claude, September to November 2026.
