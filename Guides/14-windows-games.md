# Windows games on your Mac

Many of the games blind people play, and the accessibility mods made for them, exist only for Windows: Diablo IV's
own screen reader, Stardew Access, the Hades II blind accessibility mods, Fallout 4 Access, Cyberpunk Access. On an
Apple silicon Mac they can run from Steam itself, through CrossOver's Wine, and TurnOver can be their voice: the
game's words, and Steam's own screens, which no Mac screen reader could read before. This guide is the steps, in
order, and then each game.

It was all worked out by one blind player with an AI in the autumn of 2026, on an M4 MacBook Air, and it works; but
it is a hobbyist's setup, not a product. Expect some Terminal, some files to put in place by hand, and, for one game,
a sighted person's help once.

## How it works, in a paragraph

A Windows game, or its mod, asks Windows for speech: a screen reader such as NVDA, or Windows' own voice. On the Mac
there is neither, so the game runs and says nothing. SpeechBridge, a small part of TurnOver, puts stand-in files
where the game looks for them. Each one takes the words and passes them to TurnOver, which asks you once whether that
game may speak through it, and then says them in your TurnOver voice. Nothing from Windows is installed, and the
stand-ins can do nothing but speak.

## What plays

| Game | How it speaks, and what to install |
|---|---|
| Diablo IV | its own screen reader; nothing to install, two settings |
| Stardew Valley | Stardew Access; SMAPI and the mod |
| Hades II | Blind Accessibility and HadesIIAccess; the mods and their loader, by hand |
| Fallout 4 | Fallout 4 Access; F4SE and four mods |
| Final Fantasy VI Pixel Remaster | FF6 Screen Reader; MelonLoader and the mod |
| Cyberpunk 2077 | Cyberpunk Access; the mod and its nine requirements |
| Bits & Bops, Rhythm Doctor, Blind Drive | the games' own speech; nothing to install |
| Slay the Princess and other Ren'Py games | self-voicing; nothing to install, press V |
| Periphery Synthetic EP | the game's own text; a launch option the setup writes |
| Any game using Windows' built-in voice | the game's own speech; nothing to install |
| Steam itself | Big Picture, read by TurnOver; one TurnOver setting |

All of these were played this way in the autumn of 2026. A game not in the list that speaks the way Windows games
usually do should work too; the last section says how to tell us.

## What you need

