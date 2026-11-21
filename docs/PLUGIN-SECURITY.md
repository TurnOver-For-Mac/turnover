# Plugin security (15 Nov 2026)

This document says what a TurnOver plugin can never do, what a plugin with a script can do only by asking, what
could go wrong and what stops it, what is not protected against, and how a reviewer checks a script. It follows
docs/PLUGIN-SCRIPTS-PLAN.md and the code as built on 15 Nov 2026. Scripts are built and off until the maintainer
switches on `pluginScripts`; the parts about data plugins describe what has been live since 20 Oct 2026.

A screen reader sees everything on the screen and every key. That is the reason plugins were parked on 17 Oct 2026,
and the reason for the limits below.

## The clear line

A plugin, with or without a script, can never:
- run a program, load native code, or take code from anywhere but its own approved file;
- read or change files;
- use the internet or the local network;
- see the keys that are pressed or the characters as they are typed, or the contents of a password field (a secure
  field is always blank to a plugin);
- reach an app it did not name, a macOS password or permission dialog, the login window, or TurnOver itself;
- change TurnOver's settings or another plugin;
- be heard while its app is not in front;
- keep running once it misbehaves.

A script can, only where its manifest asks and the user agreed:
- `read`: the names, roles and values of items in its apps, which includes the text a field holds, but never a
  password;
- `say`: speak, change or silence what TurnOver says for an item in its apps, and play TurnOver's own sounds;
- `press`: press an item;
- `focus`: move the keyboard focus to an item;
- `menu`: choose a command from its app's menus;
- `keys`: send a key press to its app;
- `edit`: change an item's text or value, and move the caret or the selection in it;
- `clipboard`: put text on the clipboard (reading it is `clipboardRead`);
- `everywhere`: work in every app but the forbidden ones (the apps field is `["*"]`), judged against the app really in
  front on every request;
- `hearSpeech`: be told what TurnOver says to the person while one of its apps is in front, never what is said at a
  password field or under secure keyboard entry, never what a plugin said, and with no power over the speech;
- `clipboardRead`: read the clipboard's text while one of its apps is in front, never under secure keyboard entry.

Also under `read`, a script can be given the selected text, the line and the whole text of an item (at most 10,000
characters, never from a password field), and under `say` it can put up TurnOver's own list or typed prompt (one at a
time, never over a password field or under secure keyboard entry) and play tones.

PluginPolicy's refusals apply to a script's requests when they are made, not only when a file is checked: the Apple
menu, Paste, keys that leave the app, and TurnOver's essential keys.

The apps no script may name, on any Mac, are the macOS password dialogs (`com.apple.SecurityAgent` and
`com.apple.LocalAuthentication.UIAgent`), the macOS permission dialogs (`com.apple.CoreServicesUIAgent` and
`com.apple.UserNotificationCenter`), the login window (`com.apple.loginwindow`), and TurnOver itself (`com.turnover`
and every identifier beginning `com.turnover.`). The check refuses them when the plugin loads, and TurnOver
checks again, against the bundle of the app that really owns the item, whenever a script asks for something.

The library's closed apps (passwords, System Settings, terminals, browsers, as PluginPolicy.closedApps lists them) are
closed to a script in the library as to any other plugin. On the person's own Mac a script may name them, but there
(decided 16 Nov 2026) it can only read and speak: `press`, `focus`, `edit`, `menu` and `keys` are refused for a closed app
on any Mac, when the plugin loads and again whenever the script asks, against the app really in front. TurnOver says so
in what the person hears at approval: "In <the apps> it can only read and speak: passwords, settings, terminals and
browsers are like this. It can never press, type or choose anything there, whatever else it is allowed to do." A plugin
that has a script is also one thing: until its script may run, none of its profile (labels, keys, watches, silences,
holds, view) is live either.

## How a script is held

- It runs in a separate program, `turnover-plugin-host`, one copy per plugin, started so that macOS does not count
  it as TurnOver for permissions. It has no Accessibility or Input Monitoring permission.
- The first thing that program does is lock itself in a sandbox that denies everything except reading the system's
  own libraries. If the sandbox cannot be applied it exits and TurnOver runs no scripts.
- TurnOver reads `main.js` and sends the text to it. The program needs no file of the plugin's.
- The script can only ask TurnOver for things. TurnOver checks every request against the abilities the user agreed
  to, and against PluginPolicy.
- Acting needs the app really in front. A request that acts (`press`, `focus`, `edit`, `menu`, `keys`) is refused
  unless both TurnOver's idea of the focus and the Mac's own frontmost app are one of the plugin's apps. Speech and
  sounds are dropped, not refused, while none of the plugin's apps is in front or a TurnOver approval question is open.
