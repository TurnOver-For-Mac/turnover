# TurnOver plugin guide

This is the whole format for TurnOver plugins. It is written for people and for the AI assistants
most people will use to make plugins. If you are an AI: read this, then BRIEF.md in the brief folder,
and follow the steps there.

A plugin makes one application work better with TurnOver, a screen reader for the Mac. Today a plugin
is an **app profile**: two JSON files, no code. Profiles cannot run programs, read files, use the
internet, or touch any application other than the ones they name. That is deliberate.

## The folder

```
my-plugin/
  manifest.json   who made it, and which application it is for
  profile.json    the rules
```

### manifest.json

```json
{
  "id": "bambustudio-profile",
  "name": "Bambu Studio",
  "version": "0.1",
  "summary": "Names Bambu Studio's home page buttons, and adds keys for a new or existing project.",
  "description": "Names the home page's buttons, and adds keys for a new project and opening a project.",
  "author": "TurnOver",
  "contact": "https://github.com/TurnOver-For-Mac/turnover/issues",
  "apps": ["com.bambulab.bambu-studio"],
  "kind": "profile",
  "abilities": ["read", "menu"],
  "privacy": "Reads Bambu Studio's window only; nothing leaves your Mac.",
  "license": "MIT",
  "changes": [{ "version": "0.1", "notes": "First version." }]
}
```

- `id`: one word, letters, digits and hyphens. Installing a plugin with the same id replaces it.
- `apps`: bundle identifiers. The rules apply in these applications and nowhere else.
- `formatVersion` (optional, 1 if missing): the version of this format the plugin is written in. TurnOver reads
  every older format for good; a plugin in a newer format than the TurnOver reading it is refused with a reason.
- `minimumTurnOver` (optional): the oldest TurnOver the plugin works with.
- `provides` (official plugins only): a feature built into TurnOver that installing the plugin switches on.
  Today only `"games"` (Steam speech). It does nothing in a plugin that isn't the library's official one.