- A Mac with Apple silicon (M1 or later). Big games want memory and disk: Diablo IV is about 160 GB.
- **Steam for the Mac** ([store.steampowered.com/about](https://store.steampowered.com/about/)), signed in.
- **CrossOver** ([codeweavers.com/crossover](https://www.codeweavers.com/crossover)), version 26.3 or later. It costs money, with a free trial. It runs the Windows
  games; it needn't be open.
- **NotProton**, free, from [github.com/NotProtonNot/NotProton](https://github.com/NotProtonNot/NotProton). It
  turns on Steam Play in the Mac Steam client, so Windows games install and run from Steam, through CrossOver.
- **TurnOver**, build 20 or later, from [the download page](https://doll-eye.github.io/turnover-updates/).
- **SpeechBridge**, the stand-ins, a small project of its own that works with TurnOver: it goes into the games, not
  into TurnOver. Download it from [github.com/Doll-Eye/SpeechBridge](https://github.com/Doll-Eye/SpeechBridge): the green Code button, then
  Download ZIP; or, in Terminal, `git clone https://github.com/Doll-Eye/SpeechBridge.git`.
- The Windows games you own. A game bought for the Mac usually includes its Windows version; it's the Windows one
  Steam installs once NotProton is chosen.
- A controller is optional. A PlayStation DualSense works, wired or over Bluetooth.

## 1. Steam, CrossOver and NotProton

1. Install Steam from [store.steampowered.com/about](https://store.steampowered.com/about/), open it and sign in.
2. Install CrossOver into Applications. Open it once so it finishes its own setup; it needn't stay open.
3. Install NotProton from [its releases page](https://github.com/NotProtonNot/NotProton/releases) and open it. It makes its own copy of CrossOver's engine and registers itself with Steam as a
   "compatibility tool", named after the CrossOver version, such as "CrossOver 26.3". Its page says which Steam
   versions it works with.
4. In Steam, Settings, Compatibility: enable Steam Play for all titles and choose that tool as the default. Then
   every Windows-only game in your library has an Install button. (A single game can be set the same way in its
   Properties, under Compatibility.) Diablo IV and Hades II need the Rosetta flavour of the tool, which has D3DMetal,
   CrossOver's DirectX 12.

Steam's ordinary windows are web pages, and VoiceOver reads them badly; that is what kept blind players off Steam on
the Mac. TurnOver reads **Big Picture**, Steam's full-screen interface, once you let it: TurnOver's Settings (Command
Control Comma, then S), under **Other apps' speech**, turn on **Read Steam's Big Picture**, then **Restart Steam**
there. From then on, Big Picture is read as you move: the library, a game's page with Install and Play, the store,
settings. It is off to begin with because reading it makes Steam open a debugging port on your Mac while Steam runs;
the [Privacy and security](privacy-and-security.html) guide says what that means. Steam's View menu, Big Picture
Mode, switches to it; Escape and the menu switch back.

## 2. Install a game and start it once

Install the game from Big Picture, then start it once. The first start makes the game's own little Windows, its
"prefix", where the stand-ins will go. The game needn't get far; quit it when it's up (Command Q, or Command Tab to
Steam and stop it there).

## 3. SpeechBridge: one command

Open Terminal, go to the folder you downloaded, and run the setup:

```bash
cd ~/Downloads/SpeechBridge-main
```

```bash
sh install.sh
```

(If you cloned with git, the folder is called SpeechBridge instead.) One line does both, if you'd rather:
`curl -fsSL https://raw.githubusercontent.com/Doll-Eye/SpeechBridge/main/get.sh | sh` fetches SpeechBridge into a
folder called SpeechBridge in your home folder and runs the setup. It finds every game Steam runs through NotProton,
puts the speech files into each one's prefix, swaps the game's own speech files for them, allows the mod loaders, and
leaves **SpeechBridge Setup** in Applications: an app that does the same again, for after the next game installs.
Nothing else to install. It needs no Xcode and no developer tools.

Run it again, or open SpeechBridge Setup, after every game you add (once the game has been started once), after
adding a mod, and after Steam "verifies" a game's files, which puts the game's own speech files back. It says what it
changed, and skips a game that is running.

## 4. The first time a game speaks

Start the game from Steam. The first time it sends words to TurnOver, TurnOver asks: "Diablo IV wants TurnOver to
speak for it. Do you trust it?" Choose **Allow**. From then on, the game speaks in your TurnOver voice whenever it is
the app in front, and only then; it can't do anything else. You can change your answer in Settings, **Apps that speak
through TurnOver**.

With a game in front, TurnOver reads nothing of its own: the game's words are the speech. Command Control Comma still
works for TurnOver's menu and settings, and Command Tab leaves the game.

## Where the game files are

In Finder, Go to Folder (Command Shift G) takes you to any of these:

- The games: `~/Library/Application Support/Steam/steamapps/common`, one folder per game. Mods go in here, as their
  instructions say.
- A game's Windows folders (its Documents, AppData, and C drive):
  `~/Library/Application Support/Steam/steamapps/compatdata/<the game's number>/pfx/drive_c`, with Documents under
  `users/steamuser`. The number is in the game's store page address; Diablo IV is 2344520, Stardew Valley 413150.

Mods are zip files you unpack into a game's folder. Most come from [Nexus Mods](https://www.nexusmods.com) (a free
account), [Thunderstore](https://thunderstore.io) or GitHub; each game below links its own.

## Game by game

### Diablo IV

Diablo IV has its own screen reader, built in by Blizzard, and it speaks through TurnOver with no mod at all. The
one thing that made it possible: the game refuses any file loaded from its own folder, so the stand-in it needs
lives outside it, in the Windows system folder of the game's prefix, where Windows looks for such files anyway.
SpeechBridge puts it there; nothing goes in the game's folder. Three things to know:

- On the first run, the game asks whether to enable the screen reader, and nothing reads the question. Press
  **Return**; Enable is the highlighted button. This is the one place sighted help, or a guess, is needed, once.
- Then in the game's `LocalPrefs.txt` (its Documents folder, Diablo IV, see above) make sure of
  `UseScreenReader "1"` and `UseThirdPartyReader "1"`; the second is what sends the words to the stand-in.
  `SkipIntroMovie "1"` is a kindness.
- Over Bluetooth, turn **Steam Input** on for the game in Steam, with the Xbox gamepad layout; the game then sees
  the controller. Wired, it works as it is.

Needs macOS 26.4 or later and CrossOver 26.4 or later; an older one runs the game without sound or not at all. The
menus, the open world and the fights are all read.

### Stardew Valley

Install [SMAPI](https://smapi.io), the Stardew mod loader, by hand: unzip its download, and inside it `internal/windows/install.dat` is a
zip too; unpack that into the game's folder, then copy `Stardew Valley.deps.json` to `StardewModdingAPI.deps.json`
beside it. Then into the game's `Mods` folder: [**Stardew Access**](https://github.com/khanshoaib3/stardew-access), with
**Kokoro** and **Project Fluent**, which it needs (its page links them). Run the setup again with Steam closed: it writes the launch option that starts the game through SMAPI, and
swaps the speech file Stardew Access brings. Then play: "Stardew Access version 1.6.2 loaded", the title screen, the
menus.

### Hades II

Three mods from Thunderstore, unpacked by hand into the game's `Ship` folder:
[Lirin's **Blind Accessibility**](https://thunderstore.io/c/hades-ii/p/Lirin/Blind_Accessibility/) and
**Hades 2 TOLk Compatibility** (both on [Lirin's page](https://thunderstore.io/c/hades-ii/p/Lirin/)), and
[FlatArther's **HadesIIAccess**](https://thunderstore.io/c/hades-ii/p/FlatArther/HadesIIAccess/), with the loader and libraries they list as
dependencies (Hell2Modding, LuaENVY-ENVY, SGG_Modding's ENVY, Chalk, ReLoad, SJSON, ModUtil, DemonDaemon). The
loader's `d3d12.dll` goes beside `Hades2.exe`; each mod goes in `ReturnOfModding/plugins/<Team-Name>/`; HadesIIAccess's
`plugins_data` folder moves to `ReturnOfModding/plugins_data/FlatArther-HadesIIAccess/`. Run the setup again: it
tells Wine to load the mod loader for this game. The main menu is read.

### Fallout 4

[**Fallout 4 Access**](https://github.com/FalloutAccess/Fallout4Access) by alex19EP, with what it needs:
[F4SE](https://f4se.silverlock.org) (the script extender), the Address Library, Extended Dialogue Interface and Mod
Configuration Menu, the last three from Nexus. F4SE's files go in the game folder, the mods' `Data` folders
into the game's `Data`. One text file: in the game's Documents, My Games, Fallout4, `Fallout4Custom.ini` with
`[Archive]`, `bInvalidateOlderFiles=1` and `sResourceDataDirsFinal=` on three lines. Turn Steam Input on for the
game, as for Diablo IV. Then run the setup again: it writes the plugin list, puts F4SE in the launcher's place, and
fixes the sound, which is static under Wine's own audio otherwise (the sound fix needs `cabextract` from Homebrew;
the setup says so if it's missing). The main menu is read.

### Final Fantasy VI Pixel Remaster

[BlindGuyNW's **FF6 Screen Reader**](https://github.com/BlindGuyNW/FF6ScreenReader) on
[MelonLoader](https://github.com/LavaGang/MelonLoader). Unpack MelonLoader's zip into the game folder, the mod's
`FFVI_ScreenReader.dll` into `Mods`, and its `Tolk.dll` and `nvdaControllerClient64.dll` beside the game. Run the
setup again. The first launch takes several minutes while MelonLoader fetches what it needs; Steam shows an
"On-Screen Keyboard" notice the first time, which wants an OK. The opening crawl is read.

### Cyberpunk 2077

[**Cyberpunk Access**](https://www.nexusmods.com/cyberpunk2077/mods/31539) by Ludark, from Nexus, with its nine
requirements (the mod page lists them, with [Audioware](https://github.com/cyb3rpsych0s1s/audioware) from GitHub). Each unpacks over the game folder. The mods expect NVDA; they get TurnOver instead, through the same
stand-ins. Run the setup again. The user agreement and the main menu are read. After a game update the mods must
match the game's version, as on Windows.

### Games that speak on their own

- **Bits & Bops, Rhythm Doctor, Blind Drive** and other games made with the Unity Accessibility Plugin: install,
  start once, run the setup, play.
- **Slay the Princess** and other Ren'Py games: press V in the game for self-voicing.
- **Any game that uses Windows' built-in voice** (SAPI): speaks with nothing to do.
- **Periphery Synthetic EP** and other web games in an Electron shell: the setup writes the launch option that opens
  the game's debugging port, and TurnOver reads the game's page.

## Controllers

A DualSense works wired and over Bluetooth, with rumble; the Mac Steam client looks after it. Games that expect an
Xbox controller (Diablo IV, Fallout 4) need **Steam Input** turned on for the game, in Steam: the game's properties,
Controller.

## The older way: a CrossOver bottle

Before NotProton, the same games ran in a CrossOver "bottle" with Windows Steam installed inside it. That still
works, and the setup command sets it up too when it finds a bottle called Steam: it builds a **Windows Steam** app
that starts the bottle's Steam without CrossOver's window, and TurnOver reads that Steam's Big Picture as well. It
is more fiddly (CrossOver's own windows are only partly readable, and the bottle has habits of its own), so start
with NotProton unless you already have the bottle. The detail is in [SpeechBridge's README](https://github.com/Doll-Eye/SpeechBridge#readme).

## With VoiceOver instead of TurnOver

The games can speak through VoiceOver too, with the small listener app in SpeechBridge's `listener` folder, built
with Apple's command line tools. But Steam itself stays unreadable that way, and you'd install games with sighted
help; TurnOver is the way Steam gets read. TurnOver and the listener can't both run.

## When nothing speaks

- **Is the game in front?** A game is heard only while it is the app in front. Command Tab to it.
- **Did TurnOver ask?** The question comes the first time the game speaks while in front. If you chose Not now, it
  asks again; if Don't allow, change it in Settings, Apps that speak through TurnOver.
- **Did you run the setup after installing the game, and after starting it once?** And after Steam verified its
  files? Open SpeechBridge Setup; it says what it did, and whether TurnOver is listening.
- **Was the game running when you ran the setup?** It skips a running game. Quit the game and run it again.
- **The game's own screen reader setting.** Diablo IV: Options, Accessibility, Screen Reader on and Third-party
  screen reader on. Ren'Py: V. Mods: their own settings.
- **An old SpeechBridge Listener.** If you used SpeechBridge before TurnOver, its listener holds the port TurnOver
  needs. Running the setup command retires it.
- **TurnOver's log** (the TurnOver menu, Tools, Open the log folder) has a line, "speech port", for every word a game
  sends, so you can see whether the words arrive. The game's own logs are in its folder.

## The detail

Everything above, with what was measured and why each step is the way it is, is in SpeechBridge's own repository:
[github.com/Doll-Eye/SpeechBridge](https://github.com/Doll-Eye/SpeechBridge), its README and the engineering notes beside it. TurnOver's side, the
speech port that listens and the Steam reading, is in TurnOver's code. If a game not listed here speaks through one of the usual Windows ways (SAPI, Tolk,
NVDA's controller client, Prism, the Unity plugin, Ren'Py), it should simply work; tell us either way, on the
[issue form](https://github.com/TurnOver-For-Mac/turnover/issues/new/choose).
