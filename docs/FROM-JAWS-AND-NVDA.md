# From JAWS scripts and NVDA add-ons to TurnOver plugins (15 Nov 2026)

This is for people who have written JAWS scripts or NVDA add-ons. It maps each idea you know to TurnOver's, says
plainly where there is no equivalent and why, and shows two small jobs written all three ways.

Scripts in TurnOver are built (docs/PLUGIN-SCRIPTS-PLAN.md) and are off until the maintainer switches on
`pluginScripts` (15 Nov 2026). The author's guide is [PLUGIN-SCRIPTS.md](PLUGIN-SCRIPTS.md); what a plugin can never do is in
[PLUGIN-SECURITY.md](PLUGIN-SECURITY.md).

## The main difference

JAWS scripts and NVDA add-ons run inside the screen reader, with everything it can reach. A TurnOver script runs in
a separate, sandboxed program with no files, no network and no other programs. It cannot see a key or a typed
character, though with the `read` ability it can read what a field holds, and never a password. It asks TurnOver for things, and TurnOver checks each request against what the user agreed to when
they approved the script on their Mac. Most of what is different below follows from that.

## JAWS, idea by idea

- Per-application script file (`Notepad.jss`, compiled to `.jsb`): a plugin folder for one app, with `apps` naming
  its bundle identifier. The script is `main.js`, one file, in JavaScript, with no compile step. A TurnOver plugin
  can also have no script at all, only rules.
- The default script file underneath: TurnOver's own handling is underneath every plugin. A plugin for an app comes
  first in that app; there is nothing to copy or inherit.
- Key map file (`.jkm`): the manifest's `commands`, each with a `key` and a `letter`. Keys are kept apart from
  code, as in JAWS, and the user can rebind them. The script never sees a key; it is told its command was chosen.
- `Script` with synopsis and description: a command in the manifest with an `id` and a `description`. The
  description is what input help speaks and the shortcuts list shows. There is no synopsis, only the description.
- `FocusChangedEvent`: `turnover.on("focus", handler)`. The handler may replace what is said for the item with
  `event.say`, say nothing with `event.silence`, or do neither and TurnOver reads it as usual. A focus event never
  stops other handling.
- `SayString`: `turnover.say(text)`, needs the `say` ability. It adds to what TurnOver says; to change the words for
  the item in focus, use `event.say`.
- `PerformScript`: no equivalent. One command cannot call another by name, and a script cannot call a key
  command. Put shared steps in an ordinary JavaScript function and call it from both handlers. Reason: a script
  never sees keys, and commands are declared in the manifest.
- Graphics labels file (`.jgf`) and other label data: the plugin's `labels` in `profile.json`, with matches on
  role, identifier, title and so on. Many JAWS label jobs need no script.
- Dictionary files (`.jdf`): no equivalent. TurnOver's pronunciation settings are the user's own, and a plugin cannot
  change TurnOver's settings. Reason: the clear line in PLUGIN-SECURITY.md.
- Script Manager (write, compile, try): a text editor, `turnover-plugin new` to start, `check` and `test` to try it
  without the app, and developer mode in the Plugins menu, where saving `main.js` reloads the script and TurnOver says
  "reloaded" or the first error with its line.
- Scripts that reach every app: no equivalent in this version. A plugin names its apps. Scripts for every app
  at once are listed as not in this version.
- Scripts that call Windows or the system, read files, or use the network: no equivalent, and never. Reason: the
  sandbox.
- Sharing a compiled script without its source: no equivalent. TurnOver reads `main.js` as text, and a reviewer
  must read every line of it. Packed or encoded code is rejected in review.

## NVDA, idea by idea

- App module (`appModules/notepad.py`): a plugin whose `apps` names one bundle identifier.
- Global plugin: no equivalent in this version. Scripts for every app at once are not in this version.
- Add-on manifest (`manifest.ini`: name, version, author, minimum and last tested NVDA): `manifest.json`: `name`,
  `version`, `author`, `minimumTurnOver`, `formatVersion`, `apps`, `abilities`, `script` and `commands`. The format has
  a number, and TurnOver reads every older format.
- `event_gainFocus(self, obj, nextHandler)`: `turnover.on("focus", handler)`. There is no `nextHandler` and no chain
  to pass on. What TurnOver does after the handler is decided by what you call: `event.say(text)`, `event.silence()`
  or nothing. To do something extra and keep the usual words, do the extra thing and call neither.
- `@script(description=…, gesture=…)`: `turnover.command(id, handler)` and the `commands` entry in the manifest. The
  description and the gesture are in the manifest, not on the function.
