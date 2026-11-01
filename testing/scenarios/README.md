# Regression scenarios

These scripts drive a real Mac with the key driver and check what TurnOver said and which of its scripts ran. They're
the regression pass run before a release. [TESTING.md](../../TESTING.md) describes the pass in full; this page is what
you need before running it.

## Before you run

- **A developer build.** Install one with `./build.sh`, and close its welcome window. The scenarios read what was said
  from TurnOver's log, and only a developer build writes the words there.
- **The live folder.** Copy this folder to `~/Library/Developer/TurnOver/scenarios`. The scripts open their test files
  from there.
- **The tools.** Build the key driver and its helpers from [Tools/drivers](../../Tools/drivers/README.md) into
  `~/Library/Developer/TurnOver/tools`.
- **Hands off.** The runner waits for five idle minutes, then 90 seconds before each part, and stops as soon as you
  touch the keyboard.

## Running

```bash
zsh ~/Library/Developer/TurnOver/scenarios/regression/run.sh core layer
```

Name only the parts whose apps or keys your change touched. With no parts named, it runs them all, which takes a long
time.

- **core:** Finder, Mail, Messages, WhatsApp, TextEdit, Terminal, Music, the App Store and Word.
- **day1:** Calendar, Contacts, Freeform, Reminders, Shortcuts and System Settings.
- **day2:** Byword, Excel, Preview and Ulysses.
- **days45:** Bambu Studio, Cyberduck, Audible, Books, QuickTime Player and Voice Memos.
- **utilities:** Activity Monitor, Console, Disk Utility, Passwords, Script Editor and Xcode.
- **decisions, keypad, layer, keys, plugins:** TurnOver's own keys, in TextEdit, Calculator, Word, Messages and
  WhatsApp.

## What it does to your Mac

- **Your own apps.** The scenarios run in your apps with your accounts. Where an app holds personal content (Mail,
  Messages, WhatsApp, Passwords, Ulysses, Cyberduck and the like), they only move around. They don't type, open,
  send or delete anything.
- **Typing goes into test files only:** the files in this folder, a new Word document and a new Terminal window
  running `ls`. The runners put `files/parity.txt` back afterwards. If TurnOver misses a key, it can reach a test
  document as a stray letter, so check `scratch.rtf` now and then.
- **Settings come back.** The runner turns on TurnOver's speech log for the run. On exit, however it ends, it puts
  back the log setting, the keyboard style, the reading mode and the app that was in front.

## Results and privacy

- Each check prints a pass or a miss. Spoken words are masked in the report.
- TurnOver's log holds what was said, which can include what was on your screen. Keep it, and the runner's output,
  on your Mac. Read them before attaching anything to an issue.
- Read the log before calling a miss a regression. Most misses are the test, or the app's state at the time.

## Adding a scenario

The format is at the top of [scenario.py](../../Tools/drivers/scenario.py). Start a file with `app:`. Use `open:` with
a file in this folder (`~` is your home folder) or a new document, never your own data. In apps that hold personal
content, use moving keys only.
