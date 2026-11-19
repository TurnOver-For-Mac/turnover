# Keyboard styles everywhere: the plan (19 Oct 2026)

The aim (19 Oct 2026): system-wide keyboard compatibility, whether TurnOver or VoiceOver is reading, for four styles:
VoiceOver, NVDA, Narrator and JAWS. Each Windows reader's commands are mapped to what TurnOver and VoiceOver can
already do; the gaps are listed; the Mac-versus-Windows design choices are made explicit.

## The research (all in reference/)

- `windows-docs/narrator-commands.md`: Narrator, Windows 11, Standard and Legacy layouts, from Microsoft's pages.
- `windows-docs/jaws-keystrokes.md`: JAWS 2025/2026, desktop and laptop layouts, from Freedom Scientific's pages.
- `nvda-docs/keyCommands.html`: NVDA 2026.2 (1 Oct); `apple-docs/voiceover-commands.md`: VoiceOver (7 Oct, to refresh).
- `keyboard-styles/turnover-commands.md`: every TurnOver command and its keys, from the code.
- `keyboard-styles/style-mapping.md`: each style's commands against TurnOver and VoiceOver, with a status per
  command (HAVE, MAP, BUILD, MAC-N/A, CLASH). The counts and the ranked gaps are summarised below once it is written.

## The mapping, in numbers (style-mapping.md; a next/previous pair counts once; from reading, no keys pressed)

| Style | Commands | HAVE | MAP (key only) | BUILD | Mac N/A | CLASH |
|---|---|---|---|---|---|---|
| NVDA | 183 | 126 | 15 | 32 | 3 | 7 |
| Narrator | 162 | 50 | 73 | 22 | 1 | 16 |
| JAWS | 408 | 78 | 161 | 124 | 8 | 37 |
| VoiceOver (Mac style) | 104 | 96 | 3 | 5 | n/a | n/a |

- **NVDA**: nearly there. To build: review modes (screen review), table headers set by hand, progress
  bar beeps, maths.
- **Narrator**: mostly a key table; TurnOver already does nearly all of it on other keys. To build: read from the top,
  verbosity levels, speech recap, mouse mode.
- **JAWS**: the biggest table and the most to build: say from line start / to line end, say all control (rewind,
  fast forward, speed), speech history, a pronunciation dictionary, PlaceMarkers, the extra web quick keys, JAWS's
  own Word and Excel keys.
- **VoiceOver**: only the caption and braille panels, two Safari searches, two keypad keys and the tutorial.

## The clashes, with the rule "the Mac's shortcut wins" applied

1. **Alt is Command, not Option** (as decided for NVDA keys on 12 Oct): Alt on Option would make every Ctrl+Alt
   chord Control+Option, VoiceOver's own key. JAWS's laptop table keys (Alt+Shift+letter) follow: Command+Shift.
2. **The Windows key**: Windy's Option family (Option+E Finder, Option+L lock, Option+D desktop…) for the system keys,
   since Windy is folded in; Command+E, R, Tab and arrows stay the Mac's.
3. **Mac editing and system keys win**: Option+Up/Down, Option+Forward Delete, Control+Up/Down (Mission Control),
   Command+Comma (Settings) and Command+Period (Cancel); the styles' commands on them get second keys.
4. **App menu shortcuts win** (Command+Control+N, J, K in Apple apps): the style's command moves to its second key in
   those apps.
5. **Caps+Space is per style**: browse/scan mode on and off in NVDA and Narrator keys; JAWS keys' layered commands
   (Insert+Space) in JAWS keys.


- **Two styles, one switch.** Mac (VoiceOver's keys) and Windows (NVDA's keys), a single setting read in 72 places
  in 20 files. Mac style: about 231 commands of its own; Windows style: about 139; about 272 shared.
- **Only in TurnOver's apps.** Where VoiceOver reads, every key goes to VoiceOver untouched, whatever the style;
  only Command Control Comma and Command Control Period reach TurnOver there.