- Secure keyboard entry. `keys` and `edit` are refused while the Mac reports that it is hiding what is typed (a
  password field has asked, or a program has), while a password field has the focus, and when TurnOver cannot tell
  what has the focus. A password field is never changed, and a value change in one is never sent to any script.
- A search (`turnover.find`) gives at most 50 items and may take 150 ms of TurnOver's main thread.
- Measured on 14 Nov 2026 with a throwaway test program: the sandboxed program could not open a file in the home
  folder, write to /tmp, connect to the local network or start another program.
- The sandbox call is public but long deprecated; browsers still use it. It is listed in AGENTS.md among the
  private and deprecated calls, with its fallback: if it fails, scripts do not run.

## Approval and what it protects against

A script runs only if TurnOver holds a receipt for it: the plugin's id, the SHA-256 of its files, its apps and its
abilities, when it was approved, and where the script came from. The question the person answers is spoken in
TurnOver's own words, with the author's description marked as the author's, and "Not now" is offered before
"Approve", so a hurried Return cannot approve. docs/PLUGIN-SCRIPTS.md lists the sentences.

What approval protects against:
- A plugin that arrives as files (downloaded, unzipped, synced, restored from a backup, dropped by an installer)
  cannot bring an approval with it. It has no receipt and does not start.
- An approval cannot be copied from another Mac.
- A plugin changed after it was approved no longer matches its receipt, so it does not start. A plugin that now
  asks for more apps or more abilities is refused the same way.
- Deleting the receipts only means every script needs approving again.
- A script waiting for approval is noticed. TurnOver says so when its app comes to the front, and the Plugins menu
  offers the question.

What approval does not protect against:
- A person who approves without listening. Approval says what the plugin can do, not what it will do, and TurnOver
  cannot judge intent.
- A program already running as the person that attacks TurnOver on purpose. How far the keeper below stops that
  is stated under "The keeper". In a developer build it does not stop it at all.
- A script that does harm inside what it was allowed: see "What is not protected against".

### What a developer build does

A developer build of TurnOver, whose signature changes with each build and may be ad hoc, cannot use the keeper. It keeps
the receipts in `plugin-trust.json` in TurnOver's support folder, sealed with an HMAC-SHA256, with the sealing key in
a file beside it that only the person can read. The log says so. This is weaker, and only for a developer's Mac:

- The seal stops a plugin or a stray copy of the file from bringing an approval with it, and stops a changed plugin
  matching an old receipt. It does not stop a program already running as the person, attacking TurnOver on purpose:
  that program can read the key file as the person can, and seal a file of its own.
- Nothing TurnOver can store without a keeper is out of such a program's reach. Three things limit it. TurnOver reads
  the trust file once, when it starts, so a file replaced while TurnOver runs changes nothing until the next start.
  Each time TurnOver starts with scripts on it says how many scripts are on, and that developer mode is on if it is, so
  an approval the person never gave is heard. And every other build has the keeper.
- The Keychain is not used. It keeps a secret from other programs, but it does not stop one deleting an item and
  putting another in its place, and TurnOver cannot tell whose item it reads.

### Developer mode

Developer mode is a switch in the Plugins menu, kept with the receipts. With it on, a draft's receipt holds as long as
its apps and abilities do not grow, so saving `main.js` reloads the script without a question. A receipt is a
draft's only if developer mode was on when the person approved it. Any other receipt is for exactly the files approved,
whatever developer mode is later. TurnOver says that developer mode is on each time it starts, and says so when it is
turned on.

What this costs: while developer mode is on, someone who can change a draft's files, and who got an approval of it
in developer mode, changes what runs without a question, as long as the apps and abilities named do not grow. That is
the point of the switch for an author, and the reason not to leave it on for a plugin written by someone else.

## The keeper

Decided and proven on 15 Nov 2026. It holds the receipts and the developer-mode switch in every build that is not a
developer build.

What it is: a small sandboxed XPC service inside TurnOver.app, `Contents/XPCServices/TurnOverTrustKeeper.xpc`, whose
bundle identifier is the app's followed by `.trust-keeper`. Its only entitlement is the App Sandbox. It keeps one file
in its own container (`~/Library/Containers/<identifier>/Data`). On macOS 14 and later, macOS asks the person before a
program from another developer may touch an app's container, so the file is out of reach of a program that merely runs
as the person. It does not understand receipts. It loads bytes, stores bytes (1 MB at most, written whole), and runs a
check that writes, reads and removes a probe. TurnOver's own code understands the receipts.

Who it answers: only the signed TurnOver. When a connection arrives the keeper reads its own team from its own signature
and requires the other end to be signed by that team with the app's identifier. A keeper with no team (an ad hoc build)
answers nobody. TurnOver puts the matching requirement on its own end, so a keeper swapped inside the app is not
believed either. The keeper also refuses to work unless it really is sandboxed, so a build that lost the entitlement
fails loudly instead of keeping receipts in an open folder.

