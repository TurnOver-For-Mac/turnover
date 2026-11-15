# Proposal: plugins that carry scripts (16 Nov 2026)

This is put to TurnOver's contributors by the maintainer. It asks whether the design below is sound before it is switched on. It is meant to be read critically, and where something is unproven it says so.

## What is proposed, and what is asked of you

Today a plugin is a folder of rules: labels, keys and watches. The proposal is to let a plugin also carry one script, in JavaScript. It would never run inside TurnOver, but in a separate small program that macOS locks in a sandbox with no files, no network and no other programs, and it could only ask TurnOver for things. Each thing it may ask for is a named ability, TurnOver says every ability aloud before the script runs, and TurnOver refuses any request outside what the person approved on their own Mac. The scripts are built and off behind a setting.

We ask you to read this, try the two sample plugins on the branch, and object, in a Discussion, to anything you think is unsafe or wrong. The questions the maintainer most wants answered are at the end.

## Why

NVDA's add-ons are a large part of why many people choose it, and TurnOver aims to be that for the Mac. A plugin of rules can rename a control, silence a repeated announcement, bind a key and watch for a change. It cannot combine items into one sentence, decide what to say from the state of a window, keep a note between uses, or act on one thing after looking at another. Those are the jobs people write add-ons for.

## What a plugin is and is not

CONTRIBUTING.md separates three kinds of thing.

The core is what every user needs and what reaches inside the screen reader: text, focus, speech, braille, the hand-over to VoiceOver, and the apps nearly everyone has. It is Swift, in this repository.

A plugin is support for one app, a favourite shortcut, or a tool some people want and others do not: a folder of plain files, installed by choice, looked after by its author. It may not start programs, load native code or touch files.

A companion program is a separate program that talks to TurnOver through its speech port. Anything that must install files elsewhere is a companion program, never a plugin.

## The central idea: named abilities, said aloud

A plugin never has full access. It has named abilities, checked on every request whatever its code says. Before a script first runs, the person hears which apps it works in, the author's own description marked as the author's, one sentence for each ability, what it can never do, a warning if it names a sensitive app, and "Nobody has checked this script. Approve it only if you wrote it or trust the person who did." The question offers "Not now" before "Approve".

There are now eleven abilities: read, say, press, focus, menu, keys, edit, clipboard, and the new everywhere, hearSpeech and clipboardRead. The author may give a reason for each, up to 150 characters, spoken after TurnOver's own sentence and marked as the author's. It cannot replace that sentence or widen anything.

The older eight sentences are in PLUGIN-SCRIPTS.md; read, say, edit and clipboard now also mention selected text and lines, tones and prompts, moving the cursor, and that reading the clipboard is separate. The three new ones:

- Everywhere: "It works in every app except passwords and permission dialogs, and its keys work in every app." With read as well, it adds that it can read what is on the screen wherever you are.
- Hear speech: "It hears what TurnOver says to you in those apps, as TurnOver says it, except in password fields. It cannot change it or stop it."
- Read the clipboard: "It can read what you copy: the text on the clipboard, while you are in those apps."

Every script also hears: "It can never use the internet, read or change your files, see the keys you press, see a password, or reach any other app." For a script that works in every app the last words are dropped.

### What the chooser sample says

This is what `turnover-plugin consent plugins/examples/sample-script-chooser` prints for the second sample, which lists the buttons of the window in front and presses the one you choose, in any app. The sentences are taken from the approval code in the newest commit; the copy of the tool at hand predates it and could not run on this manifest, so please run the command and compare.

- "Button chooser, scripted has a script. It works in every app you use, not only one, and goes on working whichever app you are in, except in password and permission dialogs and the login window. "Those apps" below means every app."
- "The author's own words about it: In any app, lists the buttons of the window in front, lets you choose one from a list, and presses it."
- The read, say and press sentences, with this after press: "The author says it uses this to: Presses the one button you chose from the list, and nothing else."
- "It works in every app except passwords and permission dialogs, its keys work in every app, and, because it can also read, it can read what is on the screen wherever you are."
- "The author says it uses this to: The list of buttons is wanted in whichever app you are in, not one app."
- "It can never use the internet, read or change your files, see the keys you press, or see a password."
- "In passwords, settings, terminals and browsers it can only read and speak. It can never press, type or choose anything there, hear what TurnOver says there or read your clipboard there, whatever else it is allowed to do."
- "Nobody has checked this script. Approve it only if you wrote it or trust the person who did."

