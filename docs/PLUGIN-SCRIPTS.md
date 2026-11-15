# Plugin scripts: the author's guide (15 Nov 2026)

This guide is for people who write TurnOver plugins that need a script. It says what a script is, how to write a
first one, every part of the interface, what the user is asked to agree to, and what gets a script turned off.

Status (15 Nov 2026): scripts are built and are off. They run only when the maintainer has switched them on with
`defaults write com.turnover.reader pluginScripts -bool true` (and plugins themselves are not switched off). Until
then every script is ignored and plugins stay data, as docs/DECISIONS.md says. The engine, the format, the tool,
approval and the keeper that holds approvals are in the code, with tests. Where the code and docs/PLUGIN-SCRIPTS-PLAN.md
differ, this guide follows the code and says so.

Related documents:
- [PLUGIN-GUIDE.md](../PLUGIN-GUIDE.md): the format for plugins made of rules, which every script plugin also uses.
- [PLUGIN-SECURITY.md](PLUGIN-SECURITY.md): what a plugin can never do, the threats, and the reviewer's checklist.
- [FROM-JAWS-AND-NVDA.md](FROM-JAWS-AND-NVDA.md): for people who have written JAWS scripts or NVDA add-ons.
- [turnover.d.ts](../Resources/plugin-schema/turnover.d.ts): TypeScript declarations of the interface, for editors
  and AI assistants.

## When rules are enough, and when you need a script

A plugin without a script is a folder of rules: labels, keys, watches, silence and holds, in `profile.json`. Rules
cannot make a decision. Start with rules, and add a script only when the answer to one of these is yes.

Rules are enough when you want to:
- name a control that has no name, or the wrong one;
- give a control a key that presses it, focuses it or reads it;
- choose a menu item with a key, or send a key to the app;
- read an element whenever its value changes;
- keep quiet about an element.

You need a script when you want to:
- say different words depending on what the item is or what it holds (turn "3 of 9" into "page 3", say a changed
  total only when it really changed);
- combine several items into one sentence (a status line made of three labels);
- do one thing, look at the result, and then do another;
- remember something between events (the last value said, a count);
- run a command that cannot be written as one press, one menu item or one key.

A plugin with a script is still a folder of plain files, and it can still have a `profile.json`. A script never
replaces the rules; it sits beside them.

## A first script

This is the sample plugin, `plugins/examples/sample-script-calculator`. It does two things in Calculator: a command
that reads the result, and a name for the Clear button when it takes the focus.

### 1. Start the folder

```
turnover-plugin new <folder> --app com.apple.calculator --script
```

This makes `manifest.json`, `profile.json`, `main.js` and `tests/script/first.json`, a working plugin with comments
that teach. The folder must be new or empty. `--app` takes a bundle identifier, not a name. Without `--script` it
makes a plugin of rules only. You can also make the files by hand, as below.

### 2. Write manifest.json

```json
{
  "formatVersion": 2,
  "id": "sample-script-calculator",
  "name": "Calculator, scripted",
  "version": "1.0",
  "author": "TurnOver",
  "description": "Says what the Calculator's Clear button is, and reads the result aloud on a key.",
  "apps": ["com.apple.calculator"],
  "abilities": ["read", "say"],
  "script": "main.js",
  "commands": [
    { "id": "readResult", "description": "Read the result", "key": "turnover+control+shift+r", "letter": "r" }
  ],
  "summary": "Reads Calculator's result on a key, and names its Clear button.",
  "contact": "https://github.com/TurnOver-For-Mac/turnover/issues",
  "privacy": "Reads Calculator's window only; nothing leaves your Mac.",
  "license": "MIT",
  "changes": [
    { "version": "1.0", "notes": "First version: the readResult command and a name for the Clear button." }
  ]
}
```

What matters here:
- `formatVersion` must be 2 for a plugin with a script. Everything valid in format 1 is still valid. Format 2 is the
  newest this TurnOver reads. `turnover-plugin new` without `--script` still writes format 1, so a plugin of rules
  stays readable by older builds.
- `script` must be `"main.js"`. There is one script file, and no other name. It is UTF-8 text of at most 256 KB.
- `apps` lists bundle identifiers by name. A plugin with a script cannot use a wildcard.
- `abilities` is the list of things the script may ask for, and a script needs at least one. It is enforced, not
  just described: a request for anything not listed is refused. Ask for as little as you can, because the user is
  asked to agree to each one.
