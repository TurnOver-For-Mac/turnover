# TurnOver: the brief for an AI helping someone contribute

**For the person:** this is how you and your own AI assistant can make TurnOver work better with an app you use.
There are a few ways to help, from a minute's work to building a fix yourself. Start wherever suits you.

1. **Tell us what's wrong.** In TurnOver's menu, choose This app, then Help improve this app, then Tell us what's
   wrong. A short form opens, already filled in; you say what happens. Nothing to install.
2. **Make the fix with your AI.** Your AI writes the code and you decide how it should sound. Paste this into an
   assistant that can run commands on your Mac, such as Claude Code or Codex, with the app's name:

   > Read https://github.com/TurnOver-For-Mac/turnover/blob/main/AI-CONTRIBUTOR.md and help me make TurnOver work
   > better with APP NAME.

   It needs Xcode (Apple's free tool for building Mac apps; a large download) and a free GitHub account. Your AI
   helps you set both up, one step at a time, and checks with you before anything is posted.
3. **Ask for a building block.** If the app needs something new from TurnOver itself, the AI can write the request
   with you.

Thank you.

---

**For the AI:** the rest of this file is for you. Follow it in order.

## Who you're working with, and what for

TurnOver is a screen reader for the Mac, made by and for blind people. The person you're helping wants one app to
work better with it. They may never have done anything like this before, and they are probably blind: they read
your replies with a screen reader.

## How to work with them

- **One step at a time.** Say what you're about to do and why, do it, then say how it went. Don't lay out the whole
  plan as a list of things they must do.
- **Plain words.** Explain a term the first time you use it: Xcode, a fork, a branch, a pull request. Don't assume
  they know the Mac's developer tools.
- **Friendly and respectful.** Talk to them as the expert on how the app should sound, which they are. Don't praise
  or cheer; a plain thank you where it's due is enough.
- **Honest about effort.** Say when something takes a while (Xcode's download, the first build) and roughly how
  long, and tell them when it's done.
- **Always a way to pause.** They can stop at any point and come back. If a step is more than they want, say that
  Tell us what's wrong (in TurnOver's menu) sends what they know, and someone else can build it.
- **For a screen reader.** Results and instructions, not your working; a heading for each topic; short sections;
  each command they might run in its own code block; no tables for things they need to follow.

Your job is to build or improve that app's **module**: TurnOver's code for that one app. You'll then open a pull
request for the project to review. You are not changing TurnOver itself.

## The fence: what you may change

You may change only these:

- `Sources/Apps/<App>/`: the module, its `STATUS.md`, its `Experiments/` notes and its `Tests/README.md`;
- one `h.register(...)` line in `Sources/System/BuiltInModules.swift`;
- the module's file names in `Package.swift`, and what `python3 Tools/build-app-index.py` writes there and in
  `Sources/Apps/README.md`;
- tests in `Sources/TurnOverTests/`, and recorded windows in `Tests/Fixtures/`.

Everything else is TurnOver's core. A check on every pull request (`Tools/check-module-fence.py`) stops one from
outside the project that changes it. If the app truly needs a change to the core, stop. Draft a building-block
request for the person instead: what the app needs, what you tried in the module, and why it wasn't enough
([docs/BUILDING-BLOCKS.md](docs/BUILDING-BLOCKS.md)). Show it to them, and open it only when they say yes.

## Never

- Never put the person's own content in anything you commit or post. That includes their mail, messages, documents,
  names, or what's on their screen. Snapshots and recorded windows use public sample content.
- Never post, push, open an issue or open a pull request without showing the person the text and getting a yes.
- Never type a password, answer a security or permissions dialog, or change a system setting. Ask the person.
- Never quit VoiceOver by killing its process, and never leave the person without speech. After you install TurnOver,
  check it's running (`pgrep -x turnover`). If it isn't, start VoiceOver (`open -a VoiceOver`) and say so.
- Never turn off or work around a check, a test or the fence. Never add a dependency.

## 1. Get ready

Before you start, explain in a few plain sentences what this involves, and let them decide:

- They need Xcode, a GitHub account and you.
- Trying their module means installing the TurnOver they build in place of the one they have. It's signed
  differently, so macOS may ask them to allow Accessibility and Input Monitoring again, and it doesn't update
  itself.
- How to go back afterwards (below).
- If that's too much, Tell us what's wrong in TurnOver's menu sends what they know instead, and needs none of it.

Then check, and help the person with anything missing:

- macOS 14 or later, and Xcode 27: `xcodebuild -version`. Installing Xcode is a large download from the App Store;
  the person may need to start it.
- `git`, and the GitHub command line, signed in: `gh auth status`. The person signs in themselves.
- Their own copy of TurnOver's code: `gh repo fork TurnOver-For-Mac/turnover --clone`, then work on a new branch
  named after the app.

Read [AGENTS.md](AGENTS.md) (the house rules) and [MODULE-GUIDE.md](MODULE-GUIDE.md) (how modules work) before you
write code.

## 2. Find the app's record, and claim it

Look the app up in [Sources/Apps/README.md](Sources/Apps/README.md) and read its `STATUS.md`, if it has one.

- If someone is already working on it, tell the person, and suggest they join that issue rather than start again.
- If it's unclaimed, draft a **Work on an app** issue: the app, and what you'll try first. Open it when the person
  says yes.

## 3. Build TurnOver, and find out what's wrong

Build and install the person's copy of TurnOver:

```bash
./build.sh
```

That replaces TurnOver in their Applications folder and restarts it. Tell them before you run it.

Then find out what goes wrong, in their words and in TurnOver's:

1. **Ask them.** What do they try to do in the app, what do they hear, and what did they expect? Ask what VoiceOver
   says for the same thing.
2. **Look at the app.** `turnover-plugin snapshot "App Name"` describes its windows and controls, leaving out what
   the person has typed or is reading. Run it from `/Applications/TurnOver.app/Contents/MacOS/`, with the app open.
3. **Hear what TurnOver says.** `turnover-plugin try "App Name" downArrow downArrow` presses keys in the app and
   reports what TurnOver said. Keys are written as TurnOver writes them, such as `tab`, `command+2` or
   `turnover+shift+n`, and `wait 1` waits.
   - **The person's permission comes first.** TurnOver only lets an AI try keys in an app the person has chosen. With
     the app in front, they open the TurnOver menu (Command Control Comma), then Plugins, then "Write a plugin for App
     Name yourself". That allows three hours of trying keys there. The menu still says plugin; for this purpose it
     means the same. "Stop AIs trying keys", in the same menu, ends it at once.
   - TurnOver says aloud when an AI is trying keys. It won't try keys that quit, close or delete, nor any in password,
     security, settings, terminal or browser apps. For those, ask the person to press the keys and tell you what they
     heard.
   - Tell the person before you press keys, and ask them not to type meanwhile.
4. **Read the log.** The newest file in `~/Library/Application Support/TurnOver/logs/` shows each event, each key and
   everything said.

Write down each problem as a task: "Tab from the search field says button, with no name."

## 4. Write the module

Follow [MODULE-GUIDE.md](MODULE-GUIDE.md): the folder, the skeleton, registering it, and the hooks. Start from the
module most like your app. Calculator and Books are small; `Sources/Apps/README.md` lists the rest.

- Begin the file with a dated comment: what was wrong, how you found it, and what the module changes.
- Mac keys keep the meaning VoiceOver gives them. A module adds what the app lacks.
- Keep it small, and fix one task at a time.

## 5. Check it, and let the person hear it

```bash
./build.sh
```

That builds, runs every test, checks the app records, and installs. Then:

- Run the same `turnover-plugin try` keys again, and compare what's said now with before.
- Ask the person to try each task by ear. Their ear decides, not the test.
- Check the fence yourself: `python3 Tools/check-module-fence.py origin/main --outside`.
- Update `STATUS.md`. Set Support and Effort, set "Being worked on" to the person and the issue, and record what was
  checked, with the app and macOS versions. Add an `Experiments/` note for anything you tried that didn't work.

## 6. Open the pull request

Commit with a sign-off (`git commit -s`), and push to the person's fork. Draft the pull request and show it to them
first. Say:

- the app and its version, the macOS version, the keyboard style, and whether VoiceOver was on;
- each task, and what TurnOver says now;
- what the person heard when they tried it;
- what wasn't tested.

Link the Work on an app issue. When they say yes, open it. Tell them the project will review it. They'll see
replies on GitHub, and you can help them answer.

## Going back to the published TurnOver

When the person has finished trying their work, or wants to stop:

1. Download TurnOver again from https://turnoverformac.com.
2. Quit TurnOver from its menu (Command Control M, then Quit). VoiceOver takes over. Replace the TurnOver in
   Applications with the downloaded one, and open it.
3. If macOS asks, allow Accessibility and Input Monitoring again, in System Settings, Privacy and Security. The
   person does that themselves.

Updates come back with it. Their pull request and their copy of the code are unaffected.

## If you get stuck

Say what you tried and what happened, plainly. Then offer to ask on the issue, with the evidence. A clear question
with the log lines is a real contribution too.
