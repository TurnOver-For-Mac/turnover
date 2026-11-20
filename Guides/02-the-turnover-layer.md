# The TurnOver layer

TurnOver keeps its own commands behind one key, so it never takes a shortcut away from your apps: press
**Command Control Comma**, hear "TurnOver", then press a letter. It works in every app, including ones VoiceOver reads.

## The letters

| Letter | What it does |
|---|---|
| M | The TurnOver menu |
| S | The Settings window: every setting, sections down the side |
| T | Switches the app in front between TurnOver and VoiceOver, and remembers it (also straight away: Command Control Shift T) |
| D | Direct: every key goes straight to the app in front and neither TurnOver nor VoiceOver says anything there, for a game or app that speaks for itself. Command shortcuts (Command Tab, Command Q) still work. D again to leave; remembered |
| A | Who reads: TurnOver in its apps, TurnOver everywhere, or VoiceOver everywhere |
| V | Copies your VoiceOver settings: voice, speed, pitch, verbosity |
| K | Goes round the keyboard styles: VoiceOver keys, NVDA keys, JAWS keys |
| J | "That was wrong": marks this moment for your next feedback report |
| H | This guide |
| I | Describes the picture under TurnOver's cursor |
| C | Copies the last thing TurnOver said |
| G | Trackpad gesture control on or off (experimental) |
| R | Screen recognition: reads a window from the screen itself |
| Slash | Every shortcut that works where you are, in a list; Return runs one |

Any other key says the list again. Escape, or three seconds with no letter, cancels.

## Command Control Period

A single press starts or stops TurnOver from anywhere, even if TurnOver has stopped answering: a small helper,
TurnOver Key, listens for it from login.

## The TurnOver menu

- **This app:** who reads the app in front, and that app's own commands. Apps whose support is new say
  "experimental support".
- **Settings:** speech (with the say all voice), keyboard, braille, documents, web pages, sounds, and Experimental.
- **Apps:** which apps TurnOver reads.
- **Keys:** every shortcut, keyboard help, and your own keys.
- **Send feedback, About and updates, Quit.**

In the menu, Right or Return opens a submenu or changes a setting; on a number (rate, volume) Left turns it down.
Settings that restart TurnOver change only with Return.

## Sounds

In Settings, Sounds, "Whose sounds" chooses between VoiceOver's sounds and TurnOver's own. You can also add sounds of your own.

A sound set is a folder with one audio file for each thing TurnOver can sound, such as a boundary, pressing an item, a menu opening or a page finishing loading. The file's name, without its ending, says which event it is for, for example `boundary.wav`. Wav, aiff, aif, caf, m4a and mp3 files all work.

- **Open the sound sets folder:** a button beside the choice. It shows the folder, in Application Support, TurnOver, Sound Sets, and makes it if it is not there yet.
- **Make a starter set:** a button beside the choice. It makes a new folder, "My sounds" (then "My sounds 2" and so on), holding TurnOver's own sounds as wav files under the right names, and a "Read me.txt" that lists every event's file with a line about what it is.
- **Choosing a set:** every folder in the Sound Sets folder is listed in "Whose sounds" by its name, after VoiceOver's and TurnOver's. The list is read again each time the Sounds pane opens.

Replace any file with your own, keeping the name. Delete a file to get TurnOver's own sound for that event. A file with nothing in it means silence for that event. A file TurnOver cannot play counts as missing. To share a set, zip its folder; whoever you send it to unzips it into their Sound Sets folder. If a chosen set's folder is removed, TurnOver's own sounds play.
