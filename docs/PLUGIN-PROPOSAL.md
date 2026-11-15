# Proposal: plugins that carry scripts (16 Nov 2026)

This is put to TurnOver's contributors by the maintainer. It asks whether the design below is sound before it is switched on. It is meant to be read critically, and where something is unproven it says so.

## What is proposed, and what is asked of you

Today a plugin is a folder of rules: labels, keys and watches. The proposal is to let a plugin also carry one script, in JavaScript. The script would never run inside TurnOver. It would run in a separate small program that macOS locks in a sandbox with no files, no network and no other programs, and it could only ask TurnOver for things. Each thing it may ask for is a named ability, TurnOver says every ability aloud before the script runs, and TurnOver refuses any request outside what the person approved on their own Mac. The scripts are built and are off behind a setting.

We ask you to read this and the documents it names, try the sample plugin on the branch, and object, in a Discussion, to anything you think is unsafe or wrong. The questions the maintainer most wants answered are in the section on open questions.

## Why

NVDA's add-ons are a large part of why many people choose it. TurnOver aims to be that for the Mac. A plugin of rules can rename a control, silence a repeated announcement, bind a key to read or press one thing, and watch for a change. It cannot combine several items into one sentence, decide what to say from the state of a window, keep a note between uses, react to a timer, or act on one thing after looking at another. Those are the jobs people write add-ons for.

## What a plugin is and is not

CONTRIBUTING.md now separates three kinds of thing (16 Nov 2026).

The core is what every user needs and what reaches inside the screen reader: text, focus, speech, braille, the hand-over to VoiceOver, and the apps nearly everyone has. It is Swift, in this repository, by pull request.

A plugin is support for one app, a favourite shortcut, or a tool some people want and others do not. It is a folder of plain files, installed by choice, and its author looks after it. It may not start programs, load native code or touch files.

A companion program is a separate program in its own project that talks to TurnOver through its speech port. Anything that must install files elsewhere, run as its own program or stand in for another system's parts is a companion program, never a plugin.

## The central idea: named abilities, said aloud

A plugin never has full access. It has named abilities, checked on every request whatever its code says. Before a script first runs, the person hears which apps it works in, the author's own description marked as the author's, one sentence for each ability, what it can never do, a warning if it names a sensitive app, and "Nobody has checked this script. Approve it only if you wrote it or trust the person who did." The question offers "Not now" before "Approve", so a hurried Return cannot approve. The sentences for the abilities are:

- Read: "It can read what is on the screen in those apps, including text you have typed there, but never a password."
- Say: "It can speak, change or silence what TurnOver says in those apps, and play TurnOver's own sounds."
- Press: "It can press buttons and other controls in those apps."
- Focus: "It can move the keyboard focus to an item in those apps."
- Menu: "It can choose commands from those apps' menus."
- Keys: "It can press keys in those apps for you."
- Edit: "It can change the text or value of a field in those apps."
- Clipboard: "It can put text on the clipboard. It cannot read what is on it."

Every script also hears: "It can never use the internet, read or change your files, see the keys you press, see a password, or reach any other app." For passwords, settings, terminals and browsers it hears: "In those apps it can only read and speak. It can never press, type or choose anything there, whatever else it is allowed to do."

The decision of 16 Nov 2026 adds an author's reason: one sentence of up to 150 characters per ability, spoken after TurnOver's own sentence and marked as the author's words. It cannot replace TurnOver's sentence or widen anything. The library would require one for every ability above reading and speaking, and a reviewer questions first any ability with no believable reason.

## How this compares with NVDA

NVDA add-ons can do much that these cannot. They run as full Python inside the reader: files, network, programs, typed characters, the clipboard, their own windows and settings panels, every application at once, and speech and braille drivers. Of twelve real add-ons studied on 15 Nov 2026, three convert in part today, two more need scripts that work in every app, and seven cannot come across as written. All twelve were GPL licensed, so a converted plugin keeps its author, licence and origin.

NVDA's store does not review code. Its documentation says add-ons "do not undergo human security audits" (read 15 Nov 2026). A person checks once that a submitter owns the repository; after that the checks are automatic: format, a virus scan and a checksum. "Approved for NVDA" says who published a file and that it has not changed, not that it is safe.

These plugins add what NVDA's lack: a lock-down sandbox; approval on the person's own Mac after hearing what is allowed; a changed script no longer matching its approval; a faulty script cut off while TurnOver carries on; and a small interface with a version number in place of the reader's internals, where NVDA's yearly breaks disable add-ons. None of this makes a plugin safe. It narrows what a bad one can do and tells the person.

## The safeguards

The sandboxed host. Each script runs in its own program, which locks itself in a sandbox before reading anything from TurnOver; if that fails, no scripts run. The call, `sandbox_init`, is public but long deprecated, and browsers still use it. Measured on 14 Nov 2026 with a throwaway program, the sandboxed host could not open a file in the home folder, write to /tmp, connect to the local network or start a program. Start to first message took 13 to 35 ms, and an endless loop was killed in about 65 ms.

Abilities on every request. A request without its ability is rejected. An action also needs TurnOver's focus and the Mac's frontmost app both to be one of the plugin's apps. A password field is blank to a script and cannot be changed by one.

Forbidden and closed apps. No script may name the macOS password and permission dialogs, the login window or TurnOver. In closed apps (passwords, System Settings, terminals, browsers) a script may read and speak and never act. Both are checked at load and again on each request.