- `commands` is where the script's commands are declared, not in the code. TurnOver reads the list without running
  anything, checks each key against its policy and against other plugins, and lets the user rebind the key. The
  script never sees a key. It is told that its command was chosen. A command's `id` is letters and digits only,
  and it needs a `description`, which input help reads. `key` and `letter` are optional.
- `description` is the sentence the user hears at approval, marked as your words.
- The last five fields (`summary`, `contact`, `privacy`, `license`, `changes`) are the listing. A plugin that stays
  on your own Mac does not need them; `turnover-plugin check <folder> --listing` asks for them.
- `profile.json` is optional for a plugin with a script. The sample has one, with a label for the equals button.

### 3. Write main.js

```js
// main.js: the script for "Calculator, scripted".
//
// The script runs in a sandbox, apart from TurnOver. It cannot use the internet, files or other programs. It can only
// ask TurnOver, through `turnover`, for what manifest.json's "abilities" lists ("read" and "say" here), and TurnOver
// checks every request. Try it without Calculator: `turnover-plugin test <this folder>` runs tests/script/*.json.

// An event. TurnOver tells the script when the focus lands on an item. The words are decided before the handler
// returns, from the item it was given: event.say replaces what TurnOver would say for this item, event.silence says
// nothing, and doing neither leaves TurnOver to read the item as usual. (Both need the "say" ability.)
turnover.on("focus", function (event) {
  const item = event.item;
  if (item.role === "button" && item.name === "" && item.identifier === "clear") {
    event.say("Clear, button");
  }
});

// A command. "readResult" is declared in manifest.json, with its key; the script is only told it was chosen.
// The handler may be `async`: `await` waits for TurnOver's answer (this one needs "read").
turnover.command("readResult", async function (context) {
  // turnover.find takes the same match object as profile.json's rules, and answers with a list of items, empty if
  // nothing matched. Each item is a copy of what was true a moment ago.
  const found = await turnover.find({ role: "text", identifier: "result" }, { limit: 1 });
  if (found.length === 0) {
    turnover.say("There is no result to read");
    return;
  }
  // turnover.say adds to what TurnOver says; it does not replace anything. (It needs "say".)
  turnover.say(String(found[0].value));
});
```

The match is an example. Take the real identifiers from `turnover-plugin snapshot com.apple.calculator`.

### 4. Check it, hear what the user will hear, and test it

```
turnover-plugin check <folder> --listing
turnover-plugin consent <folder>
turnover-plugin test <folder>
```

The tool is described in the next section. For a plugin with a script, `check` loads `main.js` in the real sandboxed
program and reports a syntax error with its line, commands declared in the manifest but never handled, commands
handled but not declared, and a focus or value handler in a plugin without `read`. It also warns when the script's
words suggest an ability the manifest does not ask for. That last part is a guess from the text.

### 5. Try it in TurnOver

1. Switch scripts on, as the status paragraph says, and restart TurnOver.
2. Install the folder: `turnover-plugin install <folder>`. Installing copies the files and never approves the script.
3. Turn on Developer mode for scripts in the Plugins menu, so that saving `main.js` reloads it. "How approval works"
   below says what it does.
4. Bring Calculator to the front. TurnOver says that the plugin has a script waiting for approval. Open the Plugins
   menu, choose "Calculator, scripted, script waiting for approval", listen, and choose Approve.
5. Edit `main.js` and save. In developer mode TurnOver reloads it and says "reloaded", or says the first error with
   its line.

## The tool

`turnover-plugin` is the plugin maker's tool. These are the commands that matter for scripts. Each prints plain text
and exits with a non-zero status when something needs fixing.

- `turnover-plugin new <new folder> --app <bundle id> [--script]`: a working plugin to start from.
- `turnover-plugin check <plugin folder> [--read] [--listing] [--level Community|Verified|Official]`: checks the
  plugin. With `--listing` it checks only the manifest, the keys and the script, and needs no running app: this is the
  form to use for a script. Without it the tool also checks the plugin against the app, which must be running. `--read` shows web content as TurnOver reads it. `--level` checks against the
  library rules of that level.
- `turnover-plugin consent <plugin folder>`: prints what TurnOver will say when the person is asked to approve the
  script, word for word, then the plugin's hash and, if it is signed, the signing key's fingerprint.
