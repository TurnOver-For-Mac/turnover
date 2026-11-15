# Plugin scripts: the author's guide (15 Nov 2026)

This guide is for people who write TurnOver plugins that need a script. It says what a script is, how to write a
first one, every part of the interface, what the user is asked to agree to, and what gets a script turned off.

Status (15 Nov 2026): scripts are designed (docs/PLUGIN-SCRIPTS-PLAN.md) and are off. They run only when the
maintainer has switched them on with `defaults write com.turnover.reader pluginScripts -bool true`. Until then every
script is ignored and plugins stay data, as docs/DECISIONS.md says. This guide describes the design; where the
design leaves a detail open, the guide says so.

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

## A first script in ten minutes

This builds the plan's sample plugin, `sample-script-calculator`. It does two things in Calculator: a command that
reads the result, and a better name for a button when it takes the focus.

### 1. Start the folder

The maker command is `turnover-plugin new <folder> --app <bundle id> --script`. It makes a working plugin to start
from. Calculator's bundle identifier is `com.apple.calculator`. You can also make the folder by hand, as below.

### 2. Write manifest.json

```json
{
  "formatVersion": 2,
  "id": "sample-script-calculator",
  "name": "Calculator, scripted",
  "version": "1.0",
  "apps": ["com.apple.calculator"],
  "abilities": ["read", "say", "press"],
  "script": "main.js",
  "commands": [
    { "id": "readResult", "description": "Read the result", "key": "turnover+control+shift+r", "letter": "r" }
  ]
}
```

What matters here:
- `formatVersion` must be 2 for a plugin with a script. Everything valid in format 1 is still valid.
- `script` must be `"main.js"`. There is one script file, and no other name.
- `apps` lists bundle identifiers by name. A plugin with a script cannot use a wildcard.
- `abilities` is the list of things the script may ask for. It is enforced, not just described: a request for
  anything not listed is refused.
- `commands` is where the script's commands are declared, not in the code. TurnOver reads the list without running
  anything, checks each key against its policy and against other plugins, and lets the user rebind the key. The
  script never sees a key. It is told that its command was chosen.
- `press` is in the plan's sample manifest, but the script below does not use it yet. Remove an ability you do not
  use: each one is another thing the user has to agree to.

### 3. Write main.js

```js
// main.js for sample-script-calculator

// A command: Read the result. The match below is an example. Use the app's snapshot
// (turnover-plugin snapshot <app>) to find the real identifier of the display.
turnover.command("readResult", async () => {
  const found = await turnover.find({ role: "static text", identifier: "main display" }, { limit: 1 });
  if (found.length === 0) {
    turnover.say("No result to read");
    return;
  }
  turnover.say(found[0].value || found[0].name || "Empty");
});

// An event: a button with no name takes the focus.
// Decide the words before the handler returns; nothing after an await can change them.
turnover.on("focus", (event) => {
  const item = event.item;
  if (item.role === "button" && !item.name && item.identifier === "AllClear") {
    event.say("All clear, button");
  }
});
```

The handler for a command is called when the user chooses the command. The `item` the command carries is described
under "Commands" below. The focus handler is called each time an item in Calculator takes the keyboard focus; if it
calls neither `event.say` nor `event.silence`, TurnOver says the item as it would have without the script.

### 4. Check it, hear what the user will hear, and test it

These commands are part of the plan and are built with the tool:

```
turnover-plugin check <folder>
turnover-plugin consent <folder>
turnover-plugin test <folder>
```

`check` reads the manifest as format 2, checks the script's syntax, and reports commands declared but not handled,
commands handled but not declared, and abilities used but not asked for. `consent` prints, word for word, what
TurnOver will say when the user is asked to approve. `test` is described under "Testing a script" below.

### 5. Try it in TurnOver

1. Turn on developer mode in the Plugins menu (the section "How approval works" says what it does).
2. Install the folder with Install my plugin from its folder, in TurnOver menu, Tools, Plugins.
3. Approve the script when TurnOver asks.
4. Bring Calculator to the front. The script starts when one of its apps first comes to the front.
5. Edit `main.js` and save. In developer mode TurnOver reloads it and says "reloaded", or says the first error with
   its line.