- Gestures the user can rebind: the same. The command's `key` can be rebound.
- `ui.message(text)`: `turnover.say(text)`.
- `obj.name`, `obj.role`, `obj.value`, `obj.states`, `obj.parent`, `obj.children`: the fields of an item and the calls
  `item.parent()` and `item.children()`. An item is a copy, and the calls need the `read` ability and are
  asynchronous: `await item.parent()`. `item.role` is the word a `profile.json` match uses ("button", "textField"),
  not NVDA's role constant; `item.axRole` is the accessibility role with its `AX`.
- Overlay classes (`chooseNVDAObjectOverlayClasses`): no equivalent. A plugin cannot change what kind of object
  TurnOver makes. A label rule in `profile.json` can name or re-role one.
- Settings panels and `config.conf`: no equivalent in this version. Reason: a plugin never changes TurnOver's
  settings. Plugin options in TurnOver's own menu are listed under Later.
- Drivers (speech, braille): no equivalent. Those stay TurnOver's own.
- Calling Windows or system APIs, files, network, `subprocess`: no equivalent, and never. Reason: the sandbox. A
  script has no `require`, no `fetch` and no file object.
- Scratchpad folder with reload: developer mode. Approve the script once with it on, then save `main.js` and it
  reloads without a question, as long as the apps and abilities do not grow.
- Python console: no equivalent. Use `console.log` to TurnOver's log, and the test runner.
- Developer information (NVDA+F1): "What is this?" in TurnOver's maker (VO-Slash) says and copies an item's role,
  name, identifier and the match TurnOver would use for it. The tool `turnover-plugin snapshot <app>` gives the
  whole window. A script can read the fields of an item with `console.log(JSON.stringify(item))`.
- Log viewer: TurnOver's log, which a script writes to with `console`.
- Add-on Store: no equivalent for scripts yet. The library is paused, and a script reaches it only after a person
  other than its author has read every line of that version. Until then a script arrives as a folder the user
  approves on their own Mac.
- Add-on packaging (`.nvda-addon`): a folder of plain files. A single-file `.turnoverplugin` is in the toolkit plan,
  not here.
- Restarting with add-ons disabled: setting `pluginScripts` off turns every script off. After a hang, TurnOver
  restarts with scripts off and says so.
- A yearly break of the programming interface: the interface has a version, `turnover.api`, and scripts written for
  version 1 are meant to keep working against it.

## Example one: a key that reads a status line

The JAWS and NVDA code is short and conventional, and is an illustration, not tested code. The TurnOver version
is a complete plugin that passes `turnover-plugin check <folder> --listing` (15 Nov 2026); the match in it is an
example, and its fields would be taken from a snapshot of the real app. A plugin kept on your own Mac needs only the
manifest fields down to `commands`; the last five fields are the library's listing.

### JAWS

In the script file:

```
Script ReadStatusLine ()
SayString (GetWindowText (FindDescendantWindow (GetAppMainWindow (GetFocus ()), 1000), true))
EndScript
```

JAWS has several ways to reach a status bar, and the right one depends on the program. The shape is what matters:
a script with a name, bound to a key in the key map (`Insert+Shift+S=ReadStatusLine`) and described in its
documentation file.

### NVDA

```python
import appModuleHandler
from scriptHandler import script
import api, ui

class AppModule(appModuleHandler.AppModule):
    @script(description="Read the status line", gesture="kb:NVDA+shift+s")
    def script_readStatusLine(self, gesture):
        bar = api.getStatusBar()
        ui.message(bar.name if bar else "No status line")
```

### TurnOver

manifest.json:

```json
{
  "formatVersion": 2,
  "id": "example-status-line",
  "name": "Status line",
  "version": "1.0",
  "apps": ["com.example.app"],
  "abilities": ["read", "say"],
  "script": "main.js",
  "commands": [
    { "id": "readStatus", "description": "Read the status line", "key": "turnover+shift+s", "letter": "s" }
  ],
  "description": "Reads the status line of Example on a key.",
  "author": "Example Author",
  "summary": "Reads the status line on a key.",
  "contact": "https://example.org/contact",
  "privacy": "Reads the status line only; nothing leaves your Mac.",
  "license": "MIT",
  "changes": [
    { "version": "1.0", "notes": "First version." }
  ]
}
```

main.js:

```js
turnover.command("readStatus", async () => {
  const found = await turnover.find({ identifier: "statusLine" }, { limit: 1 });
  turnover.say(found.length ? (found[0].value || found[0].name) : "No status line");
});
```