- **Windy already does NVDA keys over VoiceOver** (separate project, 17-18 Oct): a tap at the head of the HID level,
  Caps Lock as the NVDA key, each NVDA command with a VoiceOver twin sent as VoiceOver's chord, modifier by modifier
  (VoiceOver ignores chords posted with flags alone). About 25 NVDA commands have no VoiceOver twin.
- **The shelved Windows layer** (WindowsKeys.swift, 6 Oct) only remapped editing and system keys, and was never
  shown to work under VoiceOver.

## The design

1. **A style is one of four, not a yes/no.** `KeyboardStyle`: voiceOver, nvda, narrator, jaws, each with a family
   (Mac or Windows). The 72 existing checks ask the family, so behaviour that is "Windows" today (role before the
   words, the cursor not moving the focus, flat review) stays shared by NVDA, Narrator and JAWS. Today's Windows
   style becomes NVDA; nobody's setting changes.
2. **Keymaps are data.** One table per style: key → TurnOver command name. Narrator and JAWS reuse NVDA's commands
   wherever the function is the same, so most of their work is the table, not new code. Users' own keys sit on top,
   per style, as now.
3. **One reader of keys for everywhere.** TurnOver's own HID-head tap (it already claims VoiceOver's chords) does both
   jobs: where TurnOver reads, the style's key runs TurnOver's command; where VoiceOver reads, the same key is turned
   into VoiceOver's own command, posted modifier by modifier (Windy's way), with the Windows editing and system keys
   (Control C to Command C, Home and End, the lone Windows and Applications keys) done there too. A command with no
   VoiceOver twin is either done by TurnOver itself (it can read the focused element and speak through VoiceOver's
   voice with AppleScript `output`), or said plainly: "not available where VoiceOver reads".
4. **"VoiceOver everywhere, Windows keys"**: the reading mode VoiceOver everywhere (Command Control Comma, A) plus a
   Windows-family style gives exactly the case asked for: VoiceOver reads every app, the person keeps NVDA's, Narrator's or
   JAWS's keys.
5. **Choosing a style**: the Settings window's Keyboard section lists the four; Command Control Comma, then K, goes
   round them, saying each name. The welcome asks once: "Which screen reader are you used to?"
6. **Help follows the style**: keyboard help (VO-K, NVDA+1, Insert+1 in JAWS, Caps+F1 in Narrator) names keys in the
   style's own terms; one guide page per style; the Slash list shows the style's keys.

## The Mac-versus-Windows choices (decided here unless the maintainer says otherwise)