## The interface, version 1

A script sees one object, `turnover`, plus `console` and timers. Nothing else exists: no `fetch`, no `require`, no
file or process objects. The interface has a version number. `turnover.api` is 1, and scripts written for version 1
are meant to keep working against it.

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
`"appFocus"`, `"appBlur"` and `"windowChange"`. They are described under "Events".

```js
turnover.on("appFocus", () => { turnover.say("Calculator"); });
```

### turnover.command(id, handler)

Registers the handler for a command declared in `manifest.json`. The `id` must be one of the manifest's command
ids. No ability is needed to be called; what the handler does needs its own abilities.

```js
turnover.command("readResult", async () => { /* … */ });
```

### turnover.say(text, { interrupt })

Ability: `say`. Speaks `text`. `interrupt` (true or false) says whether to cut off what is being said. It is
not a request that waits for an answer. A script may say 20 things in two seconds, up to 500 characters each.

```js
turnover.say("Saved", { interrupt: false });
```

### turnover.sound(name)

Ability: `say`. Plays one of TurnOver's own sounds. The plan does not list the names; the script cannot supply a
sound of its own.

### await turnover.focused()

Ability: `read`. The item with the keyboard focus, or `null`. It is only an item in one of the plugin's own apps.

```js
const item = await turnover.focused();
if (item) turnover.say(item.name);
```

### await turnover.find(match, { limit })

Ability: `read`. Finds items. `match` is the same match object `profile.json` uses (see "Matching elements" in
PLUGIN-GUIDE.md): `role`, `roles`, `subrole`, `identifier`, `title`, `description`, `help`, `value`, `text`,
`window`, `inside`, `parent`, `unnamed`, `pressable`, `nth` and `any`. `limit` is the most to return. The result is
a list of items.

```js
const buttons = await turnover.find({ role: "button", unnamed: true }, { limit: 10 });
```

### await turnover.menu(path)

Ability: `menu`. Chooses a command from the app's menus. `path` is a list of menu names. PluginPolicy's refusals
apply when the request is made: the Apple menu, a first menu given as a pattern, and Paste, Log Out, Lock Screen,
Restart, Shut Down, Sleep, Force Quit, System Settings and Services are never chosen.

```js
await turnover.menu(["Edit", "Copy"]);
```

### await turnover.keys(combination)

Ability: `keys`. Sends a key press to the plugin's app. The refusals for sent keys apply when the request is made:
nothing that leaves the app (Command Tab, Spotlight, Spaces, screenshots and others), nothing with TurnOver's own
keys, and no Paste.

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
It keeps the plugin's own data between runs, up to 256 KB. The plan lists no ability for storage and does not say
what values it accepts; this guide leaves both open until the interface is built.

```js
const count = (await turnover.storage.get("count")) || 0;
await turnover.storage.set("count", count + 1);
```

### Timers and the log

`setTimeout`, `clearTimeout`, `setInterval` and `clearInterval` exist. A script may have 20 timers, none faster than
50 ms. Timers do not run while none of the plugin's apps is in front.

`console.log`, `console.warn` and `console.error` write to TurnOver's log. They are the way to see what a script is
doing.

### Items

An item is a copy of what was true when TurnOver made it, plus a handle TurnOver can use to ask for more. The fields
do not change after the item is made; call `refresh()` for a fresh copy.

Fields (no ability is needed to look at an item you were given; the ability was needed to get it):
- `item.role`: the role as TurnOver would say it.
- `item.axRole`: the accessibility role, with its AX prefix.
- `item.subrole`
- `item.name`
- `item.value`
- `item.description`
- `item.help`: the tooltip.
- `item.identifier`: the app's own identifier, the steadiest thing to match on.
- `item.states`
- `item.window`
- `item.secure`: true for a secure field. The value of a secure field is always blank to a plugin.

Methods:

```js
await item.refresh()     // ability read: a fresh copy, or null if the item has gone
await item.parent()      // ability read
await item.children()    // ability read: the first 200
await item.read()        // abilities read and say: TurnOver reads it its own way
await item.press()       // ability press
await item.focus()       // ability focus
await item.setValue(v)   // ability edit
```

