# Word module ownership

Word's integration lives in `Sources/Apps/Word`. The split addresses issues 2, 70 and 116: shared reading code asks
for app behavior through `AppModule`, rather than selecting Word by bundle identifier or calling a Word type.
The supported-app inventory remains in `Edition`; `System/BuiltInModules` registers the module.

## Responsibilities

| File | Responsibility |
| --- | --- |
| `WordAppModule.swift` | App policies, focus correction, sheets, sidebar, menus and page-range ownership |
| `WordTableNavigation.swift` | Module-level table and structural-navigation scripts, including commands from a cell |
| `WordDocument.swift` | Document reading, commands, selection detection, headings, comments, revisions and page moves |
| `WordSpelling.swift` | Document spelling search and its whole-document scripting fallback |
| `WordTableCell.swift` | Cell recognition, coordinates, headers, focus descriptions and cell moves |
| `WordTextArea.swift`, `WordHeaderFooter.swift` | Other editable areas and header/footer names |
| `WordTextInfo.swift` | Page-aware text ranges, lines, annotations and location reports |
| `WordScripting.swift` | AppleScript requests, their serial worker queue and Automation permission feedback |

## Shared interfaces

The app module owns these decisions:

- `supplementsSpellingMarks`: whether the system checker supplements the app's marked words.
- `usesNativeSpellingMenu`: whether corrections stay in the app's own context menu.
- `playsNativeCaretBoundarySound`: whether TurnOver adds a sound after sending a native caret key.
- `isTableCellText`: whether an app-specific text hierarchy needs the cell-movement path.
- `handlesNativeFormattingShortcuts`: whether the app already owns native formatting feedback.
- `ignoresAnnouncement`: whether the module has already reported native news, given the last key and its age.
- `hint`: an app-specific hint, explicit suppression, or the ordinary control fallback.
- `paragraphFormatting`: supplemental paragraph details, returned on main when accessibility lacks alignment.

Word retains its native spelling menu, its existing Command-B/I/U reports, the 0.8-second native-announcement
suppression, and its six-parent cell lookup. Detailed formatting still asks Word only when accessibility does not
provide alignment. Script names, gestures, AppleScript sources, timeouts and callbacks retain their existing paths.
Automation consent state is protected by a lock because module instances' worker queues and delayed main-thread
permission feedback share it. Each pending request owns its permission reminder; no lock is held across an Apple Event.

These files still compile in TurnOverCore with its MainActor default. This is an ownership boundary, not a dynamic
module loader. `Tools/check-app-boundaries.py`, run by `build.sh`, rejects Word implementation types and Word bundle
selection in shared Core/Views code; it permits the supported-app inventory. More apps can join the check after
their existing dependencies have been removed.

## Verification

`WordModuleIsolationTests` checks policy ownership, announcement timing, hints, native spelling-menu delegation and
the real repeated formatting-report command. `FormattingFeedbackTests` checks that module policy prevents duplicate
queries without swallowing native shortcuts. `WordCaretBoundaryTests` exercises the actual native caret paths,
including a deeply nested table cell; it is registered in the runner alongside `WordPageReadingTests`.

Run `./build.sh --no-install`, then `./build.sh` to install the signed app. The full build runs source membership,
app boundaries, the app index, unit tests, braille checks and helper self-tests. The boundary check's own cases run
with `python3 Tools/check-app-boundaries.py --self-test`.

A listening trial remains necessary. In a disposable public sample, check typing and selection; heading, page and
table moves; row/column/header announcements; leaving a table; spelling navigation and Word's correction menu;
Command-B/I/U state feedback; and the first/repeated formatting report. Check returning from the ribbon, Find and
a Save sheet as well. Record macOS/Word versions, keyboard style, reader ownership and coexistence mode. Automated
fixtures do not establish audible behavior or first-use Automation consent.