What it protects against: a program running as the person cannot write receipts, or turn developer mode on, by
writing a file. It cannot ask the keeper to do it either, because it is not the signed TurnOver. This is what the
sealed file of a developer build cannot give.

If the keeper cannot be reached, no script is approved in that run and none can be. TurnOver itself is not affected.
Nothing waits on the keeper for more than two seconds, and only when scripts are switched on.

What was measured, on macOS 27.2 with a throwaway copy signed with the Developer ID certificate and the hardened runtime
(15 Nov 2026):
- The service starts inside its own container. Its first answer took 164 ms the first time ever and 20 to 25 ms in later
  runs; further questions on the same connection took 0.04 ms.
- A fake app signed ad hoc, with the same bundle identifier and a copy of the real keeper inside it, was refused on every
  call, and the file was unchanged.
- The same fake app around a keeper built without the check wrote a forged file into the real container. So the check is
  what stops this attack, and a test must keep it there.
- An app signed by the same team with a different identifier was refused.

What was not tried: another program writing the container directly, because it would put a system question on the
screen. That protection rests on what macOS documents for macOS 14 and later, not on a test of ours.

What it does not change: a copy of TurnOver signed without the hardened runtime (a local build) can have code loaded
into it by another program, and that code then is TurnOver. Published builds have the hardened runtime.

The checks: `turnover --check-trust-keeper` asks the keeper to run its check and prints the result without starting the
screen reader, and `build.sh` runs it after signing a build that is not a developer build. A second check builds a
throwaway app around the real keeper and proves both that it answers its own app and that it refuses a copy of that app
signed by someone else; a keeper that answers the copy stops the build.

A published build is signed again elsewhere. The keeper's sandbox entitlement must survive that, and
`--check-trust-keeper` should be run on the published build. That is for the maintainer, and is not done by this
repository.

## Signing and the fingerprint

An author may sign a plugin. `turnover-plugin keygen` makes an Ed25519 key at `~/.turnover-plugin/author.key`, readable
only by the author. `turnover-plugin sign` writes `signature.json` over the same SHA-256 the receipt uses.

`signature.json` is `{"format": 1, "key": "<the public key, base64>", "signature": "<base64>"}`. The signature is
Ed25519 over the 32 raw bytes of the hash, not its hex text, so a tool in any language need only hash the files and
verify. The hash is of the text `TurnOver plugin 1`, a newline, then for each of `manifest.json`, `profile.json` (if
present) and `main.js`: its name, a zero byte, its length in bytes as decimal digits, a zero byte, and its bytes. The
fingerprint is the first 16 hex digits of the SHA-256 of the public key, in groups of four.

TurnOver says the fingerprint at approval, keeps it in the receipt, and says when a later version is signed by a different
key. A signature that does not match the files is said too. A signature says who made a version, not that it is safe:
anyone can make a key.

## The threats

### A plugin written to do harm

What stops it:
- A script runs only after the user has approved it on this Mac, having heard what it can do in plain words.
- Its abilities are enforced on every request, so a script that did not ask for `keys` cannot send a key.
- It runs in a sandbox with no files, no network and no other programs.
- Its apps are named (or, with `everywhere`, every app but the forbidden ones); it hears and sees nothing from other apps, and nothing while its app is not in front.
- A secure field is blank to a script, and a script can neither change one nor send keys while one has the focus.
- In the library, how much review a plugin gets depends on the risk of its abilities, not on every plugin alike: see
  "Review by risk" in docs/PLUGIN-PLATFORM-PLAN.md, and the reviewer's checklist below. `turnover-plugin check` prints
  the level.
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

For scripts it is closed from the first day: a dropped script has no receipt and does not start. In every build that
is not a developer build the receipts are held by the keeper, so another program cannot write an approval. A developer
build is weaker, as above. The install paths that exist copy `main.js` but never approve it.

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
spoke last" is listed under Later in the plan; it does not exist. What a script says is also not yet marked with its
source, so turning a script off does not cut what it is already saying (15 Nov 2026); that waits for speech-source
work that is on another branch.

## What stage B added, and what holds it (16 Nov 2026)

- Working in every app is an ability the person hears in plain words: that it works in every app except password and
  permission dialogs, and that with `read` it can read what is on the screen wherever they are. The forbidden apps give
  it nothing at all, not even an event, and a closed app lets it read and speak only.
- A list or prompt a script puts up is TurnOver's own, said with the plugin's name first. While one is open no other
  question opens, and no plugin hears what TurnOver says, so what the person types into one plugin's prompt is not
  another's to hear. A question is refused over a password field and under secure keyboard entry, because the keys
  the person types would go to TurnOver's prompt.
- Reading text and moving the caret use TurnOver's own text code and the rules `read` and `edit` already have. A
  password field gives nothing and is never changed.
