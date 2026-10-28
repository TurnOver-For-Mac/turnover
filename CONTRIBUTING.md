# Contributing to TurnOver

Thank you for wanting to help. TurnOver is maintained in spare time, a few hours a week, so the rules below are
mostly about not wasting your time or mine.

## Ways to help

- **Report a problem** with the [issue form](../../issues/new/choose): what you did, what happened, what you expected,
  your macOS version and keyboard style. One problem per issue.
- **Make a plugin** for an app TurnOver doesn't read well yet: reading rules, labels and keys, written as data. See
  [PLUGIN-GUIDE.md](PLUGIN-GUIDE.md). This is the easiest way in, and needs no Swift.
- **Fix something**, in the code or the guides (Guides/), with a pull request.
- **Test a change** someone else has proposed and say how it went, by ear.

## Finding your way in ten minutes

- [ARCHITECTURE.md](ARCHITECTURE.md): the map. Every mechanism with its files, its rule and its test. Read it once,
  top to bottom.
- [AGENTS.md](AGENTS.md): the house rules for a change (the main thread, deadlines, speech, what a commit says).
- [docs/HOW-A-KEY-BECOMES-SPEECH.md](docs/HOW-A-KEY-BECOMES-SPEECH.md) and
  [docs/HOW-FOCUS-BECOMES-AN-OBJECT.md](docs/HOW-FOCUS-BECOMES-AN-OBJECT.md): the two paths through the code, step by step.
- [docs/DECISIONS.md](docs/DECISIONS.md): why things are the way they are, dated.
- `Sources/TurnOverCore/Modules/`: one file per app. An app's quirk belongs there, never in shared code.
- The log (`~/Library/Application Support/TurnOver/logs`): what TurnOver saw and said. Most questions are answered
  there before the code.
- If you think the code is untidy, the **Code health** milestone on GitHub is the list of what to tidy. Each item
  changes no behaviour; one item or a few related ones go in a pull request.

## Before you write code

- **Build and run it the way the README's Developing section says** (`./build.sh`, not `swift run`), and read the
  log; most of what TurnOver does is only visible there.

- **Small changes**: just send the pull request.
- **Anything bigger** (a new feature, a change to how focus, speech, keys or the VoiceOver hand-over work): open an
  issue first and say what you have in mind. Those parts are shared by every app, and a change that helps one app
  can silently break another.
- **Moving app logic into app modules** is welcome, and is the direction the code is going: less special-casing in
  the core, more in `Sources/TurnOverCore/Modules/`. That work doesn't need to come as a string of tiny pull requests.
  Open an issue or a Discussion with the plan first, so two people don't move the same thing, then send it in a few
  larger pieces, an app or a mechanism at a time.
- **Keep what works.** TurnOver follows VoiceOver's keys in the Mac style and NVDA's in the Windows style. A change
  that alters what an existing key does needs a very good reason.

## Pull requests

- One purpose per pull request, with a sentence on what it does and how you checked it (by ear, a unit test, a
  recorded window). Several small fixes of the same kind, or a refactor that touches many files for one reason, can
  go together; list what's in it in the description, so it can be read piece by piece.
- `./build.sh --no-install` must build, and the unit tests must pass. The checks run them on every pull request.
- Add a test where you can: Sources/TurnOverTests has plain tests and tests against recorded windows (TESTING.md).
- Recorded windows must not contain anyone's private content: record Apple's own content, not mail, chats or
  documents.
- Match the code around you: its naming, its comment style (comments say why, and what was seen or measured; git
  already keeps who and when), and no new dependencies without asking first.
- Security matters more than usual here: a screen reader sees everything on screen and every key. Changes that touch
  keys, the network, files, permissions or the control channel get the closest review. TurnOver connects to one place,
  its update site; keep it that way.

Nothing is merged by itself, and not everything will be merged. If a pull request isn't a fit, I'll try to say why.

## Signing off your work (DCO)

TurnOver uses the [Developer Certificate of Origin](https://developercertificate.org): by adding a `Signed-off-by` line
to each commit, you certify that you wrote the change, or otherwise have the right to submit it under the project's
licence (GPL 3.0 or later). Git adds the line for you:

```bash
git commit -s -m "Word: the next table found when the cursor is in a heading"
```

There's nothing to sign beyond that line.

## Releases

Only the project's own builds are signed, notarised and offered through TurnOver's updates. Pull requests reach users
in the next release after they're merged.

## Behaviour

Be kind and be specific. Many people here use a screen reader every day and depend on it; a report that says exactly
what was heard is worth more than one that says it's broken. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
