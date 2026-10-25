# How a key becomes speech

The story of one key press, from the keyboard to the voice. ARCHITECTURE.md is the map of files; this is the
journey through them. Every step leaves a line in the log, and [LOG.md](LOG.md) explains how to read those lines.

The short version: a tap on the keyboard thread sees the key, asks the main thread whether TurnOver has a script
for it, and either swallows it (the script runs) or lets it go on to the application. A script that moves something
sends the key on itself and waits for the application to report the change, then speaks it.

## 1. The tap sees the key

[KeyboardHandler.swift](Sources/TurnOver/KeyboardHandler.swift) installs an event tap at the HID level, on a thread
of its own with its own run loop, so a busy main thread can never delay a keystroke or get the tap disabled. The
method tapEvent is called for every key down, key up and modifier change on the Mac. In order, it:

- **Lets everything through when bypassed.** The watchdog sets the static bypass flag while the main thread has
  stopped running, so the keyboard keeps working: the tap returns every event untouched until the thread is back.
- **Re-enables itself** if macOS disabled the tap for taking too long, and says so after three times in ten seconds.
- **Lets its own keys by.** A key TurnOver posted carries a marker in the event's user data (the static marker);
  the tap passes it without looking again. That is how a script sends a key on without TurnOver seeing it twice.
- **Handles the modifier keys on their own** (the flagsChanged branch). Caps Lock is the TurnOver key when the
  setting says so, and its own event never reaches an app. Control pressed and released alone pauses or stops speech.
  In the Windows style, Command alone opens the menus and Option alone the context menu or the Dock, as the
  Windows keys do.
- **Gives a direct process its keys** (a game in front: the directPid in the input manager).
- **Keypad and Quick Nav arrows.** The keypad method handles the numeric keypad commands; the quickNavArrow method
  holds a bare arrow while TurnOver's own Quick Nav is on so that two arrows pressed together make a chord.
- **Drops an echo loop.** The same key code arriving three times within 8 ms is nobody's hand: the copies are
  dropped and an error line names the process that posted them.
- **Builds a KeyboardGesture** from the key code, the modifiers (Caps Lock held becomes the turnover modifier;
  Control and Option together become it when that setting is on), the characters and whether it is a repeat.
  Gestures are named like NVDA's: kb:command+downArrow, kb:turnover+t.
- **Translates a Windows key** in the Windows style, when TurnOver has no script of its own for it: Control C
  becomes Command C, Control Left becomes Option Left. The release is translated to match (the remapped set).
- **Asks the main thread** (next section) and acts on the answer: taken or deferred means the key is swallowed and
  its key up is swallowed too (the quarantined set, so the application never sees a release without a press);
  passed means it goes on.
- **Passes.** A key TurnOver does not take is returned to the system unchanged.

## 2. The main thread decides

