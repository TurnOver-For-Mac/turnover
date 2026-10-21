# Reading a TurnOver log

The log is TurnOver's main instrument. It narrates the start, every permission answer, every key, the script the key
ran, every event TurnOver acted on and everything it said, with timings. Most questions about why TurnOver did or
did not do something are answered by reading the log, not the code.

## Where the logs are

~/Library/Application Support/TurnOver/logs, one file per launch, named turnover-<date and time>.log (UTC). Logs older
than 30 days are deleted at the next start. The newest is the one running now:

```bash
ls -t ~/Library/Application\ Support/TurnOver/logs/*.log | head -1
```

Each line starts with the seconds since TurnOver launched, in brackets, then a tag: IO for keys, events and speech,
WARN and ERROR for what went wrong, nothing for ordinary information. [Log.swift](Sources/TurnOverCore/Log.swift)
writes them.

## What is private by design

- **Typed keys are never written down.** A typed letter is logged as input (a typed key), nothing more.
- **The words TurnOver spoke are logged as lengths**: say: [37 characters]. Names of controls and windows the same:
  (12 characters). Only a developer's own Mac, with the logSpeech default on, keeps the words. A tester's log never
  holds the text of an email or a page.
- **Send feedback** (TurnOver's menu) makes a report that leaves the speech out unless you choose to include it, and
  says so when you do.

## The line kinds

**A key arrives.** The gesture's name, then the script it resolved to; no arrow means the key went on to the app.

```
[  481.299] IO input kb:command+downArrow
[  483.755] IO input kb:downArrow → list_downArrow
[  490.102] IO input (a typed key)
[  512.000] IO input kb:tab passed through
```

**A script runs.** Logged when it starts; (repeat N) is a second or third press within the multi-press timeout.

```
[  483.755] IO script list_downArrow for kb:downArrow
[  485.011] IO script list_downArrow for kb:downArrow (repeat 1)
```

**Something was said.** The length in brackets; the words on a developer's Mac. Private speech (typing echo) is
always a length.

```
[  483.795] IO say: [43 characters]
[  483.795] IO say: Reports, Today at 10:14, --, Folder, collapsed, 2 of 3
[  484.100] IO say: (private, 1 characters)
```

**An event from the application.** The kind, the raw role and the object's name (its length, or the words).

```
[  483.472] IO event selection: AXRow "(39 characters)"
[  491.706] IO event loseFocus: AXOutline "list view"
[  491.707] IO event gainFocus: AXOutline "list view"
[  520.001] IO event caret: AXTextArea ""
```

The kinds are in [Events.swift](Sources/TurnOverCore/Events.swift): gainFocus and loseFocus, focusEntered and
focusExited for ancestors, foreground, valueChange, nameChange, stateChange, caret, selection, textChange, alert,
menuStart and menuEnd, typedCharacter, liveRegionChange.

**A raw notification** that was noted but not turned into an event:

```
[ 5670.795] IO notification AXRowCountChanged: AXOutline ""
[  924.054] IO notification AXCreated: AXWindow ""
```

**A list explaining itself.** The list behaviour says what it did when the application did not answer as expected.

```
[54093.827] IO list: the list does not move its selection; TurnOver walks the rows itself
[54094.275] IO list: at the top
[54081.471] IO list: no selection change yet after downArrow
[31688.217] IO list: selected the first of 4 rows
```

**A slow script.** Over 100 ms: how long, how many accessibility questions it asked, and how long the application
took to answer them. A script that spent 4 ms of 309 in accessibility was waiting, not asking.

```
[54093.830] WARN script list_downArrow took 309 ms: 59 accessibility calls, 4 ms in them
[  700.120] WARN script finder_openNothing: its availability check took 28 ms
```

**The keyboard and the main thread.** The tap waited too long for an answer, or the tap was disabled and re-enabled.

```
[  900.500] WARN keyboard: kb:downArrow answered after 210 ms: sent on to the application now
[  901.000] WARN keyboard: tap disabled (6), re-enabling
```

**Coexisting with VoiceOver.** Which reader has the app in front, and why.

```
[ 1260.393] coexist: Tailscale in front is not a regular app; VoiceOver reads it
[   20.010] coexist: VoiceOver on; TurnOver reads its own apps now
```

**Applications.** Coming forward, and being observed for the first time.

```
[  924.168] IO app activated: Mail pid 29463
[53052.029] observing pid 51766
```

**The watchdog.** The main thread or the speech queue stopped; what was done about it. A relaunch starts a new log;
the new TurnOver is launched with the argument --after-hang and the old process id, ends the stuck copy, and logs
start: the TurnOver that hung (pid N) ended; this one takes over.

```
[ 3000.000] ERROR watchdog: the main thread has not run for 5 s; letting keys through and turning VoiceOver back on
[ 3010.000] ERROR watchdog: still stuck after 15 s; relaunching TurnOver
[ 2500.000] ERROR speech: the speech queue was stuck for 20 s; a fresh speech player in its place
```

## Following one key through a session

Pick the time the problem happened. The file's name holds the launch time (UTC), and a line's clock time is that
plus its seconds. Find the key, then read the lines around it:

```bash
L=$(ls -t ~/Library/Application\ Support/TurnOver/logs/*.log | head -1); grep -n "input kb:command+downArrow" "$L" | tail -5
```

```bash
sed -n '115850,115880p' "$L"
```

Read it as a conversation: the input line is the question, the script line is TurnOver's decision, the event line is
the application's reply, and the say line is the answer to the user. A missing line is the finding. No script after
the input means TurnOver passed the key and whatever happened next was the application's doing. A script with no
event after it means the application did not report the change, and the next list: or WARN line says what TurnOver
did about it. An event with no say means a rule decided it was not worth speaking (the same focus within half a
second, a value change on something other than the focus) and the reason is usually on the line before.

## What to attach to an issue

- **A report from Send feedback** in TurnOver's menu (Command Control Comma, then M). It saves a zip with the log on
  your Desktop, with the speech left out. The second choice keeps what TurnOver said and saves in TurnOver's reports
  folder instead, because that may be the text of emails and pages: attach it only if nothing private was read.
  Issues are public.
- **The time it happened**, as closely as you can, and what you pressed.
- **What you heard and what you expected**, in words. A report that says exactly what was heard is worth more than
  one that says it was broken.

The log never keeps what you type. Even so, read the file before attaching it if you are unsure.