It then prints review level 2.

## How this compares with NVDA

NVDA add-ons run as full Python inside the reader, with files, network, programs, typed characters and speech and braille drivers. Of twelve real add-ons studied on 15 Nov 2026, three convert in part, two more need every-app scripts (now built), and seven cannot come across as written. All twelve were GPL licensed, so a converted plugin keeps its author and licence.

NVDA's store does not review code: its documentation says add-ons "do not undergo human security audits" (read 15 Nov 2026). "Approved for NVDA" does not mean safe.

These plugins add a sandbox, approval on the person's own Mac after hearing what is allowed, approval lost when a script changes, and a faulty script cut off. None of this makes a plugin safe. It narrows what a bad one can do and tells the person.

## The safeguards

The sandboxed host. Each script runs in its own program, which locks itself in a sandbox before reading anything from TurnOver; if that fails, no scripts run. The call, `sandbox_init`, is long deprecated, though browsers still use it. Measured on 14 Nov 2026 with a throwaway program, the sandboxed host could not open a file in the home folder, write to /tmp, connect to the network or start a program.

Abilities on every request. A request without its ability is rejected. An action also needs TurnOver's focus and the Mac's frontmost app both to be one of the plugin's apps. A password field is blank to a script and cannot be changed by one, and a list or typed line is refused over it.

Forbidden and closed apps. No script may name the macOS password and permission dialogs, the login window or TurnOver, even with everywhere. In closed apps (passwords, System Settings, terminals, browsers) a script may read and speak and never act, and hearSpeech and clipboardRead are refused.

Approval receipts and the keeper. A script runs only with a receipt: the plugin's id, a hash of its files, its apps and abilities. A plugin arriving as files cannot bring an approval, and a receipt cannot be copied between Macs. Receipts are kept by the keeper, a sandboxed service that answers only the signed TurnOver. Measured on 15 Nov 2026: a fake app with the same identifier and a copy of the keeper was refused, as was an app from the same team with another identifier; around a keeper built without the check the fake did write a forged file, so that check is what stops it. A developer build keeps a forgeable sealed file instead.

Limits and strikes. A focus answer has 25 ms and a command 5 seconds. A host over 128 MB, or over half a processor for ten seconds, is killed. Three strikes in ten minutes turn a script off for that run, and TurnOver says so.

Review by risk, now worked out from the abilities by the tool, which prints the level and why in `check` and `consent`. Level 1, reading and speaking in named apps, has no reviewer. Level 2, acting in an app, writing the clipboard or working everywhere, has one review of the first version and the author by a non-author; later versions asking for nothing new under the same key need none. Level 3, today hearSpeech or clipboardRead, has a non-author read every version. An update asking for more goes to the person, who hears what is new; a changed key is said and asked about.

Withdrawal and who looks after a plugin. A library plugin can be withdrawn, which turns it off on every Mac. The manifest has a support address, each plugin has "Report a problem with this plugin" in the Plugins menu, TurnOver's problem report lists plugins that were on, and one menu item turns every plugin off until TurnOver starts again.

## What an independent review found

Reviewers who did not write the code read the scripts, host, broker and keeper. They found 8 high, 8 medium and 1 low problem, all fixed with a test in commit e7de10b on 15 Nov 2026. The high ones included a plugin's rules taking effect before its script was approved, two ways ordinary search arguments could crash TurnOver, and a Terminal plugin being able to run programs.

A further pass found one more fault, now fixed with a test: a script host that ended by itself left its input open, so a late write could reach a closed file number.

One finding was tested and is not a leak. It was feared that a script's search could reveal what a password field holds; a test shows a search never matches on a password field's value.

Two items cannot be settled without a signed build. The keeper decides whether it is sandboxed by a test of its home folder and environment, which guards against a mistake and is not proof of confinement; only a live signed build can show that (`turnover --check-trust-keeper`). And a developer build is told apart by reading its Info.plist, so a changed Info.plist in a copy that keeps its permissions could pick the developer file; again only a live signed build can show whether that works. Both stay open.

What is not fully closed: keys go to whichever app is in front, re-checked just before sending, so a switch in between is narrowed, not removed. PLUGIN-SECURITY.md lists the rest: approval says what a plugin can do, not what it will do; a script that can read can say aloud what it reads and keep it in a plain file other programs can read; and a script with read alone can still change what TurnOver says on a focus change.