- `turnover-plugin test <plugin folder>`: runs the plugin's tests. For a script that is every file in `tests/script/`,
  run in the real sandboxed program with no app and no permissions. It prints `ok` or `FAIL` for each test and a
  count, and exits non-zero if any failed.
- `turnover-plugin keygen [--force]`: makes your signing key. It is never replaced unless you give `--force`.
- `turnover-plugin sign <plugin folder>`: writes `signature.json` over the plugin's hash, with your key.
- `turnover-plugin verify <plugin folder>`: prints the plugin's hash and the signing key's fingerprint, and whether the
  signature holds. It exits non-zero when the plugin is not signed or the signature does not hold.
- `turnover-plugin install <plugin folder> [--confirm]`: copies a checked plugin into TurnOver's plugins folder. It
  copies `main.js` and never approves it. A plugin that sends keys or chooses menu items needs `--confirm`.

`new`, `consent`, `keygen`, `sign` and `verify` read no app and need no permission. The other commands need
Accessibility permission for the app the tool runs in, even `test` and `check --listing`, which look at no app.
`check` and `test` need the script program, `turnover-plugin-host`, beside the tool or in
`../Helpers` when the tool runs from inside TurnOver.app.

Your signing key is the file `~/.turnover-plugin/author.key`, readable only by you (its folder allows only you in).
The tool refuses a key other people on the Mac can read. Keep it: anyone who has it can sign as you. Replacing it
loses the old one.

## The interface, version 1

A script sees one object, `turnover`, plus `console` and timers. Nothing else exists: no `fetch`, no `require`, no
file or process objects. The interface has a version number. `turnover.api` is 1, and scripts written for version 1
are meant to keep working against it. `turnover.d.ts` declares all of it for an editor.

Every call that needs an ability says which. A request without its ability rejects with an error that names the
ability to add to `abilities`. Calls that ask TurnOver for something return a promise; use `await`.

### Facts

```js
turnover.plugin     // { id, name, version }: this plugin's own manifest fields
turnover.api        // 1
turnover.language   // "en"
```
No ability. They are read-only.

### turnover.on(name, handler)

Registers a handler for an event. No ability is needed to listen. The events are `"focus"`, `"valueChange"`,
`"appFocus"`, `"appBlur"` and `"windowChange"`; any other name throws. A second call for the same event replaces the
first handler. They are described under "Events".

```js
turnover.on("appFocus", () => { turnover.say("Calculator"); });
```

### turnover.command(id, handler)

Registers the handler for a command declared in `manifest.json`. An id that is not declared throws. No ability is
needed to be called; what the handler does needs its own abilities. The handler is given `context`, described under
"Commands".

```js
turnover.command("readResult", async (context) => { /* … */ });
```

### turnover.say(text, { interrupt })

Ability: `say`. Speaks `text`. `interrupt` (true or false) says whether to cut off what is being said. It is not a
request that waits for an answer. A script may say 20 things in two seconds; a text longer than 500 characters is cut
to 500. What is said while none of the plugin's apps is in front, or while a TurnOver approval question is open, is
dropped without an error.

```js
turnover.say("Saved", { interrupt: false });
```

### turnover.sound(name)

Ability: `say`. Plays one of TurnOver's own sounds, by its file name without `.wav`. The script cannot supply a sound
of its own. The names this TurnOver has (15 Nov 2026, the files in `Resources/Sounds`) are: announcement, blockquote,
braille_off, braille_on, browse_mode, comment, done, drill_in, drill_out, edge, empty, focus_mode, graphic, hand_back,
heading1 to heading6, landmark, link, list, marked, page_loaded, popup, press, quicknav_off, quicknav_on, secure,
spelling, startup, table, take_over, tick, tracking_off and tracking_on. A name TurnOver does not have is written to
the log and nothing plays. It does not reject. A sound counts toward the same 20 in two seconds as speech, and is
dropped under the same conditions.

### await turnover.focused()

Ability: `read`. The item with the keyboard focus, or `null`. It is only an item in one of the plugin's own apps.

```js
const item = await turnover.focused();
if (item) turnover.say(item.name);
```

### await turnover.find(match, { limit })