A handle the plugin was not given, or a handle for an item in another app, rejects.

```js
const fresh = await item.refresh();
if (fresh && fresh.value !== item.value) turnover.say("Changed to " + fresh.value);
await (await turnover.find({ role: "button", identifier: "Save" }, { limit: 1 }))[0].press();
```

### Events

An event handler receives one object, `event`.

- `focus`: `event.item` is the item that took the focus. Call `event.say(text)` to give TurnOver other words for it,
  `event.silence()` to say nothing, or neither, and TurnOver reads it as usual. The handler must decide before it
  returns: nothing after an `await` can change the words. To add to what is said, use `turnover.say`. Everything
  else TurnOver does on a focus still happens (password echo, settings panes, text fields), and a focus handler
  never stops the chain.
- `valueChange`: `event.item`, with the same `say` and `silence`. A value change the script handles stops the chain,
  as a watch rule does today.
- `appFocus`, `appBlur`, `windowChange`: you are told, and there is nothing to replace.

Never sent: typed characters, caret moves, anything from an app the plugin did not name.

A script has 25 ms to answer a focus or value event, so keep those handlers short and do the thinking before an
`await`, or not at all. Which ability `event.say` and `event.silence` need is not stated in the plan; see the open
questions.

### Commands

When the user chooses a command, the script's handler for that id is called. The wire message for a command carries
an `item`, and the plan does not say what the handler receives or what that item is. Write handlers that find what
they need with `turnover.find` or `turnover.focused`, as the sample does, and do not rely on an argument.

## Abilities

An ability is a thing the script may ask TurnOver to do. A script asks for the ones it needs in `abilities`. The
user hears them, in TurnOver's words, before the script runs, and TurnOver refuses any request outside them.

Each ability with the kind of sentence a user will hear. TurnOver generates the exact sentences from the manifest
(`turnover-plugin consent` prints them word for word). The sentences below say what each means; they are not the
shipped wording, which is set in the code when it is built.

- `read`: "It can read the names, roles and values of items in this app."
- `say`: "It can speak, and play TurnOver's own sounds."
- `press`: "It can press buttons and other items in this app."
- `focus`: "It can move the keyboard focus to an item in this app."
- `menu`: "It can choose commands from this app's menus."
- `keys`: "It can send key presses to this app."
- `edit`: "It can change the text or value of an item in this app."
- `clipboard`: "It can put text on the clipboard. It cannot read what is on it."

`read`, `say`, `press`, `focus`, `menu` and `keys` are the six abilities that data plugins already name. `edit` and
`clipboard` are new with scripts.

Approval also says, in a fixed list, what the plugin can never do (see PLUGIN-SECURITY.md).

## How approval works

A script runs only if TurnOver holds a receipt for it on this Mac. Nothing a plugin says about itself replaces that.

- The receipt records the plugin's id, the SHA-256 of its files, its apps and its abilities, and when it was
  approved. The files that count are `manifest.json`, `profile.json` if there is one, and `main.js`. `signature.json`
  and `tests/` do not count.
- Receipts live in `plugin-trust.json` in TurnOver's support folder, sealed with a key held in the Keychain. Another
  program can delete the file, and then every script needs approving again, but cannot forge an approval.
- A script with no receipt, or whose files have changed, does not start. TurnOver says once that the plugin has a
  script waiting for approval, and the Plugins menu offers it.