- `hearSpeech` and `clipboardRead` are the abilities that can read what is private, so they sit at the highest level
  of review, are refused in the closed apps, and are refused under secure keyboard entry. What the plugin itself says,
  and the notices TurnOver says about a plugin (which carry the plugin's name and its own error text), are not passed to
  any plugin that hears.
- Options are kept by TurnOver and checked every time: a value the option does not allow is never stored and never given
  to the script.
- Every plugin's author gives a `support` address and a reason for each ability above reading and speaking, and the
  Plugins menu can say who looks after a plugin and turn every plugin off until TurnOver starts again.
- Found and fixed in the same pass: a host that ended by itself (crashed) left its input open, so a write queued just
  before it ended could reach a closed file number. The input is now closed for every later write whichever way the
  host ends.
- Checked, with a test each, and not changed: a script's search never matches on what a password field holds, in a
  match or any match inside it; the keeper's sandbox check is a test of the program's home folder and environment, so it
  is a guard against a mistake and not proof of confinement, which only the signed build can show
  (`turnover --check-trust-keeper`); and whether a build is a developer build is read from its Info.plist, so a
  changed Info.plist in a copy that keeps its permissions could pick the developer file, which only a live signed build
  can show.

## What is not protected against

Said plainly, 15 Nov 2026:
- A script with `read` in an app sees what is on screen in that app: names, roles and values of its items, including
  text a field holds. Mail, messages, balances: anything the app shows. It cannot send them anywhere (no network, no
  files), but it can say them aloud, and it can keep them in its own storage (256 KB) on this Mac. What a script stores
  is a plain file in TurnOver's support folder, `plugin-data/<id>.json`, readable by any other program running as the
  person, so a script should not store what it reads from an app unless the person would expect that.
- A script with `keys` or `menu` can do in that app whatever the user could do with keys or menus there, except
  what PluginPolicy refuses. In an app that deletes, sends or pays with a key, a script can press that key.
- A script with `press` or `edit` can press buttons and change text in that app: a Send button, a field.
- A script with `clipboard` can replace what is on the clipboard. The user may then paste it somewhere.
- A script can say misleading things, or stay silent where it should speak, in its own app.
- A script with `read` can change or silence what TurnOver says on a focus or value change by calling `event.say` or
  `event.silence`, and TurnOver does not check at that moment that the plugin has `say`. The approval sentence for
  `say` mentions it, but a plugin that asked for `read` alone and was approved is not told it can do this
  (the plan says `say` is needed; the code differs, 15 Nov 2026). `turnover-plugin check` warns about the missing
  `say`.
- On the person's own Mac a script may name a closed app (a browser, a terminal, a password manager, System
  Settings), but there it can only read and speak: acting is refused on any Mac, and what the person hears at approval
  says so.
- Approval is only as good as the user's reading of it. TurnOver cannot judge intent.
- A reviewer can miss something. A review lowers the risk; it does not remove it.
- Data plugins do not have receipts yet. Anything that can write to the plugins folder has a live data plugin within
  a second (the "Later" list in the plan).
- A data plugin's `abilities` field is a description, not enforced at load, and the library install trusts the
  signed list instead of running the checks itself (gaps 2 and 3 in the plan).
- JavaScriptCore is the Mac's own engine and carries its own risk if it has a flaw; the sandbox is the second line
  for that.
- A developer build keeps its sealing key in a file, so a program running as the person can forge an approval there;
  developer mode keeps a draft's approval while apps and abilities do not grow.
- A local build signed without the hardened runtime can be loaded with code by another program, which then is
  TurnOver, keeper and all.
- Scripts reach every app only with the `everywhere` ability, as above. Whether they may ever reach a website or the internet is not decided. This design says not yet.

## The reviewer's checklist for a script

For the library, which plugins need a reviewer, and how much of each version is read, is decided by "Review by risk" in
docs/PLUGIN-PLATFORM-PLAN.md: three levels, worked out from the abilities alone (`turnover-plugin check` prints the
level and why). A reviewer is never the author, and this also applies to TurnOver's own plugins. For a plugin at a
level that needs a reviewer, follow these steps for each version the level says is read, and read the author's reason
for each ability beside it: an ability with no believable reason is the first thing to question.

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
9. Check the apps. None may be one no script may name, and a closed app (a browser, a terminal, a password manager,
   System Settings) needs a reason the description gives. In a closed app a script can only read and speak, whatever
   its manifest asks for.
10. Run the plugin's tests (`turnover-plugin test <folder>`), and `turnover-plugin check <folder> --listing`. A script
    with no tests is a reason to ask for them. A test that passes proves what it tests and nothing more.
11. Check that the author's key (if signed) is the one the previous version used, or that the change is explained.
12. Record the hash you reviewed: the SHA-256 of that version's `manifest.json`, `profile.json` and `main.js`, as
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