Ability: `read`. Finds items in the plugin's app: the one in front, or else a running one of its apps. `match` is the
same match object `profile.json` uses (see "Matching elements" in PLUGIN-GUIDE.md): `role`, `roles`, `subrole`,
`identifier`, `title`, `description`, `help`, `value`, `text`, `window`, `inside`, `parent`, `unnamed`, `pressable`,
`nth` and `any`. Leave it out to match anything. `limit` is the most to return, and TurnOver never gives more than
50. A search may take 150 ms, so a slow app costs the script its turn. The result is a list of items, empty when
nothing matched. A match TurnOver cannot read rejects.

```js
const buttons = await turnover.find({ role: "button", unnamed: true }, { limit: 10 });
```

### await turnover.menu(path)

Ability: `menu`. Chooses a command from the app's menus. `path` is a list of at most eight menu names. It resolves
with `true`. PluginPolicy's refusals apply when the request is made: the Apple menu, a first menu given as a pattern,
and Paste, Log Out, Lock Screen, Restart, Shut Down, Sleep, Force Quit, System Settings and Services are never chosen.
A path that finds no menu item rejects.

```js
await turnover.menu(["Edit", "Copy"]);
```

### await turnover.keys(combination)

Ability: `keys`. Sends a key press to the plugin's app, written as TurnOver writes keys (`command+k`). It resolves
with `null`. The refusals for sent keys apply when the request is made: nothing that leaves the app (Command Tab,
Spotlight, Spaces, screenshots and others), nothing with TurnOver's own keys, and no Paste.

```js
await turnover.keys("command+k");
```

### await turnover.copy(text)

Ability: `clipboard`. Puts text on the clipboard. A script can never read the clipboard.

```js
await turnover.copy("g-code exported");
```

### turnover.storage

`await turnover.storage.get(key)`, `await turnover.storage.set(key, value)` and `await turnover.storage.remove(key)`.
No ability is needed. A value is anything JSON can hold. `get` gives `null` when nothing is stored under the key. A
key is at most 200 characters, and a plugin may keep 256 KB in all. The data is one plain file for the plugin,
`plugin-data/<id>.json` in TurnOver's support folder, which other programs running as the person can read. Do not
store what the script reads from an app unless the person would expect that.

```js
const count = (await turnover.storage.get("count")) || 0;
await turnover.storage.set("count", count + 1);
```

### Timers and the log

`setTimeout`, `clearTimeout`, `setInterval` and `clearInterval` exist. A script may have 20 timers at once (one more
throws), and none runs faster than 50 ms (a shorter delay is made 50). Timers do not run while none of the plugin's
apps is in front.

`console.log`, `console.warn` and `console.error` write to TurnOver's log. They are the way to see what a script is
doing.

### Items

An item is a copy of what was true when TurnOver made it, plus a handle TurnOver can use to ask for more. The fields
do not change after the item is made; call `refresh()` for a fresh copy.

Fields (no ability is needed to look at an item you were given; the ability was needed to get it). Each is text,
empty when the app gave nothing, never `null`:
- `item.role`: the word a `profile.json` match uses for the role: the accessibility role without its `AX`, first
  letter small, such as `"button"` or `"textField"`. This is the word to compare with.
- `item.axRole`: the accessibility role, with its AX prefix.
- `item.subrole`
- `item.name`: the title, or the description when there is no title. At most 1,000 characters.
- `item.value`: at most 8,000 characters. A number is given as text.
- `item.description`
- `item.help`: the tooltip.
- `item.identifier`: the app's own identifier, the steadiest thing to match on.
- `item.states`: a list of words: `"focused"`, `"selected"`, `"disabled"`, `"expanded"`, `"collapsed"`, `"checked"`
  and `"mixed"`.
- `item.window`: the title of the window the item is in.
- `item.secure`: true for a password field. Its `value` is always blank to a plugin.

Methods:

```js
await item.refresh()     // ability read: a fresh copy, or null if the item has gone
await item.parent()      // ability read: the parent, or null
await item.children()    // ability read: the first 200
await item.read()        // abilities read and say: TurnOver speaks it its own way; never a password field
await item.press()       // ability press: true
await item.focus()       // ability focus: true
await item.setValue(v)   // ability edit: true; v is a string or a number
```

A handle the plugin was not given, or a handle for an item in another app, rejects. TurnOver keeps the last 512
handles it gave a plugin, so a very old item rejects too; ask for a fresh one. `press`, `focus`, `setValue`, `menu`
and `keys` work only while one of the plugin's apps is in front, by TurnOver's idea of the focus and by the Mac's own
frontmost app both; otherwise they reject. `setValue` and `keys` are also refused while the Mac hides what is typed
(secure keyboard entry), while a password field has the focus, and when TurnOver cannot tell what has the focus.