- **The screen reader key is Caps Lock in every Windows style** (Insert doesn't exist on Mac keyboards). JAWS's
  laptop layout and Narrator already allow Caps Lock, so their users know it. Control+Option also works, as now.
- **The number pad** (NVDA's and JAWS's desktop layouts, Narrator's keypad) only on Macs that have one; laptop
  layouts are the default, as JAWS's laptop layout is for JAWS laptop users.
- **The Windows key is Command; Alt is Option; Ctrl is Control for screen reader chords and becomes Command for
  app shortcuts** (Control C copies). Alt+Tab is Command+Tab; the Applications key is VO-Shift-M (right Option alone
  in the Windows family, as the shelved layer had).
- **Keys the Mac keeps for itself** (Command+Space, Command+Tab, Control+arrows for Spaces, Command+H, F11, Fn
  combinations) are never taken; where a Windows key collides, the style's Mac key gets a second key, listed in
  style-mapping.md under CLASH for the maintainer to settle.
- **Windows-only features** (Windows' own UI Automation views, Narrator's Outlook-specific modes, JAWS's
  Research It, Convenient OCR on a PC camera) are marked MAC-N/A, not imitated; where TurnOver has a Mac version
  (screen recognition for OCR, image description for Picture Smart) the key is mapped to it.
- **Names**: the styles are called "NVDA keys", "Narrator keys", "JAWS keys", which describes what they are. TurnOver
  never claims to be, or to contain, those products.

## The order (one new thing per release, each with a stress test and the regression pass)

1. **Groundwork (no visible change).** The four-style setting with families; keymaps as data, NVDA's from today's
   Windows style; the regression pass must be identical before and after. One build.
2. **NVDA keys everywhere.** The translation where VoiceOver reads, from Windy's chord table, inside TurnOver;
   the Windows editing and system keys there too. This is the roadmap's "Windows style everywhere" and the one
   people will like most. Decide first: Windy folded into TurnOver, or kept as a separate app (see below).
3. **JAWS keys.** The table over the same commands (JAWS's virtual cursor quick keys are nearly NVDA's; Insert+F6/F7
   lists, Insert+Up say line, Insert+Down say all, the JAWS cursor as TurnOver's review), plus the BUILD items
   ranked first in style-mapping.md. JAWS has the most users coming from Windows, so this goes before Narrator.
4. **Narrator keys.** Scan mode as browse mode (Caps+Space), Narrator's reading commands (Caps+Ctrl+I/O/P and
   the view keys), the rest by the table.
5. **VoiceOver's own style completed** from the VoiceOver table (the Mac style's remaining MAP and BUILD items).
6. **Trackpad per style.** VoiceOver's Trackpad Commander for the Mac family; NVDA's and Narrator's touch gestures
   for theirs (JAWS has few touch gestures; it follows NVDA's). This is the roadmap's trackpad parity.

Each step is an issue with its own stress test, and the public roadmap says what's next in plain words.

## Decided (19 Oct 2026: "Yes to all")

- **Windy is folded into TurnOver** for step 2: one product, one key tap. Windy's chord table and its
  modifier-by-modifier posting move into TurnOver; the separate Windy app stops once TurnOver has them.
- **Clashes: the Mac's own shortcut wins**, and the style's key gets a second key (listed per clash in
  style-mapping.md).
- **All four styles are included for everyone.**
- **The welcome asks once which screen reader you're used to** and sets the style.

## Progress

- **Step 1, groundwork: built** (19 Oct). The four styles in two families, stored as before; style key tables as
  data (Resources/keymaps, embedded), Narrator's and JAWS's empty. 103 unit tests pass. No visible change.
- **Step 2, NVDA keys where VoiceOver reads: built, not yet tried live** (19 Oct). WindowsKeys.swift's layer now
  carries Windy's whole table: Caps Lock as the NVDA key (read from the HID manager), NVDA chords sent as VoiceOver's
  (modifier by modifier), Caps Space browse mode with the Quick Nav letters, the Windows key's chords on Option,
  Windows editing keys, the browser and Finder keys, the lone taps. On in NVDA, Narrator and JAWS keys while TurnOver
  runs but VoiceOver reads the app; off where TurnOver reads and when TurnOver is off. The live test couldn't run
  (the Mac was locked); the driver can't hold Caps Lock (it posts events, the layer reads Caps from the HID manager),
  so the chords need a person's hands. Then the regression pass; then Windy can stop.
- **One setting, two readers, step 1: rate, volume and pitch** (19 Oct, reference/keyboard-styles/settings-parity.md):
  changed in VoiceOver first through its AppleScript commands, TurnOver taking the value VoiceOver reports. Tried by
  hand: works. Caught live: VoiceOver applies a change to the Activity that's live (the app in front was in an
  Activity of its own), so the default stayed at 70%; fixed by unticking Speech in that Activity. The welcome and the
  guide must tell testers the same: Activities that set their own speech keep their own speed. Next: punctuation,
  typing echo, verbosity and capitals through the verbosity rotor (VO-V), each walk read back and ending with Escape.
- **Step 3, JAWS keys: built** (20 Oct). Resources/keymaps/jaws.json: 54 keys of JAWS's laptop layout over TurnOver's
  commands, each a command's name or "=" and the Windows-style key whose command it runs (so an app's own command on
  that key comes along), plus four keys that apply only during say all. New commands: line to and from the cursor,
  character code on the third press, spell the selection, time with seconds and week, the app's version, speech
  history, settings, say all back/on a sentence and faster/slower for that say all. A unit test checks every entry
  resolves. Not yet heard with Caps Lock chords (needs a person's hands). Left for later (and for contributors): the
  JAWS layer (Insert+Space), PlaceMarkers, the JAWS-only web quick keys, JAWS's Word and Excel keys, skim reading.