The listing (needed to be in the plugin library; a plugin without it still installs on your own Mac):
- `summary`: one line (120 characters at most), spoken at install and in the library.
- `description`, `author`, and `contact` (an email address or web page for problems).
- `abilities`: what it does, in these words: `read` (its app's window: labels, watching, silencing),
  `press`, `focus`, `menu`, `keys` (sending key combinations), `say`. The check compares them with what the
  profile does: something used but not declared must be added; something declared but not used is noted.
- `privacy`: what it reads and where anything goes.
- `license`: an open licence by its SPDX name. The library's own is `MIT`; also `Apache-2.0`, `BSD-2-Clause`,
  `BSD-3-Clause`, `ISC`, `MPL-2.0`, `CC0-1.0`, `Unlicense`.
- `changes`: what each version changed, newest first; the current version must be there.

`turnover-plugin check <folder> --listing` checks all of this, and the keys, without the app running: keys in the
fixed form with a description, never TurnOver's essential keys (Command Control Comma, Command Control Period:
refused even on your own Mac), and a note for each key that TurnOver, VoiceOver's or NVDA's keys, an official
module or another plugin already uses (in your app, your plugin's comes first). Official modules' keys inside
documents (Word's headings, for example) are not in that list yet.

What no plugin may do, on any Mac (the plugin doesn't load, and says why): take TurnOver's essential keys; bind a
plain key (a letter, Return, Delete) with no modifier beyond Shift and no function key, since it would type in the app; choose
the Apple menu, the Services menu, or a pattern for the first menu (it could land on the Apple menu); choose Paste,
Log Out, Lock Screen, Restart, Shut Down, Sleep, Force Quit or System Settings from any menu; send keys that reach
outside its app: Command Control or Command Option Shift with anything, function keys with modifiers (Command F5
turns VoiceOver on or off), F11, Control with a number or an arrow (Spaces), screenshots, Command Tab, Spotlight,
Paste, or TurnOver's own keys. `--level Verified` or `--level Official` checks against that level's library rules
(Verified may rename named items; Official may also claim closed apps and give views).

### Writing it by hand

The files are JSON, made forgiving for people:

- Comments are allowed: `// to the end of the line`, and `/* … */`.
- A comma after the last item of a list or group is allowed.
- Every problem names the file and the line: `profile.json, line 12: nameFrom must be one of nextText,
  previousText, childText, parentText, help, description; "nextTxt" is not`.
- A field TurnOver does not know is a warning, not silence: `profile.json, line 4: TurnOver does not know the
  field "nmae"; it is ignored (did you mean "name"?)`.
- Schemas for editors and AIs: `/Applications/TurnOver.app/Contents/Resources/plugin-schema/manifest.schema.json`
  and `profile.schema.json` (add
  `"$schema"` with the file's path at the top of a file to have an editor check it as you type).

### profile.json

Four lists, all optional:

```json
{
  "labels":  [ … names for elements that have none, or the wrong one … ],
  "keys":    [ … keys that press, focus or read an element, choose a menu item, or send keys … ],
  "watch":   [ … elements to read aloud when they change … ],
  "silence": [ … elements TurnOver should not announce … ]
}
```

## Matching elements

Every rule names elements with a **match**. Every field given must agree; leave out what you do
not need. Text comparisons ignore case, and `*` matches anything (`"Print*"`). A field that is
just `"*"` means "has one": `"help": "*"` matches elements that have a tooltip.

| Field | Matches | Example |
|---|---|---|
| `role` | The accessibility role, with or without AX | `"AXButton"`, `"button"`, `"image"` |
| `subrole` | The subrole | `"AXSecureTextField"` |
| `identifier` | AXIdentifier: the steadiest choice when the app sets one | `"printButton"` |
| `title` | AXTitle | `"Export"` |
| `description` | AXDescription | `"homepage"` |
| `help` | The tooltip | `"Slice plate*"` |
| `value` | The current value | `"100%"` |
| `text` | The text inside the element | `"Open Project"` |
| `window` | The title of its window | `"Untitled*"` |
| `inside` | An ancestor that must match (another match) | `{"role": "toolbar"}` |
| `parent` | The immediate parent must match (another match) | `{"role": "group"}` |
| `unnamed` | Only elements with no title or description | `true` |
| `pressable` | Only elements that can be pressed (actions include Press) | `true` |
| `nth` | For keys: which of the matches (1 first, -1 last) | `2` |

The snapshot (snapshot.txt, or `turnover-plugin snapshot <app>`) shows every element as
`role/subrole title= description= help= identifier= text= value= actions=`. Controls with no name
are marked `UNNAMED`, with the text beside them when there is some. That is usually the label.

Good matches are specific enough to hit only what you mean, and plain enough to survive an app
update: prefer `identifier`, then `role` with `title`, `description` or `help`, then
`unnamed` with `inside`. Avoid `nth` in labels.

## labels

Labels are tried in order; the first rule that matches an element wins. Put specific rules before
general ones.

```json
{ "match": { "role": "image", "unnamed": true, "inside": { "description": "homepage" } },
  "nameFrom": "nextText", "role": "button" }
```

- `name`: the name to speak, or
- `nameFrom`: where to take it from: `"nextText"` (the nearest text after it; if there is none beside it, the
  nearest beside the element it sits in, up to six levels out), `"previousText"` (likewise, before it),
  `"childText"` (its own text), `"parentText"`, `"help"` (the tooltip's first sentence),
  `"description"`, `"ancestorHelp"` (the nearest tooltip on something it sits in), `"rowText"` (the whole row it
  sits in, read as one).

A title that is only a programming class name ("Avalonia.Controls.Grid") counts as no name: TurnOver doesn't read
it, and `"unnamed": true` matches it.
- `role` (optional): the role to speak instead of the element's own, such as `"button"` for a
  pressable image.

When the name comes from the text beside the element, TurnOver does not read that text again.

## keys

```json
{ "key": "turnover+shift+p", "description": "Prepare tab", "action": "press",
  "target": { "role": "radio button", "title": "Prepare" } }
```

- `key`: a TurnOver gesture. Modifiers: `turnover` (the user's TurnOver key: Caps Lock, or Control+Option),
  `shift`, `control`, `option`, `command`. Keys: letters, digits, `f1`…`f12`, `upArrow`,
  `downArrow`, `leftArrow`, `rightArrow`, `enter`, `escape`, `tab`, `space`, `home`, `end`,
  `pageUp`, `pageDown`, `delete`, `backspace`, and punctuation such as `/` `.` `,` `[` `]`.
  Use `turnover+` keys for plugin commands, so the application's own shortcuts still work. Check
  menus.txt for the application's shortcuts before choosing one without `turnover`.
- `description`: what it does, in a few words; spoken by input help and listed in the shortcuts list.
- `action`, one of:
  - `"press"`: press `target`.
  - `"focus"`: move the keyboard focus to `target`.
  - `"read"`: read `target` (its text, or its name and state).
  - `"menu"`: choose a menu item by path: `"menu": ["File", "Export", "Export G-code…"]`.
    Paths are in menus.txt; `*` works in each step.
  - `"keys"`: send a key combination to the application: `"keys": "command+shift+e"`.
  - `"say"`: speak `say`.
- `say` (optional with any action): spoken after it, such as `"Exported"`.
- `letter` (optional): its letter in the plugin layer, one letter or digit, unique in the plugin. Command Control
  Comma, P, then the letter runs it in either style; Down Arrow after P lists all the plugin's commands, with or
  without a letter. A key in the `key` field is then optional in practice: everything is reachable through P.

## watch

```json
{ "match": { "role": "progress indicator", "inside": { "title": "Slicing*" } }, "prefix": "Slicing" }
```

Reads the element whenever its value changes while the application is in front.
`read`: `"value"` (default) or `"text"`. `prefix`: spoken first.

## hold

```json
{ "focus": { "identifier": "productsGrid" }, "items": { "identifier": "PART_RowsPresenter" } }
```

For a list that takes the keyboard but tells TurnOver nothing as the arrows move (no focus, selection or value
news). When the focus lands on an element matching `focus`, TurnOver holds the one matching `items` and walks its
rows (its children) with its own cursor: Up and Down move and read each row, Home and End go to the ends, Return and
Space press the row (or its first button), Escape lets go.

## silence

```json
{ "role": "image", "unnamed": true, "inside": { "description": "banner*" } }
```

Elements that only add noise. TurnOver does not announce them on focus and leaves them out of
documents.

## Making one without writing anything

In the app, on the item to change (where the focus is, or where TurnOver's review cursor is), press TurnOver
Shift Slash (VoiceOver's own key for labelling). A short list:

- **What is this?** Its role, name, identifier, what it can do, and how TurnOver would find it again. Copied too,
  as the `match` to paste into a file.
- **Label this item.** Type the name (each letter is echoed; Return saves, Escape cancels).
- **Give this item a key.** Press it: the key presses the item (or moves to it, or reads it). A key with no
  modifier, or one TurnOver already uses, is refused and said why.
- **Read this when it changes.** A status line, a progress bar.
- **Don't announce this.**
- **Undo the last change**, **My changes for the app** (Return removes one), **Share my changes** (a .zip on the
  Desktop).

Every change goes into your own plugin for that app, "My changes for <app>" (folder `my-<bundle id>` in the plugins
folder), and applies at once. TurnOver picks the match: the identifier when the app gives a steady one; else the
title, description or tooltip; else "unnamed, inside" the nearest named part, with its place (`nth`) among the
matches. It checks the match finds that item, and only that one.

## Testing

### Trying it with an AI

Choose Make a plugin in the Plugins menu with the app in front, and pick Claude, ChatGPT or Gemini. With Claude Code,
OpenAI's Codex or Google's Gemini CLI installed, the AI opens in the plugin's folder and works the way a developer
would: it looks at the app, writes the plugin, checks it, installs it, and tries it with `turnover-plugin try`,
hearing what TurnOver says. TurnOver presses the keys for it, says aloud that an AI is trying keys, and only in that
app for three hours; keys that quit, close or delete are refused, and Stop AIs trying keys in the Plugins menu ends
it. When the plugin format can't do what's needed, the AI writes a parts request instead. Without those tools,
ChatGPT and Gemini work through their websites: the brief is copied for you to paste.


The tool is inside TurnOver: `/Applications/TurnOver.app/Contents/MacOS/turnover-plugin`.

```
turnover-plugin check "<plugin folder>"          the rules against the running app, and what TurnOver will say
turnover-plugin check "<plugin folder>" --read   also web content as TurnOver reads it with the plugin
turnover-plugin snapshot <app>                   the app as it is now (after switching screens)
turnover-plugin menus <app>                      every menu path
turnover-plugin install "<plugin folder>"        install; applies the next time the app comes to the front
turnover-plugin list                             what is installed
turnover-plugin listen                           what TurnOver says, live, while you try the app
turnover-plugin explain <key> [app]              which command a key reaches there, and who else would answer it
turnover-plugin try <app> <key>…                 TurnOver presses the keys in the app ("wait 1" waits) and prints what it
                                                 said; only for an app you chose Make a plugin for, in the last 3 hours
```

### Tests that travel with the plugin

```
turnover-plugin record <app> "<plugin folder>"   each new window, sheet, tab or pane, as you move through the app,
                                              saved to tests/screen-1.json, screen-2.json … (text masked; --no-mask keeps it)
turnover-plugin test "<plugin folder>"           the checks in tests/expect.json, against those screens, with no app
```

`tests/expect.json` is a list of checks: on a screen, an item (a match, as in a rule; none means the focus), and
what TurnOver says for it as a regular expression:

```json
[
  { "name": "the proxy icon is named", "screen": "screen-1.json", "item": { "role": "AXImage" }, "says": "^Document icon, button" },
  { "name": "the text is not", "screen": "screen-1.json", "notSays": "Document icon" }
]
```

Masked screens keep roles and identifiers but not text, so a check (or a rule) that matches by title needs a
screen recorded with --no-mask; never share a plugin whose screens hold anything private. TurnOver's own build runs
the tests of every plugin it carries (Tests/Plugins/sample-textedit is the example). The test command needs a
TurnOver developer build for now (the copy inside TurnOver.app cannot load the replay library yet).

A plugin in TurnOver's plugins folder (`~/Library/Application Support/TurnOver/plugins/`) is reloaded the moment
it is saved: TurnOver says "Plugin Bambu Studio reloaded", or reads the first problem with its line. Write it
there, save, and try the app; there is nothing to install or restart while you work. `check` also prints each
warning with its line.

`check` exits with an error and says PROBLEM for every rule that matches nothing, a key TurnOver does
not know, a target that cannot be pressed, or a missing menu item. A rule may match nothing because
its element is on another screen of the app (a tab not showing, a dialog not open); check again
with that screen showing.

## A complete example

Bambu Studio's home page has pressable images with no names; the name of each is the text
beside it.

```json
{
  "labels": [
    { "match": { "role": "image", "unnamed": true, "pressable": true, "inside": { "description": "homepage" } },
      "nameFrom": "nextText", "role": "button" }
  ],
  "keys": [
    { "key": "turnover+shift+n", "description": "New project", "action": "menu", "menu": ["File", "New Project"] }
  ]
}
```

## Views: a whole app in one section

Some apps have a shape TurnOver already knows how to drive. For those, a profile can carry a
**view**: a section that names the app's parts, and TurnOver's own view for that shape does the
rest. No rules needed, though a profile can have both. The view applies to every app in the
manifest's `apps`.

```json
{
  "view": { "kind": "chat", "chat": { … } }
}
```

Three shapes so far.

### chat

A messaging app: the keyboard stays in the message box; Tab and Shift Tab take TurnOver's cursor to
the messages (newest first) and the conversations, where the arrows, Return and the shortcut menu are
TurnOver's. New messages in the open conversation are read as they arrive. Messages and WhatsApp
work this way; TurnOver's own description of WhatsApp is:

```json
{
  "view": {
    "kind": "chat",
    "chat": {
      "conversations": "ChatListView_TableView",
      "transcript": "ChatMessagesTableView",
      "composer": "ChatBar_ComposerTextView",
      "title": "NavigationBar_HeaderViewButton",
      "sectionsPrefix": "SidebarButton_",
      "searchField": "TokenizedSearchBar_TextView",
      "resultsPrefix": "ChatListSearchView_",
      "saysSent": true,
      "message": { "roles": ["AXStaticText", "AXHeading"] },
      "conversation": { "any": [
        { "role": "AXButton", "identifier": "" },
        { "roles": ["AXGroup", "AXButton"], "identifier": "ChatListSearchView_*Result" }
      ] }
    }
  }
}
```

The parts are accessibility identifiers (`turnover-plugin snapshot <app>` shows them):

| Field | What it names |
|---|---|
| `conversations` | The list of conversations |
| `transcript` | The messages of the open conversation |
| `composer` | The message box |
| `title` | The open conversation's title: when it changes, the messages shown are not new ones |
| `sectionsPrefix` | Optional: a bar of sections beside the conversations (WhatsApp's Chats, Calls…), by the start of their identifiers |
| `searchField` | Optional: the app's own search field; Tab and Down then go to its results |
| `resultsPrefix` | Optional: the start of the search results' identifiers; while they show, they are the conversations |
| `saysSent` | `true` when the app says "sent" itself; otherwise TurnOver says it |
| `message` | A match for a child of the transcript that is a message (or a day heading) worth reading |
| `conversation` | A match for a child of the conversations list that is a conversation |

`message` and `conversation` are matches, the same as a rule's (see Matching elements), with two
extras any match may use: `roles`, a list of roles of which the element's must be one, and `any`, a
list of matches of which one must fit. An empty match, `{}`, fits everything; `"identifier": ""`
fits only elements with no identifier.

### media

An app laid out like Music, Podcasts or TV: a sidebar, a page of shelves, a player and a toolbar,
read as flat areas with Tab between them and the arrows within. The view finds the parts itself, so
the section is only the kind:

```json
{ "view": { "kind": "media" } }
```

### panes

Most Mac apps: a sidebar, a list, the detail, perhaps a toolbar. Name the parts in order, each with a
match, and Tab and Shift Tab go round them; TurnOver 1 to 9 go straight to one. A part that can take the keyboard gets it (a table, an outline, a text area)
and TurnOver reads it as any focus; a list that cannot is held by TurnOver's cursor, row by row;
anything else is put under the cursor and read. Inside a part, the app's own keys work as they do.
TurnOver's own description of Notes:

```json
{
  "view": {
    "kind": "panes",
    "panes": { "parts": [
      { "name": "Folders", "match": { "role": "AXOutline", "description": "Folders" }, "hint": "Up and Down choose a folder." },
      { "name": "Notes list", "match": { "role": "AXTable", "identifier": "ICMNoteListTableView*" }, "hint": "Up and Down choose a note." },
      { "name": "Note", "match": { "role": "AXTextArea", "identifier": "Note[*" } }
    ] }
  }
}
```

`hint` is said after the part's name the first time you reach it. A part that is not on screen (a
hidden sidebar) is skipped.

### Trying a view

`turnover-plugin check "<plugin folder>"` reads the view and, with the app open, says whether each
named part is in its window. Install the plugin, switch the app on in the TurnOver menu under
Applications, and bring it to the front. The Plugins list in the TurnOver menu shows each plugin's
view. A plugin's view replaces TurnOver's built-in one for the same app, so a better WhatsApp view
can be tried without a new TurnOver.

## What a plugin can and cannot do

A plugin can read the apps it names and speak what it reads; label, silence and watch their
elements; and bind TurnOver keys that press an element, move focus, read, choose a menu item, say
something, or send a key combination to the app. It cannot run code, read or write files, use the
network, touch any other app, change TurnOver's settings, or stop VoiceOver coming back.

Sending keys and choosing menu items are the only ways a plugin can act on an app, so the installer
says each one in words before installing ("TurnOver Shift P sends Command Delete to Mail"), and a
plugin that can quit, delete, remove or send needs a second confirmation: choose "Install a plugin
from the clipboard" again within 20 seconds, or `turnover-plugin install --confirm`.

## Sharing

A plugin is its folder. Share the folder; whoever installs it uses `turnover-plugin install`.

The plugin library (TurnOver menu, Plugins, Plugin library) lists plugins that passed every check, signed by
TurnOver, each with what it can do said before it installs. Every plugin in it can be read in full at
github.com/TurnOver-For-Mac/turnover-plugins.

Library ZIPs may contain at most **256 entries**, including directory entries, and **16 MiB (16,777,216 bytes)**
of uncompressed content in total. The installer counts the actual decompressed bytes before extracting files;
the compressed download size and the ZIP's stated sizes do not establish this limit. Keep profiles and sample
fixtures within these limits. Archives with encrypted entries (even with an empty password), unsafe paths,
symbolic links, unreadable content or failed checks are refused, and their temporary files are removed. Archive
inspection also limits each listing to 1 MiB and each inspection or extraction command to 30 seconds.

Keep plugin content in ordinary files. Finder ZIPs are supported, but macOS metadata is unpacked as AppleDouble
sidecar files rather than restored as Finder attributes or resource forks.