```js
const fresh = await item.refresh();
if (fresh && fresh.value !== item.value) turnover.say("Changed to " + fresh.value);
await (await turnover.find({ role: "button", identifier: "Save" }, { limit: 1 }))[0].press();
```

### Events

An event handler receives one object, `event`.

- `focus`: `event.item` is the item that took the focus. Call `event.say(text)` to give TurnOver other words for it,
  `event.silence()` to say nothing, or neither, and TurnOver reads it as usual. The handler must decide before it
  returns or reaches its first `await`: nothing after an `await` can change the words, and `event.say` then throws.
  To add to what is said, use `turnover.say`. The words replace what TurnOver would have announced for that focus;
  the usual hint still follows words a script gave, and nothing follows a silence. The same words twice within half a
  second are said once, as TurnOver's own are. Everything else TurnOver does on a focus still happens (password echo,
  settings panes, text fields), and a focus handler never stops the chain.
- `valueChange`: `event.item`, with the same `say` and `silence`. A value change the script handles stops the chain,
  as a watch rule does today. A value change in a password field is never sent to any script.
- `appFocus`, `appBlur`, `windowChange`: you are told, and there is nothing to replace. `event.say` and
  `event.silence` throw there.

A focus or value event carries the item, so TurnOver sends them only to a plugin that has the `read` ability. A
plugin without it is sent neither, and `turnover-plugin check` says so. `appFocus`, `appBlur` and `windowChange`
need no ability.

Never sent: typed characters, caret moves, anything from an app the plugin did not name.

A script has 25 ms to answer a focus or value event, so keep those handlers short and do the thinking before an
`await`, or not at all. The plan says `event.say` and `event.silence` need the `say` ability. The code does not check
this when the handler answers (15 Nov 2026); `turnover-plugin check` warns when `say` is missing and the approval
sentence for `say` covers changing or silencing what TurnOver says, so ask for `say` whenever the script does either.

### Commands

When the user chooses a command, the script's handler for that id is called with one argument, `context`.
`context.item` is the item with the keyboard focus when the command was chosen, if the plugin has `read`; otherwise it
is `null`. A command has five seconds to finish. If it fails, the person hears "<name> could not do that."; in
developer mode they hear the script's own error.

## Abilities

An ability is a thing the script may ask TurnOver to do. A script asks for the ones it needs in `abilities`. The
user hears them, in TurnOver's words, before the script runs, and TurnOver refuses any request outside them. The
abilities in force are the manifest's together with those the plugin's `profile.json` rules imply (a key that presses
needs `press`, a label needs `read`, a silence, a watch or a key that reads needs `say` as well), because the profile and
the script share one approval. Until the script may run, none of the profile is live either (16 Nov 2026).

`read`, `say`, `press`, `focus`, `menu` and `keys` are the six abilities that data plugins already name. `edit` and
`clipboard` are new with scripts.

What the user hears for each, taken from the code on 15 Nov 2026 (`turnover-plugin consent` prints them for your
plugin):

- `read`: "It can read what is on the screen in those apps, including text you have typed there, but never a
  password."
- `say`: "It can speak, change or silence what TurnOver says in those apps, and play TurnOver's own sounds."
- `press`: "It can press buttons and other controls in those apps."
- `focus`: "It can move the keyboard focus to an item in those apps."
- `menu`: "It can choose commands from those apps' menus."
- `keys`: "It can press keys in those apps for you."
- `edit`: "It can change the text or value of a field in those apps."
- `clipboard`: "It can put text on the clipboard. It cannot read what is on it."

`item.read()` needs both `read` and `say`, because it reads the item and speaks it.

## How approval works

A script runs only if TurnOver holds a receipt for it on this Mac. Nothing a plugin says about itself replaces that.

- The receipt records the plugin's id, the SHA-256 of its files, its apps and its abilities, when it was approved,
  where the script came from, and the signing key's fingerprint if the plugin was signed. The files that count are
  `manifest.json`, `profile.json` if there is one, and `main.js`. `signature.json` and `tests/` do not count.