- At approval TurnOver speaks what the plugin is for (your `description`, marked as the author's words) and what it
  can do (TurnOver's own words, from the manifest, with the fixed list of what it cannot do).
- A changed script needs approving again, including a new version of someone else's plugin.
- A plugin's profile and its script share one approval. The abilities are worked out from both, so a script cannot
  reach past its abilities by leaving the work to a key in `profile.json`.
- If the plugin was signed, TurnOver shows the key's fingerprint at approval and keeps it in the receipt. A later
  version signed by a different key is said to be so.

### Developer mode

Developer mode is a switch in the Plugins menu, kept in the sealed file. With it on, a draft's receipt holds as long
as the plugin's apps and abilities do not grow. Saving `main.js` reloads the script without a question, and TurnOver
says "reloaded" or the first error with its line. If you add an app or an ability, you are asked again.

TurnOver says which draft scripts are running each time it starts. Developer mode is for your own Mac while you
write; do not leave it on for a plugin you did not write. A developer build of TurnOver, whose signature changes
with each build, keeps the sealing key in a file beside it and says so in the log; that is weaker, and only for a
developer's Mac.

## The limits: what gets a script turned off

All the limits are in one file, ScriptLimits.swift, with the reason beside each. These are the plan's numbers of
15 Nov 2026 and may be tuned when it is built.

Slow answers and starting:
- 25 ms to answer a focus or value event. If you are late, TurnOver says what it would have said without you, and
  sends that script no further event until it answers. A late answer is a strike.
- 3 seconds to start.
- 5 seconds for a command to finish, or for an event to be answered at all. After that the script's program is
  killed, which is a strike.

Greed:
- 128 MB of memory, or more than half a processor for ten seconds: killed.
- 100 requests a second, and 150 ms of TurnOver's main thread in any second: further requests are refused.
- 20 things said in two seconds, 500 characters each.
- 20 timers, none faster than 50 ms.
- 256 KB for the script, 256 KB for a message, and 256 KB for the plugin's stored data.

Strikes:
- A kill, a crash or a late answer is a strike. Three strikes in ten minutes turn the script off for this run of
  TurnOver, and TurnOver says so once, by name. Restarting TurnOver gives it another chance.

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
sandboxed script program, with no app and no permissions.

The idea, from the plan:
- Each test gives the events and commands that happen, with the items they carry.
- It gives the answers to the script's questions: what `turnover.find` and `turnover.focused` should return, what
  an item's `children()` are, and so on, since there is no app to ask.
- It says what must be said.

The exact file layout is settled when the tool is built, and this guide does not give one. Until then, test a
script by hand with developer mode and `console.log`. Rules in `tests/expect.json` still work for the plugin's
profile, as PLUGIN-GUIDE.md and docs/PLUGIN-TOOLKIT-PLAN.md describe.

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

- `keygen` makes an Ed25519 key for you. Keep the private key private. Where it is stored, and the options of the
  three commands, are settled when the tool is built.
- `sign` writes `signature.json` over the same SHA-256 the receipt uses (the hash over `manifest.json`,
  `profile.json` if present, and `main.js`). Sign again after every change.
- `verify` checks the signature on a folder.

A signature says who, not whether the script is safe. Approval still comes first, and the library (when it returns)
takes a script only after a person other than its author has reviewed that exact version.

## Troubleshooting

### The script does not start

Check, in this order:
1. Is `pluginScripts` switched on? If not, every script is off. The maintainer switches it.
2. Is the script approved? Open Plugins in the TurnOver menu: a script waiting for approval is offered there. A
   changed file needs approving again.
3. Is its app in front? A script starts when one of its apps first comes to the front.
4. Did TurnOver restart after a hang? Scripts stay off for that run.
5. Did it start and fail? The log says the first error with its file and line, such as
   "main.js, line 12: …".
6. Is the manifest in format 2 with `script` set to `"main.js"` and `abilities` present? Run `turnover-plugin check`.
7. Is `apps` a list of named bundle identifiers, with no wildcard?

### A request is rejected

- "Rejects with an error that names an ability": add that ability to `abilities`, and expect to be asked again.
- A menu path or key refused by PluginPolicy: those refusals apply at the moment of the request, not just when
  the file is checked. Use a different path or key.
- A handle rejected: the item was not given to this plugin, or belongs to another app.
- Requests refused after many in a second: the script is over 100 requests a second or 150 ms of main-thread time.
  Ask for less, or less often.

### The words are not replaced

- Did the handler decide before it returned? Calling `event.say` after an `await` has no effect.
- Was the handler late? Over 25 ms, TurnOver says what it would have said.
- Is the item in an app the plugin names? Events from other apps are never sent.
- A focus never stops the chain, so other things TurnOver does on a focus still happen.

### The script was turned off

Three strikes in ten minutes turn a script off for this run. The log names the strikes (a kill, a crash or a late
answer). Fix the cause (usually a handler that waits, a loop, or too much memory), then restart TurnOver.
