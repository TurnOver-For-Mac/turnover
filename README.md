# TurnOver

A screen reader for the Mac.

Free and open source, made in spare time. If it helps you, [tip on Ko-fi](https://ko-fi.com/oliverkennett), no account
needed. GitHub Sponsors is coming.

TurnOver is a full screen reader: it reads every app, with its own voice and the keys you already know, VoiceOver's,
NVDA's or JAWS's. While it is on, VoiceOver is off; it turns VoiceOver off as it starts and back on as it quits, so
you are never without speech. Command Control Period starts and quits it, if you want VoiceOver for something.

Word was the reason it exists: writing in Microsoft Word on a Mac, with a screen reader that keeps up.

## The deal: a spare-time project

TurnOver is made by one blind developer, in spare time, and given away under the GPL. It works, and it's what I use
every day. But:

- **It's provided as-is.** No warranty, no support promise, no roadmap commitment.
- **Requests are welcome, and weighed, not queued.** Replies may take a week or two, or not come at all.
- **Fixes are the fastest way to get something changed.** See [CONTRIBUTING.md](CONTRIBUTING.md).

## Supporting TurnOver

If TurnOver is useful to you and you'd like to help cover its running costs, there's
[Ko-fi](https://ko-fi.com/oliverkennett), a one-off or monthly tip with no account needed; TurnOver's menu has Support
TurnOver, which opens it. GitHub Sponsors is coming once GitHub has approved the project's profile.

## Installing

Download the latest build from the [releases page](https://doll-eye.github.io/turnover-updates/). It runs on macOS 14
or later, on Apple silicon and Intel Macs. Move TurnOver to Applications and open it; a welcome explains the two
permissions macOS asks for (Accessibility and Input Monitoring). TurnOver updates itself. Every build is also on the
[releases page](../../releases), newest first, so you can go back to an earlier one if the newest breaks something:
download it, replace the app, and skip the newer one in TurnOver's menu, About and updates, Updates.

The [guides](https://doll-eye.github.io/turnover-updates/guide.html) cover getting started, the keys, reading, the
apps, the keyboard styles and troubleshooting.

The two keys to remember:

- **Command Control Comma** is the way in to everything: then M for the menu, S for settings, T to switch the app in
  front between TurnOver and VoiceOver, H for help. Any other key lists the letters.
- **Command Control Period** turns TurnOver off and on, from anywhere.

## Reporting a problem

Use the [issue form](../../issues/new/choose). Say what you were doing, what happened and what you expected. TurnOver's
menu has Send feedback, which saves a report you can attach; the log never keeps what you type, and you choose whether
it keeps what was read.

## Building it yourself

You need a Mac with Xcode 27 installed (the macOS 27 SDK; the command line tools alone aren't enough). The finished
app runs on macOS 14 or later.

```bash
git clone https://github.com/TurnOver-For-Mac/turnover.git
cd turnover
./build.sh --no-install
```

That compiles everything, runs the unit tests, and leaves TurnOver.app in ~/Library/Developer/TurnOver/build. Plain
`./build.sh` also installs it as /Applications/TurnOver.app and restarts it, replacing the TurnOver you have. Without a
signing certificate the app is signed ad hoc; macOS then asks for Accessibility and Input Monitoring again, because
the permissions belong to a signature.

The tests are a program of their own (`swift test` isn't used); `./build.sh --no-install` runs them, and so does:

```bash
~/Library/Developer/TurnOver/build/release/turnover-tests -v
```

A fork that publishes its own builds must change `SUFeedURL` and `SUPublicEDKey` in Resources/Info.plist: otherwise its
copies offer TurnOver's own updates.

## Developing

The loop is: edit, `./build.sh --no-install` (compiles everything and runs the unit tests, a minute or two; SwiftPM
rebuilds only what changed), then `./build.sh` to install the result as /Applications/TurnOver.app and restart it, and
read the newest log in ~/Library/Application Support/TurnOver/logs. The log is the main instrument: every key, what
was said (as lengths, never the words) and every event, with timings.

Don't run it with `swift run turnover`: TurnOver needs its app bundle (Info.plist, the helpers, the Settings app and
Key helper inside it, and a code signature the permissions are tied to), so a bare executable starts half-blind and
misbehaves. `turnover-coretest` (built with everything else) exercises the text and object layers against a running
app without speaking; TESTING.md has the rest.

## Where TurnOver stands

TurnOver is a **full replacement for VoiceOver**, from the first launch: one reader speaks at a time, as on every other
platform. It began as a reader that ran alongside VoiceOver (CoExist), and that went on 24 October 2026: it was
clever, but it confused things (discussion 46). You are still never without speech: VoiceOver comes back when TurnOver
quits, and if TurnOver hangs. Switching between the two is one key, and how often you do it is up to you.

TurnOver has its own settings (the Settings window, Command Control Comma then S). "Copy VoiceOver settings" is a
one-time import of your voice, rate, pitch, verbosity and typing echo, so a new user starts where they were; it is not
how settings are meant to be managed.

The plans in docs/ say which decisions are settled and which are open; docs/DECISIONS.md has this one.

## Finding your way around the code

- [docs/HOW-A-KEY-BECOMES-SPEECH.md](docs/HOW-A-KEY-BECOMES-SPEECH.md): the story of one key press, from the event
  tap to the voice, with the log line for each step. Start here.
- [docs/HOW-FOCUS-BECOMES-AN-OBJECT.md](docs/HOW-FOCUS-BECOMES-AN-OBJECT.md): how an app's focus change becomes
  something spoken, and where a rule for one app goes.
- [docs/LOG.md](docs/LOG.md): how to read a TurnOver log, the main instrument.
- [docs/DECISIONS.md](docs/DECISIONS.md): what is settled, what is parked, what is open.
- [ARCHITECTURE.md](ARCHITECTURE.md): the map from each mechanism to its files and tests.
- [TESTING.md](TESTING.md): the unit tests, recorded windows (fixtures) and the key driver.
- [PATTERNS.md](PATTERNS.md): how Mac apps misbehave for screen readers, and TurnOver's answers.
- [PLUGIN-GUIDE.md](PLUGIN-GUIDE.md): plugins, the reading rules and keys for an app, written as data.

The design borrows NVDA's object model (objects, text ranges, app modules, global plugins) and VoiceOver's keys. It
contains no code from either; see [NOTICE.md](NOTICE.md).

## Licence

TurnOver is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License
as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
See [LICENSE](LICENSE). Copyright 2026 Oliver Kennett and contributors.

The released builds are signed and notarised by the project. Copies built by others are theirs, not the project's.