- The receipts are kept by the keeper: a small sandboxed service inside TurnOver.app that answers only the signed
  TurnOver and keeps the receipts where no other program can write them. PLUGIN-SECURITY.md says what that protects
  against. A developer build of TurnOver, which may be signed ad hoc, keeps them instead in `plugin-trust.json` in
  TurnOver's support folder, sealed with a key in a file beside it, and says so in the log. If the keeper cannot be
  reached, no script is approved in that run and none can be, and the rest of TurnOver works as usual.
- A script with no receipt, or whose files have changed, does not start. TurnOver says, when one of its apps comes to
  the front, "<name> has a script waiting for approval. It will not run until you approve it in the Plugins menu."
  That is said once for a plugin and at most three times in a run. In the Plugins menu the plugin is listed as
  "<name>, script waiting for approval". If you choose a command of a script that is waiting, TurnOver says
  "<name> is waiting for approval in the Plugins menu."
- Choosing that menu item asks the question. TurnOver speaks the sentences below, then "Approve it?", and offers "Not
  now" first and "Approve" second, so a hurried Return cannot approve. No script is heard while the question is open.
  After approval it says "<name> script is on." and the menu lists "<name>, script on". Choosing that item turns the
  script off and takes the approval away.
- A changed script needs approving again, including a new version of someone else's plugin.
- If the plugin was signed, TurnOver says the signing key's fingerprint at approval and keeps it in the receipt.

What the person hears, in order, for the sample plugin (the sentences are TurnOver's own, except the author's
description):
1. "Calculator, scripted has a script. It works only in Calculator, and does nothing while you are in another app."
   (With several apps: "It works only in these apps: A and B, and does nothing while you are in another app.")
2. "The author's own words about it: Says what the Calculator's Clear button is, and reads the result aloud on a key."
   (With no description: "The author gave no description of what it is for.")
3. One sentence for each ability, as under "Abilities". With none: "It asks to do nothing in those apps. It can only
   think and keep its own notes."
4. "It can never use the internet, read or change your files, see the keys you press, see a password, or reach any
   other app."
5. For an app where a plugin can do more harm (passwords, settings, terminals, browsers), where a script can only read
   and speak: "In <the apps> it can only read and speak: passwords, settings, terminals and browsers are like this. It
   can never press, type or choose anything there, whatever else it is allowed to do."
6. If signed: "It is signed with the key <fingerprint>. That says who made it, not that it is safe." If the signature
   does not fit the files: "It has a signature, but the signature does not match its files, so the files were
   changed after it was signed."
7. "Nobody has checked this script. Approve it only if you wrote it or trust the person who did." (Said for every
   script that does not come from the reviewed library, which is every script today.)

### Developer mode

Developer mode is a switch in the Plugins menu, "Developer mode for scripts". It is kept with the receipts. With it on,
a draft's receipt holds as long as the plugin's apps and abilities do not grow. Saving `main.js` reloads the script
without a question, and TurnOver says "<name> script reloaded.", or the first error with its line. If you add an app or
an ability, the script waits for approval again.

A receipt is a draft's only if developer mode was on when it was approved. Any other receipt is for exactly the files
approved, whatever developer mode is later. So turning developer mode on does not loosen a script you approved
earlier; approve it again with developer mode on to make it a draft.

When you turn it on, TurnOver says: "Developer mode for scripts is on. A script you approve now keeps running when you
save changes to it, as long as it asks for no more apps or abilities. TurnOver says so each time it starts." Developer
mode is for your own Mac while you write; do not leave it on for a plugin you did not write.

### What TurnOver says at start-up

A moment after it starts reading, TurnOver says how many scripts may run, and that developer mode is on if it is, so
that an approval the person never gave is heard: "1 plugin script is on." or "<number> plugin scripts are on.", and
"Developer mode for scripts is on." It says nothing when no script may run and developer mode is off. After a
watchdog restart it says "TurnOver started again after it stopped responding, so plugin scripts are off until it
starts again."

## The limits: what gets a script turned off

All the limits are in one file, ScriptLimits.swift, with the reason beside each.

Slow answers and starting:
- 25 ms to answer a focus or value event. If you are late, TurnOver says what it would have said without you, and
  sends that script no further event until it answers. A late answer is a strike.
- 3 seconds to start.
- 5 seconds for a command to finish, or for an event to be answered at all. After that the script's program is
  killed, which is a strike.

