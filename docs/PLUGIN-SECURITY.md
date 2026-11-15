# Plugin security (15 Nov 2026)

This document says what a TurnOver plugin can never do, what a plugin with a script can do only by asking, what
could go wrong and what stops it, what is not protected against, and how a reviewer checks a script. It follows
docs/PLUGIN-SCRIPTS-PLAN.md. Scripts are off until the maintainer switches on `pluginScripts`; the parts about
scripts describe the design, and the parts about data plugins describe what is built.

A screen reader sees everything on the screen and every key. That is the reason plugins were parked on 17 Oct 2026,
and the reason for the limits below.

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

PluginPolicy's refusals apply to a script's requests when they are made, not only when a file is checked: the Apple
menu, Paste, keys that leave the app, and TurnOver's essential keys.

## How a script is held

- It runs in a separate program, `turnover-plugin-host`, one copy per plugin, started so that macOS does not count
  it as TurnOver for permissions. It has no Accessibility or Input Monitoring permission.
- The first thing that program does is lock itself in a sandbox that denies everything except reading the system's
  own libraries. If the sandbox cannot be applied it exits and TurnOver runs no scripts.
- TurnOver reads `main.js` and sends the text to it. The program needs no file of the plugin's.
- The script can only ask TurnOver for things. TurnOver checks every request against the abilities the user agreed
  to, and against PluginPolicy.
- Measured on 14 Nov 2026 with a throwaway test program: the sandboxed program could not open a file in the home
  folder, write to /tmp, connect to the local network or start another program.
- The sandbox call is public but long deprecated; browsers still use it. It is listed in AGENTS.md among the
  private and deprecated calls, with its fallback: if it fails, scripts do not run.

## The threats

### A plugin written to do harm

