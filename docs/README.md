# The plans

Read first, if you are new: [HOW-A-KEY-BECOMES-SPEECH.md](HOW-A-KEY-BECOMES-SPEECH.md), then
[HOW-FOCUS-BECOMES-AN-OBJECT.md](HOW-FOCUS-BECOMES-AN-OBJECT.md), then [LOG.md](LOG.md) for reading a session.
[DECISIONS.md](DECISIONS.md) says what is settled, parked and open. The rest of this folder is the plans.

The design documents behind the code: each was written before its feature was built and says why it is the way it
is. The code's comments point here ("docs/MENU-PLAN.md"). The files at the root (README, ARCHITECTURE, TESTING,
PATTERNS, PLUGIN-GUIDE, PUBLIC-ROADMAP, CHANGELOG) are the ones to read first; these are the detail.

These are design notes, written before each piece was built; they are not task lists, and nothing in them is ticked
off. The status column (20 Oct 2026) says how each stands against the code.

| File | What it is | Status |
|---|---|---|
| `APP-RECIPES-PLAN.md` | Apps described by data, not code: recipes (`Resources/recipes/*.json`), the parts a recipe can name, and the tool that drafts one. | Built: seven apps read from recipes. The explorer and fixture comparison are not. |
| `BRAILLE-PLAN.md` | Braille displays: the Mac's own drivers reached from Objective-C, the tables, typing, and VoiceOver's chords. | Built (build 8). Tested with one 20-cell display; other displays untested. |
| `KEYBOARD-STYLES-PLAN.md` | The keyboard styles (VoiceOver, NVDA, Narrator and JAWS keys) everywhere on the Mac, whichever reader is speaking, and how clashes with Mac shortcuts are settled. | Current. Steps 1 to 3 built (styles, NVDA keys where VoiceOver reads, JAWS keys); 4 to 6 open. Its Progress section is kept up to date. |
| `MENU-PLAN.md` | The TurnOver menu (Command Control Comma, M): "This app" first, names in titles and explanations after, hand over and quit in one place. | Superseded 21 Oct: NVDA's shape, every setting in the Settings window, the menu seven lines (the note at its top). |
| `PLUGIN-TOOLKIT-PLAN.md` | The plugin toolkit: the hand-written format, the maker in the app, `--explain`, and the tests that travel with a plugin. | Partly built (the format, checker, maker and tests); the sandboxed scripts are not, and plugins stay data only. |
| `TOC-PREFERENCES.md` | Every setting that can come from VoiceOver: the map from VoiceOver Utility's export to TurnOver's settings, and what has no VoiceOver counterpart. | Reference; the "Standard" column describes an edition that no longer exists. |
| `VOICEOVER-PARITY.md` | The VoiceOver keys: every VoiceOver command, what answers it in TurnOver, and the rulings on the ones that differ. | Reference, from a 12 Oct audit; a few rulings since are in the code's comments. |
| `NVDA-PARITY.md` | The NVDA keys: every NVDA command, what answers it in TurnOver, and the variations put to the maintainer. | Reference, from a 12 Oct audit; the unbuilt items are in PUBLIC-ROADMAP.md. |

`archive/` holds plans that are finished or superseded, kept as they were.