Approval receipts and the keeper. A script runs only with a receipt: the plugin's id, a hash of its files, its apps and abilities. A plugin arriving as files cannot bring an approval, and a receipt cannot be copied between Macs. Receipts are kept by the keeper, a sandboxed service inside the app that answers only the signed TurnOver. Measured on 15 Nov 2026: a fake app with the same identifier and a copy of the keeper was refused, as was an app from the same team with another identifier; but the same fake around a keeper built without the check did write a forged file, so that check is what stops it. Not tried: another program writing the keeper's container directly, because it would put a system question on screen. That rests on Apple's documentation for macOS 14 and later. A developer build keeps a sealed file instead, which a program already running as the person could forge, and says at start how many scripts are on.

Limits and strikes. A focus answer has 25 ms and a command 5 seconds. A host over 128 MB, or using over half a processor for ten seconds, is killed. Three strikes in ten minutes turn a script off for that run, and TurnOver says so by name.

Review by risk (decided 16 Nov 2026, replacing review of every version). Low risk, reading and speaking in named apps, has no reviewer. Higher, acting in an app or working everywhere, has one review of the first version and the author by a non-author; later versions asking for nothing new under the same key need none. Highest, reading private things together with a way to send them out, has a non-author read every version. An update asking for more goes to the person, who hears what is new; a changed key is said and asked about.

Withdrawal. A library plugin can be withdrawn, which turns it off on every Mac and removes a script's receipt.

Who looks after a plugin. The author does. The manifest gains a support address; each plugin gets "Report a problem with this plugin"; TurnOver's problem report lists plugins that were on; one menu item turns every plugin off until restart; and the library can mark a plugin unmaintained so someone else takes it over.

## What an independent review found

Reviewers who did not write the code read the scripts, host, broker and keeper. They found 8 high, 8 medium and 1 low problem. All were fixed, each with a test, in commit e7de10b on 15 Nov 2026, along with two gaps found when the documents were checked. The whole test runner then passed 762 tests.

The high problems included a plugin's rules taking effect before its script was approved, two ways ordinary search arguments could crash TurnOver, a Terminal plugin being able to run programs, menu items being pressable around menu policy, and a read-only script being able to silence speech.

What is not fully closed: keys are still sent to whichever app is in front, re-checked just before sending, so a switch in between is narrowed, not removed. The review also named three possible risks it could not establish (how the keeper confirms it is sandboxed, how a developer build is told apart, and a write after a pipe closes); the commit does not say they were settled, so treat them as open. PLUGIN-SECURITY.md lists the rest: approval says what a plugin can do, not what it will do; a script that can read can say aloud what it reads and keep it in a plain file other programs can read; speech is not yet marked with its source; data plugins have no receipts yet; and a reviewer can miss something.

## What is built, being built, and planned

Built, with tests, on the branch: the sandboxed host, the interface, approval, the keeper, the limits, signing, the `turnover-plugin` tool, the sample plugin and the documents. The platform decisions of 16 Nov 2026 (reasons, review by risk, support, the report item) are written in the platform plan; I could not confirm each is in the code.

Being built: a converter from an NVDA add-on to a draft plugin, and store browsing in the tool. The converter reads the add-on's Python as text and never runs it, checks the download against the store's checksum, writes a draft with only the abilities the original needed, and reports what carried over and what needs a person. It is unfinished.

Only planned, each with its own approval sentence: scripts for every app, options in TurnOver's menu, a list and a text prompt, tones, reading the selection and moving the caret, hearing what TurnOver says, reading the clipboard, and the library carrying scripts. Later and separately: the internet to named hosts, and files in a folder the person chooses.

## What this reverses

The decision of 20 Oct 2026, "Plugins are data", says no scripts run from a plugin. Switching this on reverses it for sandboxed scripts only. The maintainer thinks the reasons for the decision are still respected: the worry was code running inside a program that sees the whole screen and every key. Here no plugin code runs inside TurnOver, and the script has no files, network or programs, never sees a key or a password, and has only what the person heard and agreed to. If you think that reading is too generous, say so.

## Risks that remain, and open questions

The risks that remain are a person approving without listening, a script that misleads inside its own app, a flaw in JavaScriptCore or the sandbox, a reviewer who misses something, an author who disappears, and a keeper whose container protection rests on Apple's word. A converter also makes it easy to bring many add-ons across at once.

Questions for you:

1. Is review by risk acceptable, with no reviewer at the lowest level, or should a non-author read every script?
2. Is the person's own approval, with the statement that nobody has checked it, enough for a script outside the library?
3. Should the internet ever be an ability, even to named hosts, and never for a plugin that can read?
4. Should scripts ever work in every app?
5. Who reviews, and how are reviewers chosen?
6. Should TurnOver itself be allowed to show NVDA's store, given that it connects only to its own update site today?
7. Should converted add-ons be offered at all, given the store has no code review?
8. Is the closed-app rule, reading and speaking only, too strict or not strict enough?
9. Is anything not fully closed, above, a reason not to switch this on?

## How to try it

The work is on the branch `claude/plugin-scripts`. Switch scripts on, then restart TurnOver:

```
defaults write com.turnover.reader pluginScripts -bool true
```

The sample plugin is `plugins/examples/sample-script-calculator`, for Calculator. The tool's commands:

```
turnover-plugin check <folder> --listing
turnover-plugin consent <folder>
turnover-plugin test <folder>
turnover-plugin install <folder>
turnover-plugin verify <folder>
```

`consent` prints exactly what the person will hear at approval, so you can judge the sentences without running anything. `test` runs the script's tests in the real sandboxed program with no app. `install` copies the files and never approves. To hear the approval, turn on developer mode in the Plugins menu, bring Calculator to the front and choose the waiting item. The author's guide is docs/PLUGIN-SCRIPTS.md, the threats are in docs/PLUGIN-SECURITY.md, and the later decisions are in docs/PLUGIN-PLATFORM-PLAN.md.
