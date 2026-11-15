# Plugin scripts: the plan (15 Nov 2026)

The brief (Oliver, 14 Nov 2026): a robust way for people to build plugins, how they make them and how they are kept
secure; based on JAWS scripts and NVDA add-ons, and better suited to the Mac where it can be.

This is the "scripts in a sandbox" stage that docs/PLUGIN-TOOLKIT-PLAN.md left for later. It adds to the data
plugins TurnOver has now; it does not replace them. It is off until the maintainer turns it on
(`defaults write com.turnover.reader pluginScripts -bool true`), and "Plugins are data" in docs/DECISIONS.md stands
until he does.

## The short answer

- A plugin stays a folder of plain files. Most plugins need only rules (labels, keys, watches), as now.
- A plugin that needs to think gets one script, `main.js`, in JavaScript. JavaScript because the Mac already has
  the engine (JavaScriptCore): nothing to install, nothing to ship, and most people who script know it.
- The script never runs inside TurnOver. It runs in a small separate program, locked in a sandbox by macOS, with
  no files, no network, no other programs and none of TurnOver's permissions. It can only ask TurnOver for things,
  and TurnOver checks every request against what the user agreed to.
- A script does nothing until the user has approved it on this Mac, having heard in plain words what it can do.
  A changed script needs approving again.
- A script that is slow, greedy or crashing is stopped and turned off, and TurnOver carries on reading.

## What JAWS and NVDA do

JAWS scripts:
- One set of files per application, named after the program, on top of a default set. Source (`.jss`) is compiled
  (`.jsb`); keys live in a separate key map (`.jkm`); labels and settings live in their own data files.
- A script is a command with a name and a description that keyboard help reads. Event functions (focus changed,
  new text, window activated) replace JAWS's own handling unless they call it.
- A Script Manager inside JAWS: write, compile, try at once.
- Scripts run inside JAWS with everything JAWS can reach. Compiled scripts are shared without their source.
  Nothing is signed, sandboxed or reviewed.

NVDA add-ons:
- A package (`.nvda-addon`) with a manifest: name, version, author, the oldest NVDA it needs and the newest it was
  tested with. Inside: app modules (one app), global plugins (everywhere), drivers.
- Python. Events pass down a chain and each handler chooses whether to call the next. Commands are bound to
  gestures the user can rebind. An Add-on Store with channels and compatibility checks.
- Good tools: a Python console, a scratchpad folder, a log viewer, developer information for the item in focus.
- Add-ons run inside NVDA as full Python: files, network, keystrokes, everything. The store's checks are light.
  Add-ons are switched off on secure screens, and NVDA can restart with add-ons disabled. Each yearly release that
  breaks the programming interface disables add-ons until their authors update them.

What TurnOver takes from them:
- Per-app plugins, a default underneath, and the event chain (TurnOver's core is already NVDA's design).
- Commands with descriptions, keys kept apart from code so the user can rebind them.
- A manifest with compatibility fields; a library with levels.
- The authoring loop: save and it reloads, hear the first error, see what was said, ask what an item is.
- Starting with plugins off.

What TurnOver does differently:
- No code inside the reader. Both of them load other people's code into a program that can read the whole screen
  and every key. That is the reason plugins were parked on 17 Oct 2026.
- Abilities asked for, said aloud and agreed, then enforced on every request. Not a description the author wrote.
- A crash or an endless loop in a plugin cannot stop the reader.
- A small interface with a version number that old scripts keep working against, in place of the reader's internals.
- Tests that travel with the plugin and run without the app.

## What is there today, and the gaps (read 14 Nov 2026)

Data plugins: `manifest.json` and `profile.json` in `~/Library/Application Support/TurnOver/plugins/<id>/`, with
labels, keys (press, focus, read, menu, keys, say), watch, silence, hold and view. PluginPolicy refuses the
dangerous keys and menu items on any Mac. The library's list is signed (Ed25519), carries each file's SHA-256, a
sequence number and an expiry. The `turnover-plugin` tool checks, records, tests and installs.