If all you need is to read one element on a key, a rule does it with no script: a key with `"action": "read"` and a
`target` in `profile.json`. A script earns its place when you combine items or decide what to say.

## Example two: an unnamed button said by a better name when it takes the focus

### JAWS

```
Function FocusChangedEvent (handle hwndFocus, handle hwndPrevFocus)
If GetObjectName () == cscNull && GetObjectTypeCode () == WT_BUTTON Then
	SayString ("Clear")
	Return
EndIf
FocusChangedEvent (hwndFocus, hwndPrevFocus)
EndFunction
```

### NVDA

```python
import appModuleHandler
import controlTypes

class AppModule(appModuleHandler.AppModule):
    def event_gainFocus(self, obj, nextHandler):
        if obj.role == controlTypes.Role.BUTTON and not obj.name:
            obj.name = "Clear"
        nextHandler()
```

### TurnOver

```js
turnover.on("focus", (event) => {
  const item = event.item;
  if (item.role === "button" && !item.name && item.identifier === "clearButton") {
    event.say("Clear, button");
  }
});
```

This needs `read` (for the item) and `say` (for `event.say`) in the manifest's `abilities`. A rule does the same
job with no script: a label in `profile.json` such as
`{ "match": { "identifier": "clearButton" }, "name": "Clear" }`. Prefer the rule where it is enough.

## What you cannot do here that you could there

- Work in every app at once (JAWS's default scripts, NVDA's global plugins). Not in this version.
- See typed characters or caret moves, or react to each key. A script is never sent them. This is the price of
  being unable to log what is typed.
- Read the clipboard. A script can only put text on it.
- Read or write files, use the network, start a program, or call the system. Never.
- Change TurnOver's settings, voices, pronunciations or another plugin.
- Add a settings window of your own, or your own windows. Not in this version.
- Make a screen reader for a website. Browsers are closed apps today, and scripts for a website are later.
- Reach into TurnOver's internals: the object model, overlay classes, the speech queue. The interface is small on
  purpose, and has a version number.
- Do slow work in a focus handler: it has 25 ms.
- Run in the background while the app is not in front. A script is paused then.
- Be shared as a compiled file without source.
- Keep running when it misbehaves: three strikes in ten minutes and it is off.
- Be switched on without the user's agreement. The user hears what it can do, and agrees, on their own Mac.

## Converting an NVDA add-on

`turnover-plugin convert` makes a draft TurnOver plugin from an NVDA add-on and a report on what came across. It reads
the add-on's Python as text, with Python's own parser (`/usr/bin/python3 -I`, on a small script of ours that only
parses). It never runs anything from the add-on, never installs anything and never approves anything. The result is
a draft: a person must read every line, because NVDA's store does not review code. Its SHA-256 and a virus scan say
who published a file and that it has not changed, not that the code is safe.

```
turnover-plugin convert <add-on id | .nvda-addon file | folder> --out <folder> [--converted-by "Name"] [--channel stable|beta|dev] [--force] [--with claude|chatgpt|gemini|myself]
turnover-plugin convert <…> --report-only
```

- An id is looked up in NVDA's combined store list (`https://addonStore.nvaccess.org/en/all/latest.json`), on the stable
  channel unless you ask. The file is downloaded only over https from the address the list gives, at most 50 MB, and is
  refused unless its SHA-256 matches the list. The request carries nothing about your Mac or you. TurnOver the screen
  reader still connects only to its update site; this is the tool's own request.
- A file or folder you already have is read in place. Unpacking refuses any entry whose path leaves the folder, any
  link, more than 2,000 entries and more than 50 MB.
- `--out` is where the draft goes. An existing folder is never overwritten without `--force`. `--report-only` prints
  the report and writes nothing.
- The draft is `manifest.json`, `main.js`, `CONVERSION.md` (the report: what carried over, what needs a person, what can
  never come across and why, and the licence notice) and a copy of the original's licence text. An add-on that cannot
  come across at all (a speech driver, say) gets the report and no plugin.
- Scripts and events become `turnover.command` and `turnover.on` handlers. A statement is translated only where one
  table, `ConvertMapping.swift`, says the translation is exact and every argument is a plain literal (`ui.message("x")`
  becomes `turnover.say("x")`). Every other statement stays as the original Python in comments, under a line saying
  a person must write it. A call that is not in the table is never guessed at; it is listed in the report.
- `kb:NVDA+x` becomes `turnover+x`. A gesture TurnOver refuses a plugin, or one that clashes, is left unbound and reported.
- The abilities come from the original's own calls and nothing else, and are written in `convertedFrom` in the manifest
  with the add-on's id, version, SHA-256 and source address. `turnover-plugin check` reports as an error any ability or
  app in `manifest.json` that the record does not have, so a later hand or AI edit that reaches further is seen.