What stops it:
- A script runs only after the user has approved it on this Mac, having heard what it can do in plain words.
- Its abilities are enforced on every request, so a script that did not ask for `keys` cannot send a key.
- It runs in a sandbox with no files, no network and no other programs.
- Its apps are named; it hears and sees nothing from other apps, and nothing while its app is not in front.
- A secure field is blank to a script, and a script can neither change one nor send keys while one has the focus.
- In the library, a script is taken only at Verified: a named person who is not the author has read every line of
  that version (the reviewer's checklist below).
- A misbehaving script is turned off.

### A good plugin turned bad by an update

What stops it:
- Approval is tied to a hash of the plugin's files. A changed script has a different hash, does not start, and
  needs approving again.
- If the plugin is signed, TurnOver says when a later version is signed by a different key.
- In the library, the list carries the hash a reviewer read. An update is a new version that needs its own review.
- The library's `withdrawn` entries turn a plugin off, and a withdrawn script loses its receipt too.

What does not stop it: a user who approves the new version without reading what it says it can do. Approval says
what the plugin can do, not what it will do.

### Another program on the Mac dropping a plugin into the folder

A data plugin today is live within a second of being copied into the plugins folder, with no question asked (gap 1
in the plan). TurnOver holds Accessibility and Input Monitoring; another program running as the user does not, and a
dropped plugin borrows them. That is real, and it is not fixed for data plugins yet (a later step in the plan).

For scripts it is closed from the first day: a dropped script has no receipt and does not start. The receipts are
sealed with a key in the Keychain that only TurnOver's signed program can read, so another program can delete the
file (every script then needs approving again) but cannot forge an approval. A developer build keeps the key in a
file and says so in the log; that is weaker and only for a developer's Mac.

The install paths that exist copy `main.js` but never approve it.

### The library's site or key being taken over

The library's list is signed (Ed25519), carries each file's SHA-256, a sequence number and an expiry. The existing
tool checks them. What stops a taken-over site is that a list with no valid signature is not used, an old list is
not replayed past its sequence number and expiry, and a file whose hash does not match is not installed.

What does not stop it: someone who holds the library's signing key can publish a signed list. Approval is the
second line: even a script the library delivers has no receipt until the user approves it on their own Mac, and
the approval says what it can do. For the library to return for scripts, the plan lists work that is not in this
repository: the list carries the author's key, the level, the reviewer and the reviewed hash; the steward runs the
checks and tests; and the reviewer is never the author.

### A plugin that is merely buggy

What stops it:
- The script is in a separate program. A crash or an endless loop in it cannot stop the reader.
- Limits on time, memory, requests and speech. A script that answers a focus event more than 25 ms late is not
  waited for. Past 5 seconds its program is killed.
- Three strikes in ten minutes (a kill, a crash, a late answer) turn it off for this run of TurnOver, and TurnOver
  says so by name.
- Scripts stay off for a run that follows a watchdog restart after a hang.

### A plugin that tries to sound like TurnOver or macOS

A script can say things. The danger is a message that looks like TurnOver's or the Mac's own: "TurnOver needs your
password", "macOS says your Mac is at risk".

What stops it:
- For library plugins, PluginPolicy's rule: words that mention TurnOver or VoiceOver, a phone number or a web
  address are not allowed in a label, a watch prefix or a key's `say`. That check reads rules; it cannot read what
  a script builds from strings, so a reviewer must check every `say` in a script (the checklist below).
- A script cannot reach a macOS password or permission dialog, the login window or TurnOver itself, and a secure
  field is blank to it.
- While a TurnOver approval question is open, no script is heard.
- At approval, the author's description is marked as the author's words, and what the plugin can do is in
  TurnOver's own words.

What does not stop it: a script that says something misleading in its own app. A command to "say which plugin
spoke last" is listed under Later in the plan; it does not exist.

## What is not protected against

Said plainly, 15 Nov 2026:
- A script with `read` in an app sees what is on screen in that app: names, roles and values of its items. Mail,
  messages, balances: anything the app shows. It cannot send them anywhere (no network, no files), but it can say
  them aloud, and it can keep them in its own storage (256 KB) on this Mac.
- A script with `keys` or `menu` can do in that app whatever the user could do with keys or menus there, except
  what PluginPolicy refuses. In an app that deletes, sends or pays with a key, a script can press that key.
- A script with `press` or `edit` can press buttons and change text in that app: a Send button, a field.
- A script with `clipboard` can replace what is on the clipboard. The user may then paste it somewhere.
- A script can say misleading things, or stay silent where it should speak, in its own app.
- Approval is only as good as the user's reading of it. TurnOver cannot judge intent.
- A reviewer can miss something. A review lowers the risk; it does not remove it.
- Data plugins do not have receipts yet. Anything that can write to the plugins folder has a live data plugin within
  a second (the "Later" list in the plan).
- A data plugin's `abilities` field is a description, not enforced at load, and the library install trusts the
  signed list instead of running the checks itself (gaps 2 and 3 in the plan).
- JavaScriptCore is the Mac's own engine and carries its own risk if it has a flaw; the sandbox is the second line
  for that.
- A developer build keeps its sealing key in a file; developer mode keeps a draft's approval while apps and
  abilities do not grow.
- Whether scripts may ever reach every app, a website or the internet is not decided. This design says not yet.

## The reviewer's checklist for a script

For the library, a script reaches Verified only when a named person who is not its author has read every line of
that version. This also applies to TurnOver's own plugins. The pull request cannot be approved by its author.
Follow these steps for each version, not only the first.

1. Read every line of `main.js`, `manifest.json` and `profile.json`. If you cannot read it, you cannot approve it.
2. Reject code that is packed, encoded or built from strings: `eval`, `Function`, `new Function`, and long encoded
   text (base64, hex, or arrays of numbers turned into letters). Also reject a script that assembles names of
   things at run time to reach them, such as building a property name from pieces. Ask for the plain version.
3. Check each ability is needed for what the description says. For each ability in the manifest, find the calls
   that use it. Remove an ability that nothing uses. Question an ability that the description does not explain.
4. Check every `say`. Look at every `turnover.say`, `event.say` and every label or key's `say` in the profile, and
   the strings they are built from. Reject words that pass as TurnOver, VoiceOver, macOS, the system, a password or
   permission prompt, a phone number, or a web address.
5. Check every use of `keys` and `menu`. Each key sent and each menu path must match what the description says, and
   must not be on PluginPolicy's lists (that is enforced too, but read it yourself). Be suspicious of keys or menu
   paths chosen from a computed value.
6. Check loops and timers. Every loop must end. Every `setInterval` must have a reason and a way to stop. Look for
   work in a focus or value handler, which has 25 ms.
7. Check what is stored. Everything in `turnover.storage` must be explained by the description. Look for anything
   that copies what the script has read into storage, or into the clipboard.
8. Check what is read and what it is for: whether `read` results are used only for what the description says.
9. Run the plugin's tests (`turnover-plugin test <folder>`), and `turnover-plugin check <folder>`. A script with no
   tests is a reason to ask for them. A test that passes proves what it tests and nothing more.
10. Check that the author's key (if signed) is the one the previous version used, or that the change is explained.
11. Record the hash you reviewed: the SHA-256 of that version's `manifest.json`, `profile.json` and `main.js`, as
    the plan defines it, with your name and the date. `turnover-plugin verify <folder>` prints that hash and the
    signing key's fingerprint. A later change, even one character, needs a new review.

If any step fails, do not approve; say which step and why, on the pull request.

## Reporting a plugin that behaves badly

1. Stop using it: turn the plugin off in the Plugins menu, or remove it.
2. Note its id and version, and what it did or said. Look in TurnOver's log (`~/Library/Application Support/TurnOver/logs`),
   which records what TurnOver saw and said; leave out anything private.
3. Report it through the project's issue form on GitHub, the way other problems are reported
   (see CONTRIBUTING.md), naming the plugin, its author and the version. Do not put private content in a public
   issue. The repository has no SECURITY.md yet (15 Nov 2026), so a report that could harm people before it can be
   fixed has no private channel written down; say in the issue that it is a security report, without the details
   that would help someone misuse it.
4. For a library plugin, the contact in its listing is also an address for problems. A confirmed report leads to the
   plugin's `withdrawn` entry in the library's list, which turns it off for everyone and removes a script's receipt.
