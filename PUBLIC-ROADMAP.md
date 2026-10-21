# What's coming to TurnOver

TurnOver is free and open source, made in spare time. This is what's being worked on and what people have asked
for. Requests are weighed, not queued, and there are no dates or promises: things arrive when they're solid, and
sooner if someone sends a fix. To ask for something, use the idea form on GitHub (Send feedback in the TurnOver menu
opens it).

TurnOver works alongside VoiceOver. VoiceOver stays on: TurnOver reads every app by default, and Command Control Shift
T gives the app in front to VoiceOver, or back. VoiceOver always handles security (password fields, Touch ID, macOS's
own prompts). There are keyboard styles for VoiceOver's keys and NVDA's, with Narrator's and JAWS's on the way.

## Plugins: coming back, in the open

Plugins are the reading rules, keys and labels for an app, written as data. They were parked while TurnOver was
closed, because a way to load other people's rules into a screen reader needs care. In the open, plugins arrive as
pull requests to the repository, where anyone can read them and they are reviewed before they ship with TurnOver.
PLUGIN-GUIDE.md says how to write one.

## Next

- **The Windows style everywhere, even where VoiceOver reads.** NVDA's keys on top of VoiceOver in every app, not
  only in TurnOver's. You could even let VoiceOver read every app and still use the Windows style's keys.
- **Trackpad parity.** The trackpad already drives TurnOver in its apps. Next, every gesture behaving as it should for
  your keyboard style: VoiceOver's Trackpad Commander in the Mac style, NVDA's touch gestures in the Windows style.
- **Apple's own apps, one at a time.** Pages and Numbers first, then Preview, Photos, Calendar, Contacts, Reminders
  and Keynote, and on through the rest. Finder and System Settings come last, and only where VoiceOver falls short.

## Soon

- **A key mapping manager** in the Settings window: every command by category with its keys; add, change or remove
  keys; clashes with VoiceOver's or NVDA's keys pointed out; hybrids of the styles, saved as profiles; a quick switch
  between profiles, or a profile that comes on by itself for an app, as VoiceOver's Activities do.
- **A verbosity manager**: the order in which an item's pieces are said, and which are said at all, set per app.
  In Mail, for example, subject first, then sender, then the time, or any order you like; the same for lists in
  other apps.
- **Your VoiceOver scripts, on keys.** AppleScripts written for VoiceOver ("tell application VoiceOver to output")
  run as they are with TurnOver speaking, and each can go on a key, as with VoiceOver's Keyboard Commander.
- **Voices.** A tidy list (the voices for your languages, best quality first), and changing voice, rate and pitch on
  the fly with VoiceOver's or NVDA's own keys.
- **Sounds one by one.** Each of TurnOver's sounds on or off, or your own; positional sound with an off switch.
- **The rotor in text:** moving by formatting (bold, italic), sentence, line and paragraph.
- **Tables in TextEdit:** moving cell by cell with the keys.
- **Finder's icon view:** each item's position ("3 of 12").
- **Safari:** landing on the page where VoiceOver does.

## Later, asked for

- **Reset, backup and restore:** reset keys, settings or everything; back up to a file and restore it.
- **Word:** arrows inside table cells with several lines.
- **Google Docs, Sheets and Slides:** the Windows style's cursor keys everywhere in them.
- **Image descriptions** on more web pages.
- **Arabic typing** read back in every browser and editor.
- **NVDA's** mouse tracking, progress bar beeps, review modes, setting table headers by hand, maths, annotation
  details and magnifier.
- **VoiceOver's** interactive tutorial, caption and braille panels, and the keypad's last keys.
- **Steam's Windows games** under CrossOver, in TurnOver's Steam support.

## Asked for, suited to plugins one day

- **ChatGPT and Codex:** the apps read cleanly, quick keys both ways.
- **Microsoft Excel:** row and column announcements as you move.
- **iPhone Mirroring.**
- **Music, TV and Podcasts:** more beyond what TurnOver reads now.

## In build 20

- VoiceOver stays on alongside TurnOver, silenced only where TurnOver reads, and it handles every security window.
- Command Control Comma is the way in to everything: M for the menu, S for the Settings window, T to switch an app
  between TurnOver and VoiceOver. Command Control Period turns TurnOver off and on.
- The Settings window, with every setting; one Quick Nav shared with VoiceOver; spelling corrections in any edit box;
  Direct mode for games and apps that speak for themselves; apps can ask to speak through TurnOver; Kindle; Outlook
  without a plugin; the Privacy and security guide.