Greed:
- 128 MB of memory, or more than half a processor for ten seconds: killed.
- 100 requests a second, and 150 ms of TurnOver's main thread in any second: further requests are refused.
- 20 things said in two seconds, 500 characters each (replacement words for an event and `item.read` count too; silence
  does not).
- 20 timers, none faster than 50 ms.
- 500 lines a second from the host program; more are thrown away unread, and a host that keeps it up is stopped. At
  most 64 requests waiting for TurnOver's main thread. While the script is paused, everything but its log and its own
  stored data is refused.
- A `*` pattern in a match is at most 200 characters and is compared with at most 10,000.
- 256 KB for the script, 256 KB for a message, and 256 KB for the plugin's stored data.

Strikes:
- A kill, a crash or a late answer is a strike. Three strikes in ten minutes turn the script off for this run of
  TurnOver, and TurnOver says so once, by name: "The script of <name> kept going wrong, so it is turned off until
  TurnOver starts again. You can turn it on again in the Plugins menu." The menu then lists "<name>, script turned off
  after problems".
- A script that fails to load (a syntax error, say) is not started again until its files change, and TurnOver says
  once: "The script of <name> did not load." followed by the first error with its line.

When no scripts run at all:
- `pluginScripts` is off.
- The watchdog has just restarted TurnOver after a hang (`--after-hang`). Scripts stay off for that run and TurnOver
  says so.
- The sandbox cannot be applied to the script's program. Then TurnOver runs no scripts.
- While a TurnOver approval question is open, no script is heard.

A script is started when one of its apps first comes to the front, ended when all of its apps have quit, and
paused (no events, no timers) while none of its apps is in front.

## Testing a script

A script's tests live in `tests/script/*.json` in the plugin folder. `turnover-plugin test` runs them in the real
sandboxed script program, with no app and no permissions. A file holds one test in `{ }` or a list of tests in
`[ ]`. Comments and trailing commas are allowed, as in the plugin's other files.

A test starts the script fresh, and runs its `steps` in order. The script's own memory, and `turnover.storage`, which the
runner keeps in memory, carry from one step to the next. Each step is one of:
- `"event"`: one of `focus`, `valueChange`, `appFocus`, `appBlur`, `windowChange`. `"item"` is the item the event
  carries: an object with whatever the script reads (`role`, `name`, `value`, `identifier`, `states`).
- `"command"`: one of the commands in `manifest.json`. `"item"` is optional: it is `context.item`.

and may have:
- `"answers"`: what TurnOver answers when the script asks for something in this step, by operation: `focused`,
  `find`, `item.refresh`, `item.parent`, `item.children`, `item.read`, `item.press`, `item.focus`, `item.setValue`,
  `menu`, `keys`, `copy`. The answer is the JSON the script gets back. An item, or a list of them, is written like the
  step's `"item"`. `{"error": "…"}` makes the request fail with that message. The same answer serves every time the
  script asks in that step. A question with no answer fails the test and says which. `turnover.storage` needs no
  answer.
- `"expect"`: `"say"` is what the event's answer was, for `focus` and `valueChange`: the words, `""` for silence, or
  `null` for neither (TurnOver would read as usual). `"said"` is the list of what `turnover.say` was called with in this
  step, in order. `"error"`, for a command, is some words its failure message must contain; leave it out and the
  command must finish without an error. A key you leave out is not checked.

Requests are ability-checked as in TurnOver, against the abilities the plugin really has, so a script that asks for
more than its manifest says fails here as it would there.

This is the sample plugin's own test, `tests/script/read-result.json`, in full:

```json
// A test with no app: each step gives the script an event or a command, the item it carries, and the answers TurnOver
// would give to what the script asks. "expect" is what must come out. (More in Sources/PluginTestKit/ScriptScenarioRunner.swift.)
{
  "name": "reads the result",
  "steps": [
    // "say" is what the focus event's answer was: words, "" for silence, null for TurnOver's own reading.
    { "event": "focus", "item": { "role": "button", "name": "", "identifier": "clear" },
      "expect": { "say": "Clear, button" } },
    { "event": "focus", "item": { "role": "button", "name": "Seven", "identifier": "seven" },
      "expect": { "say": null } },
    // "answers" gives the reply to each request the script makes in this step; "said" is what turnover.say spoke.
    { "command": "readResult",
      "answers": { "find": [ { "role": "text", "value": "42", "identifier": "result" } ] },
      "expect": { "said": ["42"] } },
    { "command": "readResult",
      "answers": { "find": [] },
      "expect": { "said": ["There is no result to read"] } }
  ]
}
```

