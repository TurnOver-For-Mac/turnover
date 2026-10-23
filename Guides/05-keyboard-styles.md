# Keyboard styles

TurnOver speaks three screen readers' keys. Press Command Control Comma, then K, until you hear the one you want; the
Settings window's Keyboard section offers the same choice. The style changes which keys you
press, never what TurnOver can do.

## VoiceOver keys (the Mac style)

VoiceOver's own keys, doing what they do in VoiceOver. VO is Control and Option together; Caps Lock works as VO too.
VO arrows move around, VO Space presses, VO Shift Down and Up go into and out of things, VO U is the rotor, VO M the
menu bar, VO D the Dock, VO Shift M the shortcut menu. VO Command Shift with the arrows changes speech settings, VO
Command with the arrows moves by the rotor's kind. Control pauses speech. One Quick Nav is shared with VoiceOver.

[Every key, VoiceOver keys](keys-voiceover.html).

## NVDA keys (the Windows style)

NVDA's own keys, doing what they do in NVDA. Caps Lock is the NVDA key (Control and Option works too): Caps Lock N
the TurnOver menu, Caps Lock 1 keyboard help, Caps Lock L the current line, Caps Lock A say all, Caps Lock F7 the
elements list, Caps Lock Space browse mode on and off. Control stops speech. Where NVDA uses Alt, TurnOver uses the
Mac's Command key, which sits where Alt does on a PC keyboard. The role is said before the words, as NVDA says them.

[Every key, NVDA keys](keys-nvda.html).

## JAWS keys

JAWS's laptop layout, with Caps Lock as the JAWS key. The reading grid: Caps Lock U, I and O for the previous, current
and next line; J, K and L for words; M, Comma and Period for characters; Y, H and N for sentences; Control U, I and O
for paragraphs. Caps Lock Shift J and L read the line up to and from the cursor. Caps Lock Z is the virtual cursor,
Caps Lock F5, F6 and F7 the lists of form fields, headings and links, Caps Lock Semicolon the PC cursor and Caps Lock P
the JAWS cursor, Caps Lock 8 and 9 click. During say all, Left and Right go back and on a sentence, and Page Up and
Page Down change the speed for that say all. Every other key is NVDA's.

[Every key, JAWS keys](keys-jaws.html).

## On a Mac keyboard

- **Insert doesn't exist**, so every Insert, NVDA or JAWS key chord becomes Caps Lock.
- **The Mac's own shortcuts win.** Where a Windows reader's key collides with a Mac shortcut (Command Comma opens
  every app's settings, Command Period cancels), the reader's command sits on a second key, listed on its page.
- **Windows' Control is often the Mac's Command** for app shortcuts: copy, find, new tab. In screen reader chords it
  stays Control.
- **Home, End, Page Up and Page Down** are Fn with the arrows on a laptop keyboard. F1 to F12 need Fn unless the Mac
  is set to use them as standard function keys.

## In every style

- TurnOver's own commands behind Command Control Comma never change with the style.
- Keyboard help (the TurnOver menu, Keys) says what any key does without doing it.
- Command Control Comma, then Slash, lists every key that works where you are.
- Your own keys (Settings, Keyboard commands) sit on top of any style.

## Changing keys

Open Settings with Command Control Comma, then S, and choose **Keyboard commands** in the sidebar. Commands are
grouped by category, including commands with no key. Search by a command's words or its key, or choose a category.
Select a command to see its keys and the **Add key**, **Change** and **Remove** buttons.

For Add or Change, press the key you want. TurnOver records it without running its current command. Read the
assignment and any warnings, then choose **Save key**. Escape or Cancel leaves the keys unchanged. Recording also
ends when you leave Settings or after 30 seconds. A conflicting assignment is replaced only when you save.

Warnings compare TurnOver's built-in VoiceOver and NVDA styles. They cannot check custom assignments in another
screen reader. A plain typing or navigation key also carries a warning: assigning it can take it away from apps.
Right Option is separate from left Option, and number-pad keys are separate from the number row. Essential keys,
including Escape, the browse/focus-mode key, the TurnOver layer and startup keys, and the keypad's modifier and mode
switch, cannot be changed.

Remove sends a key to the application. Change assigns the new key and sends the old one to the application. To undo
either, choose **Changed keys**, select the key, then choose **Restore default**. This list also keeps existing assignments
to applications, Shortcuts and script files.

App and document commands come from the app where you opened Settings; open Settings from that app again to refresh
them. They still work only where that command is available. Changing keyboard style or layout clears this app
snapshot; reopen Settings from the app to collect its commands in the new style. Named keyboard profiles and
automatic switching by app are the next parts of the manager.