Gaps found:
1. Anything that can write to the plugins folder has a live plugin within a second, with no question asked. TurnOver
   holds Accessibility and Input Monitoring; another program running as the user does not. A dropped plugin borrows
   them.
2. `abilities` in the manifest is only a description. It is checked for the library listing, not when a plugin loads.
3. The library install does not run the listing and policy checks itself; it trusts the signed list.
4. Review by a person (the Verified level) leaves no record a Mac can check.
5. The documents disagree about whether plugins are parked, paused or live.

Scripts close gap 1 and 2 for themselves from the first day (approval receipts, enforced abilities). The same
receipts for data plugins are the next step after this one (Later, below), because they touch every way a data
plugin is made today.

## The clear line

A plugin, with or without a script, can never:
- run a program, load native code, or take code from anywhere but its own approved file;
- read or change files;
- use the internet or the local network;
- see what is typed, or the contents of a password field (a secure field is always blank to a plugin);
- reach an app it did not name, a macOS password or permission dialog, the login window, or TurnOver itself;
- change TurnOver's settings or another plugin;
- be heard while its app is not in front;
- keep running once it misbehaves.

A script can, only where its manifest asks and the user agreed:
- `read`: the names, roles and values of items in its apps;
- `say`: speak, and play TurnOver's own sounds;
- `press`: press an item;
- `focus`: move the keyboard focus to an item;
- `menu`: choose a command from its app's menus;
- `keys`: send a key press to its app;
- `edit`: change an item's text or value;
- `clipboard`: put text on the clipboard (never read it).

The first six are the abilities data plugins already name. PluginPolicy's refusals (the Apple menu, Paste, keys
that leave the app, TurnOver's essential keys) apply to a script's requests when they are made, not only when a
file is checked.