Run `turnover-plugin test` on the folder. Each test prints `ok` or `FAIL` with the reason, and the last line counts them.
Rules in `tests/expect.json` still work for the plugin's profile, as PLUGIN-GUIDE.md and docs/PLUGIN-TOOLKIT-PLAN.md
describe; a plugin with only script tests needs no recorded screens.

Tests do not count toward the plugin's hash, so you can change them without a new approval. A reviewer is meant to
run them (see PLUGIN-SECURITY.md).

## Signing

Signing is optional. It lets a user, and a reviewer, know that a version came from the holder of one key and has
not been changed since.

```
turnover-plugin keygen
turnover-plugin sign <folder>
turnover-plugin verify <folder>
```

- `keygen` makes an Ed25519 key for you at `~/.turnover-plugin/author.key`, readable only by you, and prints its
  fingerprint. It will not replace a key that exists unless you give `--force`, because the old key would be lost.
- `sign` writes `signature.json` over the same SHA-256 the receipt uses (the hash over `manifest.json`,
  `profile.json` if present, and `main.js`). Sign again after every change to those three files.
- `verify` prints the hash and the signing key's fingerprint, and says whether the signature holds. The hash and the
  fingerprint are what a reviewer records.
- `signature.json` is `{"format": 1, "key": "<the public key, base64>", "signature": "<base64>"}`. The signature is
  Ed25519 over the 32 raw bytes of the hash, not its hex text, so a tool in any language need only hash the files and
  verify. The fingerprint is the first 16 hex digits of the SHA-256 of the public key, in groups of four.

A signature says who, not whether the script is safe. Approval still comes first, and the library (when it returns)
takes a script only after a person other than its author has reviewed that exact version.

## Troubleshooting

### The script does not start

Check, in this order:
1. Is `pluginScripts` switched on? If not, every script is off. The maintainer switches it.
2. Is the script approved? Open Plugins in the TurnOver menu: a script waiting for approval is offered there. A
   changed file needs approving again, and so does a plugin whose apps or abilities grew, unless developer mode was
   on when you approved a draft and they did not grow.
3. Is its app in front? A script starts when one of its apps first comes to the front.
4. Did TurnOver restart after a hang? Scripts stay off for that run.
5. Did it start and fail? TurnOver says "The script of <name> did not load." and the first error with its file and
   line, such as "main.js, line 12: …".
6. Is the manifest in format 2 with `script` set to `"main.js"` and `abilities` present? Run `turnover-plugin check`.
7. Is `apps` a list of named bundle identifiers, with no wildcard, none of them an app no script may name?

The apps no script may name, on any Mac, are the macOS password and permission dialogs, the login window, and TurnOver
itself (every identifier beginning `com.turnover.`). The check refuses them when the plugin loads, and TurnOver
checks again, against the app really in front, whenever a script asks for something.

### A request is rejected

- "This needs the <ability> ability. Add it to abilities in manifest.json, and the person has to agree to it.": add that
  ability, and expect to be asked again.
- A menu path or key refused by PluginPolicy: those refusals apply at the moment of the request, not just when
  the file is checked. Use a different path or key.
- A handle rejected: the item was not given to this plugin, was given long ago, or belongs to another app.
- "This works only while one of the plugin's apps is in front.": press, focus, setValue, menu and keys need the app
  really in front.
- Requests refused after many in a second: the script is over 100 requests a second or 150 ms of main-thread time.
  Ask for less, or less often.

### The words are not replaced

- Did the handler decide before it returned? Calling `event.say` after an `await` throws.
- Was the handler late? Over 25 ms, TurnOver says what it would have said.
- Does the plugin have `read`? Without it a focus or value event is never sent.
- Is the item in an app the plugin names? Events from other apps are never sent.
- A focus never stops the chain, so other things TurnOver does on a focus still happen.

### The script was turned off

Three strikes in ten minutes turn a script off for this run. The log names the strikes (a kill, a crash or a late
answer). Fix the cause (usually a handler that waits, a loop, or too much memory), then restart TurnOver, or choose the
plugin's item in the Plugins menu to start it again.

### What a script says is not yet cut off

What a script says is not yet marked with its source, so turning a script off does not cut off what it is already
saying (15 Nov 2026). That waits for speech-source work that is on another branch.