The tap cannot read the object model (that lives on the main thread), so it asks. The askMain method in
[ScriptHandler.swift](Sources/TurnOverCore/ScriptHandler.swift) hands the gesture to the main thread and waits up
to the lookupLimit, 0.15 s. Normal answers take microseconds. If the main thread is late, the key is swallowed now
(deferred) and when the answer comes the script runs or the key is re-posted, with a warning line saying how late.
Only a main thread that has stopped beating altogether (the watchdog's view) lets keys straight through.

On the main thread, handleKeyDown in [InputManager.swift](Sources/TurnOverCore/InputManager.swift) runs. In order:

- **A capture** (the keyboard commands editor waiting for a key) takes the key outright.
- **Pass next key** (the command that lets one key through untouched) lets it go and logs passed through.
- **Every key stops speech**, as NVDA does, except a typed key while only the typing echo is speaking.
- **The script is looked up** with findScript (next section) and the key is logged: input kb:… with the script's
  name after an arrow, or input (a typed key) when it is typing. A typed key is never written down.
- **A password guard**: typing while TurnOver's focus is a password field in an app that does not have the keyboard
  is held back and spoken about.
- **TurnOver's own screens first**: screen recognition, the find prompt, the TurnOver menu and keyboard help each
  take the key when they are open; a Command key closes them and goes on to the app.
- **Sleep mode**: an app the user has put to sleep gets every key but the wake key.
- **The script is queued** with queueScript and the answer is taken; otherwise the answer is passed, the clipboard
  announcer looks at it, and a typed character becomes a typedCharacter event for the focus (that is how typing is
  echoed: from the key, never read back from the caret).

## 3. Finding the script

findScript in ScriptHandler.swift asks, in this order, and the first answer wins:

1. **The user's own keys** (UserGestures): a key the user gave to a command, or took away.
2. **The style's table** (StyleKeymap): Narrator and JAWS keys mapped onto TurnOver's commands.
3. **Global plugins**: VoiceOver's keys and NVDA's keys live here.
4. **The app module** for the focused process (FinderAppModule and the rest, under Sources/TurnOverCore/Modules).
5. **The document**, when browse mode or a text document is intercepting (the focusTreeInterceptor).
6. **The focus object** itself, then its ancestors for scripts marked canPropagate.
7. **The global commands** (GlobalCommands.swift): everything that works everywhere.

A Script, defined in [Scripts.swift](Sources/TurnOverCore/Scripts.swift), is a name, a description for keyboard
help, a category, the handler to run and an optional isAvailable check. Several scripts may share a key, each with
its own availability; the first available one runs. An availability check that talks to the application and takes
more than 15 ms is logged by name, so slow checks are found rather than guessed.

Scripts run one at a time on the main thread (executeScript). Each run is logged as script name for key, with
(repeat N) for a second press within the multi-press timeout, and a warning when the script took more than 100 ms,
with the number of accessibility calls it made and how long they took.

## 4. A script that moves something

Most scripts do not do the work themselves; they let the application do it and then read the result. The list
arrows are the example. SelectableList in [SelectableList.swift](Sources/TurnOverCore/SelectableList.swift) is the class for a
list, table or outline that moves its own selection. Its initOverlay declares a script per key (list_downArrow,
list_upArrow, list_home and so on). The moveSelection method:

- sends the key on with the gesture's send method, which hands it to the post method in KeyboardHandler.swift.
  That posts the key down and up at the HID level with TurnOver's marker, lifting any modifier the hand still holds that the key must not carry, and putting it back
  after;
- then waitForSelection pumps the run loop for up to 0.3 s until a selection or focus event from the application is
  pending (EventHandler.isPending). The event, when it comes, reads the new row;
- with nothing selected yet it selects the first row itself through accessibility; at the top or bottom it sends
  the key and does not wait; in a list that ignores the arrows it walks the rows itself; in an empty one it says so.

The same shape is everywhere: EditableText in [EditableText.swift](Sources/TurnOverCore/EditableText.swift) sends a caret key on and waits for the
caret to move before speaking the line, word or character at the new place.

## 5. Speech

[Speech.swift](Sources/TurnOverCore/Speech.swift) is the one door to the voice:

- **speakMessage** says TurnOver's own words (a message; it reaches braille as a message too).
- **speakObject** says an object as the focus: objectPropertiesSpeech builds the pieces (name, role, value, states,
  position), speakObject adds the selected row of a list or its count, then the text at the caret for text fields.
- **joined** turns the pieces into one line: commas in the Mac family, as VoiceOver reads, and spaces in the
  Windows family, as NVDA does, so the voice does not pause at every piece.
- **enqueue** is where every line ends up. It splits text by language, hands the cleaned text to the sink (the
  tests listen here), then stops if the speech mode is off or beeps, or if VoiceOver is on. What remains is logged as say: and queued on the SpeechPlayer in
  [SpeechPlayer.swift](Sources/TurnOverSpeech/SpeechPlayer.swift), which runs the voice on its own thread.

## 6. The worked example

Finder, list view, Down Arrow on a row. The log shows the whole journey:

```
[54085.010] IO input kb:downArrow → list_downArrow
[54085.011] IO script list_downArrow for kb:downArrow (repeat 1)
[54085.047] IO event selection: AXRow "Reports, Today at 10:14, --, Fold"
[54085.049] IO say: Reports, Today at 10:14, --, Folder, collapsed, 3 of 6
```

- **54085.010**: the tap saw Down Arrow, asked the main thread, and handleKeyDown found the focus object's script
  list_downArrow (step 3, item 6: the focus object is a SelectableList). The key is taken.
- **54085.011**: the script runs, a millisecond later. It is the second Down within the multi-press timeout, hence
  repeat 1. moveSelection posts Down Arrow to Finder's process and waits.
- **54085.047**: 36 ms later Finder reports its selection changed; the AX handler turned that notification into a
  selection event for the row (see [HOW-FOCUS-BECOMES-AN-OBJECT.md](HOW-FOCUS-BECOMES-AN-OBJECT.md)). The wait ends.
- **54085.049**: the row is spoken: its name (the row's text, column by column), its role, its state and its
  position. Forty milliseconds from key to voice.

When the application does not answer in time, the next line is list: no selection change yet after downArrow,
and the event reads the row when it finally comes.