Not in this version, each a later decision: scripts for every app at once (NVDA's global plugins), scripts for a
website, internet access, a script's own settings and windows, reading the clipboard, seeing typed characters.

## Where a script runs

- A new program, `turnover-plugin-host`, in `TurnOver.app/Contents/Helpers`. One running copy per plugin.
- TurnOver starts it with DisclaimedSpawn, as it starts the other helpers, so macOS does not count it as TurnOver
  for permissions.
- The first thing the host does, before it reads a byte from TurnOver, is lock itself in a sandbox
  (`sandbox_init` with its own profile: everything denied but reading the system's own libraries). If the sandbox
  cannot be applied the host exits with status 3 and TurnOver runs no scripts. No sandbox, no scripts.
- TurnOver reads `main.js` itself and sends the text down the pipe. The host needs no file of the plugin's.
- The host runs the script in JavaScriptCore, the Mac's own engine. The script sees one object, `turnover`, plus
  `console` and timers. Nothing else exists there: no `fetch`, no `require`, no file or process objects.
- The two talk in JSON, one message per line, over the host's standard input and output.

Measured on this Mac, macOS 27.2, 14 Nov 2026 (a throwaway test program, not kept):
- the sandboxed host could not open a file in the home folder, write to /tmp, connect to 127.0.0.1 or start
  /usr/bin/true, and `AXIsProcessTrusted` was false inside it;
- JavaScriptCore worked inside the sandbox, including dates and number formatting;
- start to first message: 13 to 35 ms;
- one question and answer: about 20 microseconds, 35 at the 99th percentile;
- memory: 16 to 18 MB per host;
- a script in an endless loop never answered, and killing the host took about 65 ms.

`sandbox_init` is public but long deprecated; browsers still use it. It goes in the private-API inventory
(AGENTS.md) with its fallback: if it fails, scripts do not run.

## Approval

- A script runs only if TurnOver holds a receipt for it: the plugin's id, the SHA-256 of its files, its apps and
  its abilities, and when it was approved.
- Receipts live in `plugin-trust.json` in TurnOver's support folder, sealed with an HMAC-SHA256. The key is in the
  Keychain. A developer build, whose signature changes with each build, keeps the key in a file beside it and
  says so in the log: weaker, and only on a developer's Mac.
- What the seal stops: a plugin that arrives as files (downloaded, unzipped, synced, restored from a backup,
  dropped by an installer) cannot bring an approval with it; an approval cannot be copied from another Mac; and a
  plugin changed after it was approved no longer matches. Deleting the file only means every script needs
  approving again.
- What the seal does not stop (reviewed 15 Nov 2026): a program already running as the person, attacking TurnOver
  on purpose, can replace the key in the Keychain and seal a file of its own. The Keychain keeps a secret from
  other programs; it does not stop them deleting an item and putting another in its place, and TurnOver cannot
  tell whose item it reads. Nothing TurnOver can store today is out of such a program's reach. Three things limit
  it. TurnOver reads the trust file once, when it starts, so a file replaced while TurnOver runs changes nothing
  until the next start. Each time TurnOver starts with scripts on, it says how many scripts are on, and that
  developer mode is on if it is, so an approval the person never gave is heard. And a place for receipts that
  another program cannot write is a decision for the maintainer, below.
- A script with no receipt, or whose files have changed, does not start. TurnOver says once that the plugin has a
  script waiting for approval, and the Plugins menu offers it.
- Approving speaks what the plugin is for (the author's words, marked as the author's) and what it can do
  (TurnOver's own words, generated from the manifest, with the fixed list of what it cannot do).
- Developer mode, a switch in the Plugins menu kept in the sealed file: a draft's receipt then holds as long as
  its apps and abilities do not grow, so saving `main.js` reloads it without a question. A receipt is a draft's
  only if developer mode was on when the person approved it; any other receipt is for exactly the files approved,
  whatever developer mode is later. TurnOver says that developer mode is on each time it starts.
- A plugin's profile and its script share one approval: a script cannot reach past its abilities by leaving the
  work to a key in `profile.json`, because the abilities are worked out from both.

## Signing, the library and review

- An author may sign a plugin: `turnover-plugin keygen` makes an Ed25519 key, `turnover-plugin sign` writes
  `signature.json` over the same SHA-256 the receipt uses. TurnOver shows the key's fingerprint at approval and
  keeps it in the receipt. A later version signed by a different key is said to be so.
- `signature.json` is `{"format": 1, "key": "<the public key, base64>", "signature": "<base64>"}`. The signature
  is Ed25519 over the 32 raw bytes of the hash, not its hex text, so a tool in any language need only hash the
  files and verify. The fingerprint is the first 16 hex digits of the SHA-256 of the public key, in fours.
- The library keeps its signed list. For a plugin with a script the list will also carry the author's key, the
  level, who reviewed it and the hash they reviewed.
- A script reaches the library only at Verified: a named person who is not its author has read every line of that
  version against docs/PLUGIN-SECURITY.md. That goes for TurnOver's own plugins too. The pull request cannot be
  approved by its author.
- Until the library returns, a script arrives only as a folder the user approves on their own Mac. The existing
  install paths copy `main.js` but never approve it.
- The list's `withdrawn` entries already turn a library plugin off; a withdrawn script loses its receipt too.

The library's own tooling (the list generator, the steward) is not in this repository. Its changes are listed
under Decisions for the maintainer.

## Misbehaviour

Limits, all in one file (ScriptLimits.swift) with the reason beside each:
- 25 ms to answer a focus or value event. Late: TurnOver says what it would have said, and sends that host no
  further event until it answers.
- 3 s to start. 5 s for a command to finish or an event to be answered at all: after that the host is killed.
- 128 MB of memory, or more than half a processor for ten seconds: killed.
- 100 requests a second, and 150 ms of TurnOver's main thread in any second: further requests are refused.
- 20 things said in two seconds, 500 characters each. 20 timers, none faster than 50 ms.
- 256 KB for the script, for a message, and for the plugin's stored data.
- Three strikes (a kill, a crash, a late answer) in ten minutes: the script is turned off for this run of
  TurnOver, and TurnOver says so once, by name.

Starting without scripts:
- `pluginScripts` off turns every script off.
- When the watchdog has just restarted TurnOver after a hang (`--after-hang`), scripts stay off for that run and
  TurnOver says so.
- While a TurnOver approval question is open, no script is heard.

## The format

`formatVersion` 2 adds to the manifest (everything in format 1 stays valid):

```json
{
  "formatVersion": 2,
  "id": "sample-script-calculator",
  "name": "Calculator, scripted",
  "version": "1.0",
  "apps": ["com.apple.calculator"],
  "abilities": ["read", "say"],
  "script": "main.js",
  "commands": [
    { "id": "readResult", "description": "Read the result", "key": "turnover+control+shift+r", "letter": "r" }
  ]
}
```

- `script`: must be `"main.js"`. One file. Needs `formatVersion` 2 and `abilities`.
- `commands`: the script's commands. Declared here, not in code, so TurnOver lists them, checks their keys
  against PluginPolicy and other plugins, and lets the user rebind them, without running anything. A script never
  sees a key; it is told that its command was chosen.
- `apps`: named bundle identifiers only. No wildcard for a plugin with a script.
- Files that count toward the hash, in this order: `manifest.json`, `profile.json` if present, `main.js`.
  `signature.json` and `tests/` do not count.
- The hash: SHA-256 of the text `TurnOver plugin 1`, a newline, then for each file its name, a zero byte, its
  length in bytes as decimal digits, a zero byte, and its bytes.

## The script interface, version 1

```js
turnover.plugin                    // { id, name, version }
turnover.api                       // 1
turnover.language                  // "en"

turnover.on(name, handler)         // "focus", "valueChange", "appFocus", "appBlur", "windowChange"
turnover.command(id, handler)      // an id from manifest.json's commands

turnover.say(text, { interrupt })  // say
turnover.sound(name)               // say; one of TurnOver's own sounds
await turnover.focused()           // read; the item with the focus, or null
await turnover.find(match, { limit })   // read; match is profile.json's match object
await turnover.menu(["Edit", "Copy"])   // menu
await turnover.keys("command+k")        // keys
await turnover.copy(text)               // clipboard
await turnover.storage.get(key)         // also set(key, value), remove(key)

setTimeout, clearTimeout, setInterval, clearInterval
console.log, console.warn, console.error    // to TurnOver's log
```

An item is a copy of what was true when it was made, plus a handle:

```js
item.role, item.axRole, item.subrole, item.name, item.value, item.description, item.help,
item.identifier, item.states, item.window, item.secure
await item.refresh()      // read; a fresh copy, or null if it has gone
await item.parent()       // read
await item.children()     // read; the first 200
await item.read()         // read and say; TurnOver reads it its own way
await item.press()        // press
await item.focus()        // focus
await item.setValue(v)    // edit
```

Events:
- `focus`: `event.item`. `event.say(text)` replaces what TurnOver says for the item; `event.silence()` says
  nothing; neither, and TurnOver reads it as usual. The handler must decide before it returns or reaches its first
  `await`, from the item it was given: nothing after an `await` can change the words (use `turnover.say` to add to
  them). So a late answer means the handler's own code took more than 25 ms, never that a request was slow.
  Everything else TurnOver does on a focus still happens.
- `valueChange`: `event.item`, with the same `say` and `silence`.
- `appFocus`, `appBlur`, `windowChange`: told, nothing to replace.
- Never sent: typed characters, caret moves, anything from an app the plugin did not name.

A request without its ability rejects with an error that names the ability to add. A handle the plugin was not
given, or one for an item in another app, rejects.

The script is started when one of its apps first comes to the front and ended when its apps have all quit. It is
paused (no events, no timers) while none of its apps is in front.

Details settled while the documents were written (15 Nov 2026):
- `event.say` and `event.silence` need `say`.
- `turnover.storage` needs no ability. A value is anything JSON can hold.
- A command's handler is given `context`. `context.item` is the item with the focus when the command was chosen,
  if the plugin has `read`; otherwise null.
- `turnover.find` gives a list of items, empty when nothing matched.
- `item.states` is a list of words ("selected", "disabled"); `item.window` is the window's title.
- `turnover.sound` takes the name of one of TurnOver's own sound files; a name TurnOver does not have rejects.
- The library's closed apps (PluginPolicy.closedApps) are closed to a plugin with a script as to any other. On any
  Mac, a script may not name the macOS password and permission dialogs, the login window, or TurnOver.
- While a secure field has the focus, `keys` and `edit` requests are refused, as reading it always is.
- `turnover-plugin verify <folder>` prints the hash and the signing key's fingerprint: what a reviewer records.
  An author's key is a file, `~/.turnover-plugin/author.key`, readable only by them.
- "What is this?" (VO-Slash, the plugin maker) is the developer information for the item in focus.

Details settled while the format and the tool were built (15 Nov 2026):
- A plugin with a script may have no `profile.json`. A plugin without a script still needs one.
- An empty `abilities` list counts as none, and a script needs at least one ability.
- Format 2 is the newest this TurnOver reads. The plugin maker still writes format 1, so a plugin of rules stays
  readable by older builds.
- The apps no script may name on any Mac are `PluginPolicy.scriptForbiddenApps` and every identifier beginning
  `com.turnover.`. They are checked when the plugin loads and again, against the app really in front, whenever a
  script asks for something.
- `plugin-trust.json` is one JSON object: `format`, `developerMode`, `receipts` and `seal`. The seal is the base64
  HMAC of the object without `seal`, written compactly with its keys sorted.
- A script test (`tests/script/*.json`) may also give `{"error": "..."}` as an answer, expect an error with
  `expect.error`, and use `turnover.storage`, which the runner keeps in memory.
- What a script stores is a plain file in TurnOver's support folder. Other programs can read it, so a script
  should not store what it reads from an app unless the person would expect that.

## The wire

One JSON object per line. TurnOver to host:
- `{"t":"hello","api":1,"plugin":{…},"language":"en","abilities":[…],"commands":[…],"source":"…"}`
- `{"t":"event","id":7,"name":"focus","item":{…}}`
- `{"t":"command","id":8,"command":"readResult","item":{…}}`
- `{"t":"reply","id":3,"ok":true,"value":…}` or `{"t":"reply","id":3,"ok":false,"error":"…"}`
- `{"t":"pause"}`, `{"t":"resume"}`, `{"t":"bye"}`

Host to TurnOver:
- `{"t":"ready","events":["focus"],"commands":["readResult"]}` or `{"t":"failed","error":"main.js, line 12: …"}`
- `{"t":"eventDone","id":7,"handled":true,"say":"Clear"}` (`"say":""` for silence; `"handled":false` for neither)
- `{"t":"commandDone","id":8,"error":null}`
- `{"t":"request","id":3,"op":"find","args":{…}}`
- `{"t":"notify","op":"say","args":{"text":"…","interrupt":false}}` (also `sound`, `log`)

The host answers an event as soon as the handler returns. It ends when its input closes.

## How it joins TurnOver

New code, in `Sources/Core/Plugins/Scripts/` unless said:
- `Sources/TurnOverPluginWire/`: the message names and limits both sides share.
- `Sources/TurnOverPluginHost/`: the host program.
- `ScriptLimits`, `ScriptAbilities` (the list, and the sentences for approval).
- `ScriptHost`: one host process. Start, the timed question for events, commands, the watchdog and strikes.
- `ScriptBroker`: a protocol for what a script may ask, the routing and the ability checks. `AXScriptBroker` is
  the real one; tests use a fake.
- `ScriptTrust`: the hash, receipts, the sealed file, signatures.
- `ScriptPlugins`: a GlobalPlugin, registered in Core.start beside ProfilesPlugin when `pluginScripts` is on. It
  finds plugins with scripts among ProfileStore's, checks receipts, starts and pauses hosts, carries their
  commands as scripts (as ProfilesPlugin carries keys), and passes events on.

Changes to existing code, kept as small as they can be:
- `PluginFormat`, the manifest type, the schemas: the new fields.
- `PluginPolicy`: refusals for a script's manifest; the request-time checks reuse `refusedKey` and the menu rules.
- `ProfileStore`: `main.js` counts as a change to reload for.
- `TurnOverObject.reportFocus()`: one question, "has a script given words for this focus?". If so those words are
  said in place of `Speech.speakObject`, through the same step that drops the previous focus's speech.
- `Edition`: `includesPluginScripts`.
- `TurnOverMenu`: under Plugins, a script waiting for approval, scripts on or off, developer mode.
- `build.sh` and `Package.swift`: the host built, signed, self-tested and put in Helpers, as the other helpers are.

A value change the script handles stops the chain, as a watch rule does today. A focus never stops the chain:
objects do more than speak when they take the focus (password echo, settings panes, text fields).

## Tools and tests for authors

- `turnover-plugin new <folder> --app <bundle id> [--script]`: a working plugin to start from.
- `turnover-plugin check`: format 2, the script's syntax, commands declared but not handled and the reverse,
  abilities used but not asked for.
- `turnover-plugin consent <folder>`: what TurnOver will say at approval, word for word.
- `turnover-plugin test`: as now for rules; for a script, `tests/script/*.json` gives events and commands with the
  items they carry and the answers to the script's questions, and what must be said. It runs in the real sandboxed
  host with no app and no permissions.
- `turnover-plugin keygen`, `sign`, `verify`.
- Save a draft's `main.js` in developer mode: reloaded, and "reloaded" or the first error with its line is said.
- `plugins/examples/sample-script-calculator`: a script with commands, events and tests.
- Documents: PLUGIN-GUIDE.md gains a scripts part; docs/PLUGIN-SCRIPTS.md (the author's guide and the interface),
  docs/PLUGIN-SECURITY.md (the line, the threats, the reviewer's checklist), docs/FROM-JAWS-AND-NVDA.md, and
  `turnover.d.ts` so an editor or an AI knows the interface.

## Build stages

Each stage is built by a helper from this plan, with only the tests for its own part, in one build folder. The
full `build.sh --no-install` runs once at the end.

1. The engine: the wire, the host, ScriptHost, ScriptLimits, ScriptAbilities, the ScriptBroker protocol, the
   build and packaging. Tests: the sandbox refuses files, network and programs; question and answer; a late
   answer; an endless loop killed; a crash; a request without its ability.
2. The format, trust and the tool: format 2, the policy, ScriptTrust, the `turnover-plugin` commands, the sample
   plugin and its tests.
3. Joining TurnOver: ScriptPlugins, AXScriptBroker, the reportFocus question, approval and the menu, the switch.
4. The documents, alongside.
5. A review by someone who did not write it, then the full build.

## Decisions for the maintainer

1. Turning it on: `pluginScripts` is off. Turning it on reverses "Plugins are data" for sandboxed scripts only.
2. The library: bringing it back for scripts needs the list to carry author key, level, reviewer and reviewed
   hash; the steward to run `turnover-plugin check` and the script tests; and a rule that the reviewer is not the
   author. None of that is in this repository.
3. Release signing: `turnover-plugin-host` is signed like the other helpers and needs no entitlement. With the
   hardened runtime JavaScriptCore runs without its compiler, which is what the tests use.
4. Whether scripts may ever reach every app, a website, or the internet. This plan says not yet.
5. Where a report of a harmful plugin goes. There is no SECURITY.md; docs/PLUGIN-SECURITY.md says so until there is.
6. A place for receipts that another program cannot write (see Approval). Both ways change how TurnOver is
   assembled and signed, so neither is built here:
   - a small sandboxed service inside TurnOver.app that keeps the receipts in its own container, which macOS 14 and
     later protects from other developers' programs, and which answers only the signed TurnOver
     (`xpc_connection_set_peer_code_signing_requirement`); or
   - the data-protection Keychain with an access group, which needs a provisioning profile and the
     `keychain-access-groups` entitlement.
   Until one of them exists, a receipt stops files that arrive, not a program that attacks TurnOver's own files on
   purpose. That is still more than a plugin of rules has today (gap 1).

## Later

- Receipts for data plugins too, so nothing in the plugins folder is live without approval (gap 1).
- Abilities enforced for data plugins at load (gap 2), and the library install running the checks itself (gap 3).
- A command that says which plugin spoke last.
- Scripts for a website (the browsers are closed apps today).
- Options a plugin declares, shown in TurnOver's own menu.
- Script tests that replay a recorded app through the real broker.
