# The TurnOver menu: a tidier layout (proposed 11 Oct 2026; built 12 Oct 2026)

Superseded on 21 Oct 2026 by NVDA's shape: no settings in the menu at all. Every setting lives in the Settings window
(Sources/TurnOverSettings), in sections in NVDA's order: General, Speech, Keyboard, Item details, Web pages, Documents,
Screen recognition, Other apps' speech, Experimental (Braille to come, a contributor's). The menu is This app, Settings,
Keys, Tools, Help, Support TurnOver, Quit, and Command Control M opens it in one press. Two settings wait in Tools
until they have a section: Braille and Voices for other languages. The rest of this file is the 12 Oct design, kept.

The request: "it's getting a little busy, especially in the allowed apps menu … some of the descriptions are a bit
abstract." Built 12 Oct 2026, with these choices: "This app" first; hand over and quit in one submenu. Changed from the
proposal: Reading stays two sections (Documents, Item details), because one would have held 21 items; long
sections have small groups (Capitals, Typing echo, Cursor, Messages, Tables, Fonts).

## What is wrong now

- **Thirteen items at the top**, mixing settings, actions and information: Preferences, Shortcuts, Input help,
  Keyboard style, New to try, Plugins, Force quit, Send feedback, About, Quit, and from the app Hand over to
  VoiceOver, Updates, Tester key, Uninstall.
- **Applications is two levels down** (Preferences, then Applications), and it is the busiest list:
  - 13 named apps, ten of them titled "(preview, off until you turn it on)" while their value says "TurnOver leads":
    the title contradicts the value, and the same 35 words are heard ten times;
  - "Unverified apps": 115 apps in one flat list, every one saying "VoiceOver leads".
- **Explanations inside titles**: "Sounds: a tick as the focus moves, a click as an item is pressed", "Quick keys wrap
  round the page (H, K and the rest go on from the other end, and say so)". Long to hear on every pass, and the first
  word (used for typing to jump) is often not the setting's subject.
- **Abstract names**: Presentation, Object descriptions, Position information, Document formatting, Automatic
  hand-over, Keyboard focus follows the cursor, Screen layout, Show messages.
- **The same setting twice**: Keyboard style at the top and under Keyboard.

## Rules for the new layout

1. At most nine items at any level, so "3 of 9" is short, and nothing deeper than three levels.
2. The first word says what the item is about, and is different from its neighbours, so typing a letter lands on it.
3. Titles are names; the explanation is said after a pause (as Hints are), not read as part of the title.
4. A list that changes says how many it holds: "Read by TurnOver, 5 apps".
5. Things done most often come first; things done once (Uninstall, Tester key) at the end.

## The top level (nine items)

1. **This app: Claude** (the app in front). Who reads it (Return switches, the same as Command Control Shift T); the
   app's own commands and settings (what each app module adds today); "Change the item I'm on" (the plugin maker);
   "Ask for this app to be supported".
2. **Apps**: the new Applications list (below).
3. **Settings**: the preferences, regrouped (below).
4. **Keys**: list every shortcut here (today "Shortcuts"); keyboard help, each key says what it does (today "Input
   help"); your own keys (today Commands and keys).
5. **New in this build**.
6. **Send feedback**: one item. It asks once whether to include what TurnOver said (Yes or No), instead of two
   items that differ by four words. Marked moments are offered first when there are any.
7. **Tools**: Force quit an app; Screen recognition; Plugins (for plugin makers).
8. **About and updates**: About; Check for updates; Tester key; the guide; Uninstall.
9. **Hand over to VoiceOver**, then **Quit TurnOver** (two items; Quit always last).

(Ten with Quit: or Hand over and Quit become one submenu "Hand over or quit". To decide.)

## Apps

```
Apps
  Claude, the app in front: TurnOver reads it              Return: switch to VoiceOver
  Switch between TurnOver and VoiceOver as I change apps: on
  Read by TurnOver, 5 apps                                  each: Return hands it to VoiceOver
  Read by VoiceOver, supported, 8 apps                      each: Return gives it to TurnOver ("Music, preview")
  Other apps on this Mac, 115                               type to find; "not yet checked with TurnOver"
  Ask for an app to be supported
```

- An app is in one list or the other, so its place says who reads it: no "TurnOver leads" heard on every row.
- "Preview" is one word after the name, and only in the VoiceOver list, where it helps the choice.
- The long list opens as a chooser (type to narrow), as Unverified apps does now, and says once at the top what
  "not yet checked" means.
- Return moves an app between the lists and says so: "Music: TurnOver reads it now".

## Settings

```
Settings
  Speech          voice, rate, volume, punctuation, capitals (a submenu: say "cap", raise the pitch), where speech plays, other languages
  Keyboard        style, TurnOver key, typing echo, laptop or desktop layout, groups
  Reading         headings, links, lists, tables… (today Document formatting), and what is said about an item (today Presentation)
  Web pages       today Browse mode
  Braille
  Sounds          tick and click; chimes or words at hand-over
  Starting        open at login; show in the menu bar
  Screen recognition
```

Eight sections, each named by its subject; "Reading" replaces two abstract ones.

## Names, before and after

| Now | Proposed |
|---|---|
| Automatic hand-over to and from VoiceOver | Switch between TurnOver and VoiceOver as I change apps |
| Presentation | (into Reading) What is said about an item |
| Object descriptions | Help text of items |
| Position information | Position, such as 3 of 10 |
| Keyboard shortcuts | Each item's keyboard shortcut |
| Hints: what you can do with an item, after a pause | Hints after a pause |
| Document formatting | Reading |
| Browse mode | Web pages |
| Screen layout: links and controls flow with the text… | Links and buttons in the line, as on screen |
| Quick keys wrap round the page (H, K and the rest…) | Quick keys go round the page |
| Keyboard focus follows the cursor | Moving the cursor moves the keyboard focus |
| Show messages (braille) | Messages on the display |
| Sounds: a tick as the focus moves, a click as an item is pressed | Sounds as I move and press |
| Chimes instead of words when taking over from VoiceOver and handing back | Hand-over: chimes or words |
| Say cap before capitals / Raise the pitch for capitals | Capitals: say "cap", raise the pitch |
| Install the plugin you are writing (the starter folder) | Install my plugin from its folder |
| Voices for other languages (every language listed) | Voices for other languages (only languages with a voice on this Mac) |

## How it would be checked

The probe's menu outline (turnover-coretest --menu-outline) before and after; every setting still reachable and
saved; type-ahead lands on each first word; the old menu's paths in the guide and the beta guide updated. Settings
keep their saved values (only titles and places change).