## What is built, and what is only planned

Built, with tests, on the branch (the whole runner passes 819 tests): the sandboxed host, approval, the keeper, limits, signing and the tool; scripts for every app; options in TurnOver's own menu; a list and a typed line; tones; text and caret; hearing speech; reading the clipboard; the author's reasons, support address, Report a problem and the item that turns every plugin off; the review level from abilities; and the converter and store browsing.

Only planned: the library carrying scripts, with the reviewer recorded for levels 2 and 3; the internet to named hosts and files in a folder the person chooses, each as its own ability by its own decision; and AI writing the bodies of converted add-ons.

## What the converter does today, honestly

The converter never runs an add-on's code; it reads the Python as text. It takes an add-on by its id in NVDA's store, checked against the store's checksum, or a file or folder you have. It writes a draft plugin and a report of what carried over, what a person must finish and what can never come across, and keeps the creator, licence and converter's name. The abilities are worked out from the original's calls and recorded; `check` refuses a converted plugin that asks for more, and the approval question says whose add-on it was.

It was tried on two real add-ons. In both, the commands, the keys, the credit and the abilities carried over. The code inside each command did not: each handler is a stub holding the original Python as a comment, for a person to write. It translates a statement only where one table says the translation is exact, and guesses at nothing. So today a conversion is a head start and a clear report, not a working plugin. App modules arrive with no app, because they name a Windows program. AI writing the bodies is planned, not built, and would pass through the same record, check and approval.

`store list` and `store search` give each add-on a verdict ("can be converted", "needs work", "not for the Mac" or "not looked at yet"), from an earlier conversion on your Mac or plain signs in the store's entry.

## What this reverses

The decision of 20 Oct 2026, "Plugins are data", says no scripts run from a plugin. This reverses it for sandboxed scripts only. The maintainer thinks its reasons are still respected: the worry was code running inside a program that sees the whole screen and every key. Here no plugin code runs inside TurnOver, and the script has no files, network or programs, never sees a key or a password, and has only what the person approved. If that reading is too generous, say so.

## Risks that remain, and open questions

The risks that remain are a person approving without listening, a script that misleads inside its own app, a flaw in JavaScriptCore or the sandbox, a reviewer who misses something, an author who disappears, and a keeper whose protection rests on Apple's word.

Questions for you:

1. Is review by risk acceptable, with no reviewer at the lowest level?
2. Is the person's own approval enough for a script outside the library?
3. Should the internet ever be an ability, even to named hosts?
4. Is working in every app acceptable now that it is built, and are hearSpeech and clipboardRead rightly at the highest level?
5. Who reviews, and how are reviewers chosen?
6. Should TurnOver itself show NVDA's store, given that only the command line tool does so today?
7. Should converted add-ons be offered at all, given the store has no code review?
8. Is the closed-app rule, reading and speaking only, right?
9. Are the two items that need a signed build a reason not to switch this on yet?

## How to try it

The work is on the branch `claude/plugin-scripts`. Switch scripts on, then restart TurnOver:

```
defaults write com.turnover.reader pluginScripts -bool true
```

There are two samples: `plugins/examples/sample-script-calculator` for Calculator, and `plugins/examples/sample-script-chooser` for any app, with three options. The tool's commands:

```
turnover-plugin check <plugin folder> [--read] [--listing] [--level Community|Verified|Official]
turnover-plugin consent <plugin folder>
turnover-plugin test <plugin folder>
turnover-plugin install <plugin folder>
turnover-plugin verify <plugin folder>
turnover-plugin new <new folder> --everywhere
turnover-plugin convert <add-on id | .nvda-addon file | folder> [--out <folder>] [--force] [--channel stable|beta|dev] [--report-only] [--converted-by "<name>"]
turnover-plugin store list | search <words> | show <id>   [--json] [--hide-not-mac] [--channel stable|beta|dev]
```

`consent` prints what the person will hear at approval. `test` runs the script's tests in the real sandboxed program. `install` copies the files and never approves. `convert --report-only` writes nothing. `store` and `convert` make their own request to NVDA's store. To hear the approval, turn on developer mode in the Plugins menu, bring an app to the front and choose the waiting item. The author's guide is docs/PLUGIN-SCRIPTS.md, the threats are in docs/PLUGIN-SECURITY.md, the decisions are in docs/PLUGIN-PLATFORM-PLAN.md, and the converter is in docs/FROM-JAWS-AND-NVDA.md.