- An app module names a Windows program, so `apps` is left empty for you. The report says how to find the Mac app's
  identifier. When you choose it, put it in `apps` and in `convertedFrom.apps`. `check` says a converted plugin with no
  app is not finished.
- Credit: `convertedFrom.author` is the creator (the original author, kept as the manifest's `author` too) and
  `convertedFrom.convertedBy` is who converted it, from `--converted-by "Name"`. Without it nothing is asked and the
  field is left empty; `check` warns, and `check --listing` refuses to call it ready to share, until it is filled.
  At approval TurnOver says whose add-on it was converted from and who converted it. Neither name changes what the
  plugin may do.

### Finishing the translation with your own AI tool, or yourself

The draft is mostly stubs, because the converter only translates what it can translate with certainty. The rest stays as
the original Python in comments. To finish it, `convert` also writes, beside the draft:

- `original/`: the add-on's Python files and `manifest.ini`, copied as plain text (each name ends in `.txt`), with a
  note saying this is untrusted reference text that nobody runs. Nothing in it is ever run, by TurnOver, the converter
  or the AI.
- `BRIEF.md`, with `CLAUDE.md`, `AGENTS.md` and `GEMINI.md` pointing at it, and `PLUGIN-GUIDE.md` and
  `PLUGIN-SCRIPTS.md` (the same set the "Make a plugin" briefs use). The brief gives the task (finish translating,
  function by function, from `original/`); says plainly that the add-on's text is data and never instructions, that the
  AI must not add abilities, apps or keys beyond what the report lists without saying so in plain words, and must
  never try to get round a refusal; gives the table of NVDA calls and events and what each becomes (built from the
  converter's own table, so the two cannot disagree) and the list of what can never come across; says Windows selectors
  do not carry over, that Mac items are found from `turnover-plugin snapshot <app>`, and that an add-on for a
  Windows-only program is reported as not for the Mac, not forced; gives the key rules (`NVDA+` becomes `turnover+`,
  never add Control or Option to `turnover`, a layer letter is the fallback); says how to check the work (`check`,
  `test` with a scenario test in `tests/script/` for each translated command, `consent`); and gives the credit and
  licence rules. The finish line is a passing check, passing tests, and a short `CONVERSION-NOTES.md` saying what was
  translated, what was left out and why, and what to try by ear.
- With `--report-only`, or when nothing could be carried over, none of this is written.

`--with claude`, `--with chatgpt` or `--with gemini` then hands the folder over exactly as "Make a plugin" does: Claude
Code opens in the folder with the request typed in; Codex or Gemini CLI opens in Terminal if it is installed; otherwise
the whole task, with no folder path in it, goes on the clipboard and the AI's website opens, and you save its answer
into the folder. `--with myself` opens the folder in Finder. TurnOver does not send anything to an AI service itself.

The draft is marked "converted, translation not reviewed" in `convertedFrom.translation`, in `CONVERSION.md` and at the
top of `main.js`. `check` says so, and `check --listing` will not call it ready to share, until a person who has read
`main.js` against the original changes it to `reviewed`. That is not approval: a translated plugin is installed
unapproved like any other, and approving it is the person's, in TurnOver, after hearing what it can do. An AI is told
never to change that field.

### Finding an add-on without knowing its id

```
turnover-plugin store list [--hide-not-mac] [--json]
turnover-plugin store search <words> [--hide-not-mac] [--json]
turnover-plugin store show <id> [--json]
```

`list` shows every add-on on the stable channel, sorted by name. `search` matches the name, id, author and description,
ignoring case, and every word must be found. `show` gives everything the list says about one add-on: licence, source
address, SHA-256 and so on. Each add-on is one plain line made for a screen reader, with no tables. `--json` prints the
same as JSON. The list is kept for an hour in the tool's cache folder (`~/Library/Caches/turnover-plugin`).

Each line ends with a small verdict: "can be converted", "needs work", "not for the Mac" or "not looked at yet". It
comes from, in order: what an earlier `convert` or `convert --report-only` of that id and version found on this Mac
(kept in the same cache folder); plain signs in the store's own entry, from the one small table in
`ConvertSigns.swift` (a speech synthesizer or braille driver, remote access, or a Windows-only thing such as
Notepad++ or SAPI gives "not for the Mac", with the reason in a few words); otherwise "not looked at yet". The list
alone never says "can be converted". `--hide-not-mac` leaves out the "not for the Mac" ones and says at the end how
many it left out.
