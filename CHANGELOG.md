# What's new in TurnOver

The newest build is first. "Reported by a tester" marks a fix for something a tester sent in. Thank you.

## 2.0, build 22.2

### Fixed

- After the Mac wakes and is unlocked, TurnOver comes back. The lock turns VoiceOver on for the login window; the notice
  of that arrived only after the wake, minutes later, and TurnOver took it for VoiceOver turned on by hand, so it stayed
  off until quit and started again. The lock's own VoiceOver no longer counts, and once secure input is off TurnOver
  looks again for up to ten seconds until an ordinary app is in front.
- TurnOver Settings: Tab and Shift Tab are TurnOver's own in its window: the sidebar, then the section's controls in
  screen order, round and round, whatever the Mac's Keyboard navigation setting says. With that setting off (the Mac's
  default) the window's own Tab reached the sidebar and the ducking pop-up and nothing else, and TurnOver's generic
  Tab fallback, sorting the sidebar by its middle, skipped the top half of the pane. Reported by four people on
  AppleVis; reproduced here with the setting off and on.
- Copying VoiceOver's settings with a Siri voice chosen in VoiceOver no longer sounds like a failure: the copy is
  reported, then that the voice is a Siri voice, which Apple gives to Siri and VoiceOver alone, so TurnOver keeps its
  own, with where to choose another. Reported on AppleVis.
- NVDA and JAWS keys: Left Option on its own, when the Dock doesn't take the focus (macOS's own Move focus to the Dock
  shortcut turned off), says so and where to turn it on, instead of nothing. Reported on AppleVis.
- Spotlight on macOS 27 is read: Command Space says the search field, the letters typed go to it, Tab reaches the
  microphone, Escape says it closed (Urh's change; Spotlight's panel is drawn by "Siri AI" there, which TurnOver didn't
  follow). Reported on AppleVis.

## 2.0, build 22.1

### Fixed

- One reader speaks at a time whatever the swap setting says. With "TurnOver and VoiceOver swap" off, turning VoiceOver
  on left both talking over each other; now TurnOver goes quiet while VoiceOver is on and running, and comes back when
  VoiceOver goes off (if that is what quietened it). Started with the swap off and VoiceOver on, TurnOver waits and says
  so through VoiceOver.
- TurnOver Settings: Escape closes the window; the app quits with its last window and when TurnOver has gone (left
  running with no window, only a force quit found it); Tab reaches every control in the window, pop-ups and sliders too,
  whatever the Mac's Keyboard navigation setting (with it off, a Tab through Speech met only the ducking pop-up).
  Reported on AppleVis.
- Keyboard navigation (System Settings, Keyboard) is turned on for the Mac once, with a welcome page saying so, since
  TurnOver's Tab needs it where VoiceOver's keys did not.
- Steam and its games always speak through TurnOver where Steam is installed: the switch for it is gone from Settings
  and the Games menu (Steam itself says when it is asked to open its port, so off only hid speech). Reading Big Picture
  and Restart Steam stay.
- NVDA and JAWS keys: Left Option D opens the Desktop folder in Finder, as Windows D reaches the desktop. Asked for on
  AppleVis.

## 2.0, build 22

### Changed

- CoExist is gone: TurnOver is a full screen reader from the first launch, and one reader speaks at a time. While
  TurnOver is on VoiceOver is off; Command Control Period quits TurnOver and starts it again. VoiceOver is no longer
  kept running and silenced alongside it, so nothing asks for audio recording permission any more, and TurnOver's own
  braille and sounds are on. Password fields and macOS's own prompts are TurnOver's to read; what you type in a
  password field is still never spoken or logged. Discussion 46.
- Screen reader behaviour: TurnOver is on or off, VoiceOver is on or off, and that is all. TurnOver reads everywhere
  while it is on; no apps are labelled for either reader and nothing switches as you change apps. A new Settings
  section, Screen reader behaviour, holds one switch: TurnOver and VoiceOver swap, one coming on as the other goes
  off (TurnOver turns VoiceOver off as it starts and on as it quits, comes on when VoiceOver turns off and steps aside
  when VoiceOver comes on). Off, each reader has its own switch and neither changes the other, for VoiceOver reading
  inside a virtual machine such as Parallels. Readers per app (the lists, the modes, switching as apps change) are
  folded away inside that section, off for a new install; a set-up that already uses them keeps working as it did.
- TurnOver turns VoiceOver on by starting it, not by its keyboard shortcut, which can be changed or stop working;
  and VoiceOver's own shortcut passes straight through TurnOver's keys instead of waiting on them. Command Control
  Period waits for Command and Control to be let go before TurnOver quits, so VoiceOver's shortcut arrives cleanly.
- The welcome, on a first start and after this update, presents TurnOver as a full screen reader, and names the
  three keyboard styles, the menu, the Settings window and the copy of your VoiceOver settings by their keys.
- The menu is short, in NVDA's shape: This app, Settings, Keys, Tools, Help, Support TurnOver, Quit. Every setting
  now lives in the Settings window, in sections down the side: General, Speech, Keyboard, Item details, Web pages,
  Documents, Screen recognition, Other apps' speech, Screen reader behaviour. Braille waits under Tools until it has
  its section.
- Settings: voices for other languages are in the Speech section (a voice and a rate for each language with a voice
  installed); the Voice list is the Mac's languages and English, Eloquence first; Steam's two switches (game speech,
  and reading Big Picture) and Restart Steam are in Other apps' speech as well as under Games in the menu; the
  settings keys (Command Control Comma, then S, and the style's own) open the window at the asked section; Previous
  builds, under About and updates, opens the releases page for going back to an earlier build.
- Command Control M opens the TurnOver menu in one press, in every keyboard style. Command Control Comma then M
  still works.
- VoiceOver keys: Left and Right pressed together, which turn Quick Nav off and on, now also switch a document between
  focus mode and browse mode: off is focus mode (the keys go to the page, until the focus leaves), on is browse mode.
  There was no deliberate way into focus mode in this style, since TurnOver Space is VO-Space.
- Browse mode: a letter is always a command, as in NVDA; a field is typed into after Return or Tab enters it.
- Pressing a control on a web page now says what changed: on or off, checked or not, expanded or collapsed,
  selected. A page that changes the control a moment later (Squarespace's switches take a second or two) is still
  reported, with the control's name if you have moved on. VO-Space presses the control through accessibility, as
  VoiceOver's VO-Space does; Enter and Space send the real key, as before, so a page that ignores one answers the
  other. A menu button that ignores the accessibility press (the Claude app's More options) is opened by the keyboard.
- Notification Centre: VO-O opens the panel and the key again closes it; the Notification Centre and Control Centre
  keys find the clock wherever macOS puts it; a panel left open before TurnOver started is handled.
- VO-Shift-L recognises the whole screen when the cursor is not on a picture, a direct recognition key in the Mac
  style.
- The typing echo is private: typed words are never written to the log or carried in a report.

### Fixed

- VoiceOver comes back after a quit, a crash or a long hang, also when macOS says it is on but it is not running
  (quit by a script, or crashed), and waking the Mac from sleep no longer toggles VoiceOver.
- With NVDA or JAWS keys, the layer that makes Caps Lock the NVDA key where VoiceOver reads can be turned off: Settings,
  Keyboard, "NVDA and JAWS keys where VoiceOver reads too" (on, as before). Off, VoiceOver's own Caps Lock keys
  (VO-F7, VO-F8, VO-M) work in the apps VoiceOver reads. The old setting for it was never read.
- The speech settings are TurnOver's own again: the rate, volume and pitch keys change TurnOver's voice only, and
  TurnOver no longer reads VoiceOver's rate when it takes over. The link between the two readers' settings wasn't
  reliable.
- TurnOver Settings: the switches in Screen reader behaviour are read with their names on Tab (the window gives a
  switch its label a moment after Tab lands on it; TurnOver now waits for it); changing a switch no longer pauses
  for a second and a half; Tab never lands on a control the window has thrown away when the section changes (a
  contributor's change); a Settings window left open through an update is closed, since it showed TurnOver as off.
- Safari: a page that moves the focus into an empty frame by itself (an advertisement loading) no longer takes
  TurnOver off the page.
- VoiceOver keys: Right Arrow reads the character you just passed, as VoiceOver does, so what you hear is what
  Backspace will delete. NVDA keys and JAWS keys keep reading the character after the caret, as on Windows.
- Backspace speaks the deleted character at once, instead of after waiting for the caret (Mail's compose window held
  every repeated Backspace back by a quarter of a second).
- A list focused twice within half a second with a different row selected (Finder opening a folder) is read
  each time; it was taken for the same focus and read once.
- Braille: a Focus 5 by USB is found, and freed from VoiceOver's braille server; a message held on the display gives
  way to the next command, as in NVDA (two of a contributor's changes).
- Word's own dictionary decides what is misspelled in Word; the choice now lives in Word's app module instead of
  shared code, with tests (a contributor's change).
- The app shortcut picker offers every application once: Safari and other apps reached through a link were missing,
  and some appeared twice (a contributor's change).
- Waking the Mac no longer says TurnOver is not responding in the system's voice, several times over itself. The
  watchdog took the sleep for a hang; it now knows the difference, and its warnings are said one at a time.
- Finder: Command Down on a folder, and Command Up, are sent again if Finder ignored them. About one press in
  twenty did nothing although the key reached Finder; now, if nothing has changed a third of a second later, the key
  goes once more. Only for a folder, never for a file, so nothing opens twice. A symptom fix; the cause is in Finder.
- Finder: an empty folder is read as empty, and Down Arrow in it says so. It was read as a list of four or five
  items, and the arrows walked through the columns.
- A menu item, button or link with no name of its own is named by the text it holds (GitHub Desktop's lists of
  repositories and branches were nameless menu items).

## 2.0, build 21

### New to try

- TurnOver is free and open source: the code is at github.com/TurnOver-For-Mac/turnover, no tester key is needed any
  more, Send feedback opens TurnOver's problem form on GitHub, and Support TurnOver in the menu opens Ko-fi.
- Plugins are back on for everyone: the TurnOver menu, Tools, Plugins. Shared as pull requests to the plugins
  repository, checked and reviewed before the library carries them.
- TurnOver reads every app by default; VoiceOver still handles passwords and macOS's own prompts. Command Control
  Shift T gives the app in front to VoiceOver, or back to TurnOver, straight away (the layer's T still does too).
- JAWS keys (Command Control Comma, then K, until you hear "JAWS keys"): JAWS's laptop layout with Caps Lock as the
  JAWS key. The reading grid (Caps U I O for lines, J K L for words, M comma period for characters, Y H N for
  sentences, Control U I O for paragraphs), Caps Shift J and L for the line up to and from the cursor, Caps Z for the
  virtual cursor, Caps F5 F6 F7 for the lists, Caps P and semicolon for the JAWS and PC cursors, Caps 8 and 9 to
  click, Caps Control H for speech history, Caps Control V for the app's version, Caps Control F12 for the time with
  seconds. During say all, Left and Right go back and on a sentence, and Page Up and Page Down change the speed for
  that say all. Every other key is the Windows style's.

### Fixed

- Waking the Mac at the lock screen no longer ends in several TurnOvers speaking at once: while the Mac is asleep,
  locked or just awake, a stuck voice is left to come back rather than restarted; a restart after a hang ends the
  stuck copy, so there is only ever one. Reported by a tester.
- Giving a key to a command: the list of commands stays open for the next one; Escape leaves it. Reported by a tester.
- Command Tab doing nothing until TurnOver was turned off and on: a modifier the Mac thought was still held is
  released before Command Tab passes, and the log records both states.
- When the Mac's audio system hangs (it did for a few minutes on 20 Oct), TurnOver no longer hangs with it and
  restarts over and over: the fresh voice is built off the main thread, nothing waits on the speech queue, the
  device list is read on its own queue, and the log says which audio call stuck.
- Screen recognition no longer freezes TurnOver (it could restart itself on a slow read). Reported by a tester.

- The Windows style (NVDA, Narrator and JAWS keys): no more pauses between the pieces of what TurnOver says
  ("Settings submenu 3 of 9", "OK button"), as NVDA says them. The Mac style keeps VoiceOver's way. Reported by a
  tester.

## 2.0, build 20.2

### Fixed

- TurnOver restarting itself ("TurnOver's voice stopped"), most often after say all and an arrow key: the speech could
  wait for ever on the Mac's audio player. It no longer can, and if speech ever does stick, a fresh voice takes over
  within a few seconds instead of a restart. Reported by a tester.
- Context menus: Right Arrow on an item with no submenu no longer closes the menu or freezes TurnOver, and Right on
  Open With opens it. Reported by a tester.
- Word: every table in a document moves by row and column, not only the first. Reported by a tester.
- Your own keys: VoiceOver's and NVDA's commands (next paragraph, next table and the rest) are listed whatever the
  keyboard style, and keys given to them work; right Option keys you set work with VoiceOver's Option Commander off.
  Reported by a tester.
- Command Control Period switches TurnOver off and on again after an update; it had quit TurnOver instead.

## 2.0, build 20.1

### Fixed

- The Dock, status menus and Spotlight: the arrows move through them again with a TurnOver app in front (in build 20
  they went to the app behind).

## 2.0, build 20

### New to try

- Apps can ask to speak through TurnOver (a game, say): the first time, TurnOver asks you, by name, whether you trust
  it. An app you allow is heard in TurnOver's voice while it's the app in front, and can do nothing else. Settings,
  Apps that speak through TurnOver, changes your answer. (Windows games through SpeechBridge use the same way in.)
- Direct (Command Control Comma, then D): for a game or app that speaks for itself. Every key goes straight to it,
  VoiceOver never sees them, and TurnOver says nothing there; Command shortcuts still work. D again to leave.
- Spelling corrections in any edit box: on a misspelled word (or just after one), VO Shift M lists the Mac's
  suggestions; Return puts one in place of the word. Learn spelling, Ignore and the app's own menu are at the end
  of the list. Word keeps its own menu, with its corrections.
- VoiceOver now stays running alongside TurnOver (CoExist, on unless you turn it off) and handles everything to do
  with security: in any password field, and in macOS's own prompts (passwords, Touch ID, "Allow" questions),
  TurnOver steps aside and VoiceOver reads until you leave.
- Privacy and security, a new guide: every permission and why, the one place TurnOver connects to (its update
  site), how to check that yourself with a firewall, and what the log keeps (never what you type or read).
- CoExist, much simpler: VoiceOver keeps running and is silenced at the sound level wherever TurnOver reads, and
  heard the instant you give an app to VoiceOver (Command Control Comma, then T), in password fields, or when
  TurnOver turns off or quits. No VoiceOver Utility round trips, no app lists, nothing said as it switches.
- Kindle: the sign-in pages, the library and books, read a sentence at a time, the arrows and say all turning the
  pages (Kindle shows a book's words only while VoiceOver runs: CoExist covers it).
- VO-F8 opens VoiceOver Utility again.
- The Settings window: every setting in one window, the sections down the side (speech, keyboard, documents, web
  pages, sounds, starting, experimental). Command Control Comma, then S, or Settings, Open the Settings window. Changes
  take effect at once.
- One TurnOver: the full screen reader. Newer features still settling are marked experimental where they are:
  CoExist (VoiceOver running alongside, quiet in TurnOver's apps) is in Settings, Experimental, with a plain
  explanation; apps whose support is new say "experimental support" under This app.
- Say all voice, in Settings, Speech: say all can read in a natural voice made on your Mac, reading ahead so it never
  waits, while everything else stays in your usual, instant voice. (On the maintainer's Mac first.)
- Say all stops on the word you had reached, not the start of the paragraph.
- The guides: getting started, the TurnOver layer, reading and say all, the apps, keyboard styles, CoExist, and
  troubleshooting, on the updates site and inside TurnOver (H after Command Control Comma).
- Plugins are parked: still in the code, no longer in the menu, and the library's checks have stopped. Why: a way to
  load other people's rules into a reader with this much access needs a reviewed format, limits, signing and a
  second pair of eyes before it is offered; nobody had made one yet. The format and helpers stay public.
- VoiceOver stays on. TurnOver reads its own apps, and VoiceOver is quiet there; everywhere else VoiceOver reads
  as usual. You never choose, and there is no hand-over to wait for.
- One menu: Command Control Comma opens the TurnOver menu in any app. This app, keys, the copy of your VoiceOver
  settings, feedback, about, quit. No settings of TurnOver's own: your VoiceOver settings are copied instead, and
  the copy is in the speech settings too (VO-Command-Shift-Right to "sync with VoiceOver").
- Command Control Period turns TurnOver off and on.
- The rotor without opening it: VO-Command-Left and Right choose the kind, VO-Command-Up and Down move. In Word:
  headings, comments, tracked changes, misspelled words, tables, pages. The speech settings are VO-Command-Shift.
- VoiceOver's own sounds, in TurnOver's apps too: links, misspelled words, Quick Nav, the trackpad.
- The trackpad: VoiceOver's gestures in TurnOver's apps ("trackpad commands on" with the VO keys and a two-finger
  turn); VoiceOver's own Trackpad Commander everywhere else.
- Giving an app to VoiceOver (the menu, This app) sticks, and VoiceOver speaks there at once.
- Discord: TurnOver's chat keys, as in Messages and WhatsApp.
- Chat lists keep going: Down at the end of the conversations loaded and Up at the oldest message fetch more.
- Shift with the arrows reads the selection the moment it changes.
- VO Shift M on a misspelt word in Word opens Word's corrections.

### Fixed

- Updating from build 19 with VoiceOver off (the old way turned it off in TurnOver's apps): VoiceOver is turned back on,
  and until it is, or whenever you turn it off yourself, TurnOver reads every app. Before, the apps TurnOver doesn't
  read were silent. With VoiceOver off, TurnOver also keeps reading in password fields and prompts (it never speaks
  what you type there).
- On macOS 14.0 and 14.1, which can't silence VoiceOver, TurnOver works the old way (VoiceOver off where it reads).
- If VoiceOver can't be silenced (macOS's audio permission said no), TurnOver says so and how to fix it.
- Quick Nav is one Quick Nav: turning it on or off (Left and Right Arrow together) turns VoiceOver's the same way,
  in TurnOver's apps and VoiceOver's alike. With VoiceOver's Quick Nav on, lists and arrows in TurnOver's apps did
  nothing, VoiceOver taking the arrows silently; the arrows TurnOver passes on now go to the app alone.
- If VoiceOver was quit (rather than turned off), TurnOver reads every app and starts VoiceOver again within a few
  seconds; it wrongly spoke the audio-permission message while VoiceOver wasn't there.
- AirPods: switching to them could leave TurnOver silent (the Mac's speech synthesizer stopped giving sound). TurnOver
  now starts a fresh synthesizer when the sound output changes or a voice goes quiet, and if speech is still stuck it
  says so in the Mac's voice and restarts itself within about ten seconds. Reported by a tester.
- Command Control Comma, then T, giving an app back to TurnOver now says "TurnOver leads in" the app first, then reads
  it, as the other way says "VoiceOver leads in".
- VO A (and the trackpad's two-finger flick down) in a list or table reads from the selected row on, at once; in
  Mail's message list it read from the first message after three or four seconds, and gestures made meanwhile all
  ran together afterwards.
- Spelling: VO Shift M on a misspelled word opens TurnOver's list of corrections again (the Mac's spell checker, asked
  about one word, called every word right), also straight after Command Semicolon has selected the word. TurnOver E
  finds every misspelled word in TextEdit, not only the one the app has marked.
- Finder: Desktop items that come without a file address (an alias, a volume) are found by name and say their kind.
  Reported by a tester. (Or give Finder to VoiceOver: Command Control Comma, then T.)
- Quick Nav on and off play TurnOver's sound with TurnOver's sounds chosen; they said the words instead.
- TurnOver no longer stops when the Mac sleeps with the lid closed (it ended as the sound went, and stayed off). If it
  ever stops while the Mac is asleep or locked, the Command Control Period helper starts it again quietly once the Mac
  wakes or is unlocked, rather than straight away into a sleeping Mac.
- My own keys is back under Keys (it went missing with the small TurnOver of 16 October). A right Option key with
  Shift is now its own key, said as "right option shift N". (Reported by a tester.)
- Numbers says a cell's address ("B3") only when Cell coordinates is on. (Reported by a tester.)
- An app that answers slowly (a game answering once a frame) no longer freezes TurnOver for seconds as it comes
  forward: TurnOver signs up for its news in the background, and lets it rest a moment when its slow answers add up.
- Game speech from the bridge is said only while a game is the app in front.
- Only TurnOver's own programs can talk to TurnOver: TurnOver Settings, TurnOver Key (Command Control Period), the
  plugin tool and Windy now reach it through a private channel that checks each program's signature. Before, any
  program on the Mac could change TurnOver's settings, make it speak, press keys through it or read its settings.
- Command Control Comma where VoiceOver reads: the letter after it (T to take the app back) goes to TurnOver even with
  VoiceOver's Quick Nav on; it went to VoiceOver.
- Progress bars are said as a percentage ("90 percent", not "0.9"), and once read, the percentage is said as it
  climbs, every 10 percent and at the end, while the app is in front.
- "Unknown" is never said as what something is.
- VoiceOver comes back if TurnOver freezes: the helper keeping VoiceOver quiet needs a word from TurnOver every
  second, and lets VoiceOver be heard after three seconds without one.
- Word: a line with a grammar mark is read once; the mark's words were read again after it ("Grammatical error:
  after"), since this build's highlight reading.
- Calendar, a new event (Command N): Tab and Shift-Tab go through the whole box (quick entry, title, date and time,
  alerts, location, video call, invitees, calendar, notes, Event or Reminder); before, Tab left the box and closed it.
  Return or Space presses a button: on the date it opens All day, the start and the end, each date and time named,
  Up and Down to change them. The quick entry says what it's for, and typing in it no longer reads the whole line
  on every key. Done, after the last part, saves the event. Saving (Done, or Return in the quick entry, the title or
  the place) says what was saved and when, then goes to that day with the event chosen: Down and Up read the day's
  events, Return opens one.
- Calendar: Up and Down read a day's events again (Calendar now shows them as buttons, which TurnOver had missed).
- The green window button says "full screen".
- If VoiceOver stops unexpectedly while macOS still thinks it's on, TurnOver speaks after a few seconds.
- Web pages, Mac style: Return with the reading position on a text field goes into the field; it was typed into it,
  which submitted a search box. Tab likewise moves on rather than typing a tab.
- Web pages: at the end of a page that loads more as you scroll (YouTube's home page), Down and the quick-nav
  letters fetch what's below and carry on; "bottom" came too early (reported by a tester).
- Web pages: "page read in part" is said once for each page, and a page you come back to isn't read from the top
  again after many mail messages have been opened in between.
- The Find menu (VO-Shift-F): the bold, italic and other format searches work; twelve of its items did nothing.
- A control that follows another focus at once no longer loses its speech to a nameless pane on the way; it was
  cut to its first letter in some dialogs.
- Spelling errors are announced at the right word when the same letters appear earlier in the line.
- A capital spelt while VoiceOver was talking no longer raises the pitch of the next thing said.
- Say all: the tones for links and headings sound as the paragraph is read, not two paragraphs early.
- A Mac set to a language other than English gets that language's voice when the chosen voice is missing, not English.
- Steam: Big Picture's menu keys stay with Steam; after switching away with the menu open, the arrows and Return
  went to Steam from every app.
- Quitting TurnOver: the keyboard is released before VoiceOver is turned on, so the first keys you type aren't lost.
- If TurnOver cannot start, it says so in an alert instead of doing nothing.
- Send feedback: the "what TurnOver said" file holds the last 15 minutes and 5 minutes around each marked moment,
  not the whole day; the settings copy leaves out your apps list and your own keys. Braille typing and game speech
  are no longer written to the log as words.
- Page statistics counts a heading wrapped over several lines once.
- Steam: Big Picture's window is named Steam in the app summary and the TurnOver menu (it belongs to a process called Steam Helper), and the menu no longer offers to make a plugin for it (reported by a tester).
- VoiceOver stays on (a mode on one Mac for now, the `coexist` default): TurnOver takes the keys in its apps ahead of VoiceOver and VoiceOver is silent there by an Activity TurnOver puts into VoiceOver itself (exported, added, imported back, every sheet answered); nothing is ever switched off. Command Control Period turns TurnOver off and on without quitting it, and the Activity goes with it. Command Control Comma opens the TurnOver menu; its This app submenu gains "Describe the image at the cursor" and "Ask for this app to be tuned".
- Lists: with several rows highlighted (Shift Down, Command click), TurnOver says the row that just changed and then how many are selected, as VoiceOver does; it said the first selected row every time. Clearing the selection says "nothing selected".

## 2.0, build 19

### New to try
- The plugin library is open: TurnOver menu, Plugins, Plugin library. Each plugin says what it can do before it
  installs; every list and download is checked against TurnOver's signature. To start: Xcode (build and test results said as they happen, keys to build, run and test; asked for by
  a tester), and two examples: Calculator and Bambu Studio.
  No plugin for the app you're in? "No plugin for this app yet", last in the library's list, finds what the app
  is built with. If TurnOver has the parts for that kind of app, make its plugin or post it as wanted for plugin
  makers; if not (Java, Qt, Flutter…), ask for the parts. Only how the app is built is sent, never what is in it. Every plugin can be read in full at github.com/TurnOver-For-Mac/turnover-plugins, and anyone can add one
  there: a plugin that passes TurnOver's checks goes into the library within the hour (CONTRIBUTING.md).
- Making a plugin with an AI: Claude Code, OpenAI's Codex or Google's Gemini CLI open in the plugin's folder and can
  try keys in the app and hear what TurnOver says, as a developer would (TurnOver presses them, says so, and only in
  that app for three hours). Without Codex or Gemini CLI, ChatGPT and Gemini work through their websites as before.
  Each installed plugin in the Plugins menu now has About and Remove; Remove puts it in the Trash.
- The plugin layer (Command Control Comma, then P) lists each command with its key.
- Help wanted: if you use OpenAI's Codex or Google's Gemini CLI, try TurnOver menu, Plugins, Make a plugin for an
  app with ChatGPT or Gemini, and tell me how it goes (Send feedback). I can only test Claude Code here.
- Browse mode: P and Shift P move to the next and previous paragraph of text, past menus and link bars to the
  article; N and Shift N to the text after a block of links, as in NVDA (reported by a tester).
- Browse mode letters follow each style's reader: the Mac style now has VoiceOver's own single-key Quick Nav (L link,
  X list, C check box, F text field, J control, M heading at the same level, N landmark, D different item, R radio
  group), where it had NVDA's; the Windows style keeps NVDA's, with A now annotation as in NVDA. Caps Lock F7 on a
  page lists its headings, links and fields (Windows style). The rule: Mac keys do what VoiceOver's do,
  Windows keys what NVDA's do.
- The rest of NVDA's browse mode keys (Windows style): I (list item), S (separator), O (embedded object), headings 7 to 9, Comma
  and Shift Comma (past the end of a list, table or other container, or to its start), and in the Windows style
  NVDA+Shift+Space to turn single-letter navigation off for a page.
- Mac style, more of VoiceOver's keys: arrow-key Quick Nav with VoiceOver's two-arrow chords, its rotor kinds and
  web pages; VO-Home and VO-End in text; VO-Return selects text; VO-A reads the cursor's contents; VO-F3 the
  VoiceOver cursor; VO-F4 twice; VO-F7 three times (network); VO-Shift-S scrolls.
- Windows style, more of NVDA's: NVDA+S's four speech modes; the desktop layout's keys; NVDA's braille tether,
  braille mode and auto scroll; NVDA+Control+Shift+F1 copies part of the log; Excel's note, elements list and cell
  review; Screen Curtain on NVDA+Control+Escape only (VoiceOver's VO-Shift-Underscore in the Mac style).
- Settings profiles: VO-X (Activities) and NVDA+Control+P (configuration profiles), by hand or for an app.
- TurnOver works with Steam for Mac: Big Picture and Steam's games speak.

### Fixed
- Changing reading mode (Command Control Comma, A) says the mode's name in place of "TurnOver on", not on top of it.
- Speech is no longer 3 dB louder than VoiceOver's: at the same Mac volume, Alex (and every voice) now plays at the level VoiceOver plays it.
- On a web page, pressing Space or Enter on a video player's button (YouTube's Play) no longer switches to focus mode when "Focus mode when a field takes the focus" is off (reported by a tester).
- The keyboard language is said right when it changes: on a Mac with two sources it was said the wrong way round, "ABC" as Arabic came on and the reverse (reported by a tester).
- Steam's Add a Non-Steam Game: each program is one line, its name and path with the tick box, and Return ticks it. It read as nameless boxes, names and paths apart.
- Steam with a controller: the Home, Settings and Power menu reads as you move through it; it had gone silent after its first item.
- Steam's desktop windows: a tick box says on or off as you switch it with Space or Return, not only when you come back to it.
- Steam's desktop windows: after Tab moves to a button, Return presses that button; it pressed the line the arrows had last been on.
- Steam's game pages: the note beside the main button is read after it, so Resume says why ("Update failed, not enough free disk space") and Play says when you last played.
- Word: tabbing through a dialog's fields (Font) no longer cuts each field to its first letter (reported by a tester).
- Word: VO-Command-T and VO-Command-Shift-T move to the next or previous table from inside a table too; they said "no next table" (reported by a tester).
- Terminal: a command's output no longer talks over an open menu or over the "terminate running processes?" sheet;
  it's read when you're back in the terminal. VO Right and Left stay inside a sheet.
- VoiceOver turned on by hand while TurnOver led, and TurnOver kept the keys because macOS never said so: TurnOver
  now checks for itself every two seconds and steps aside (reported by a tester).
- Windows style, browse mode: Control Up and Down move by paragraph, as in NVDA (reported by a tester).
- If VoiceOver stops but macOS still says it's on, TurnOver speaks after a few seconds.

- App Store: Update works on the Updates page (each update's row went unrecognised, so the press was refused as
  unsafe).
- App Store: while an app downloads, Space and Return say how far it has got (a second Space no longer cancels;
  Delete does), the app's line reads its progress as it is now and then Open, and Open pressed again while a big
  app is starting says "opening" instead of starting it again.
- Tables in TextEdit (and other Mac text views) are announced: entering says the table's size and the cell, moving
  says the new row or column, leaving says "out of table" (reported by a tester).
- Steam's Big Picture: only the part of Big Picture you're in speaks, so the page behind the menu no longer talks
  over it.
- TurnOver reads in Big Picture itself (it runs as a separate Steam app, Steam
  Helper, which VoiceOver kept until now when TurnOver reads only its own apps).

- After a menu closes with Escape (TextEdit's spelling menu), the text area is the focus again and the arrows read.
- A system dialog left open (the keychain asking for your password, a security prompt) is no longer lost behind
  other apps: TurnOver says it is waiting whenever you switch app, and it is first in the application chooser
  (VO-F1 twice, or Option Tab in the Windows style).
- TurnOver E and Shift E (VO-Command-E in the Mac style) find every misspelled word, in TextEdit and in Safari's
  text boxes when Safari marks none, including the word just typed and one at the very start.

## 2.0, build 18.1

A small build on the heels of 18, for one bug worth having at once.

### Fixed

- After a menu closes with Escape (TextEdit's spelling menu, a context menu in any app), the text area is the focus
  again and the arrows read. In build 18 TurnOver could lose the focus there, and the arrows went quiet until you
  switched apps.

### What to test

- In TextEdit, VO-Shift-M on a misspelled word, Escape, then the arrows: they should read the text.

## 2.0, build 18

A week of fixes from your reports, and safer settings.

### New to try

- **Who reads, everywhere at once.** Command Control Comma, then A, goes round three modes: TurnOver in its apps (as
  now), TurnOver everywhere (VoiceOver keeps only the apps you give it), and VoiceOver everywhere (TurnOver steps
  back but keeps running). Each mode remembers its own apps; Command Control Comma, then T, still switches the app in
  front. Also in the TurnOver menu, Applications, Who reads (reported by a tester).
- **Your keyboard language said.** Switching input source with Fn, the Globe key or Control Space says the new one,
  as VoiceOver does (reported by a tester).
- **Mail says its autocorrections** while you write: "corrected to the" (reported by a tester).
- **Moving by formatting in documents.** VO-Command-B, I, U, K, O and P (with Shift for previous) find the next
  bold, italic or underlined text, colour or font change, or plain text in Word and TextEdit, not only on web pages
  (reported by a tester).
- **The layer key's list.** After Command Control Comma, Down Arrow lists TurnOver's commands to arrow through;
  Return runs one.
- **The browse mode sound both ways.** TurnOver now plays a sound when it goes back to browse mode by itself, as well
  as into focus mode (reported by a tester).
- **For plugin makers:** the plugin listing (summary, contact, abilities, privacy, licence, changes) and
  `turnover-plugin check --listing`, which checks it and your keys without the app running (PLUGIN-GUIDE.md).

### What to test

- Safari: from Google's search box, Command L, an address and Return; then a favourite. The new page should be
  announced once, in browse mode.
- Mail: in a reply, move through the quoted part (quote levels said), and Command ' and Command Option '. Then
  Command Shift D: "sent", straight away.
- Word: VO-Command-T to a table, then the arrows. A table with Arabic in it. VO-Command-B through bold text.
- Moving by character through a misspelled word: "spelling error" once going in, "out of spelling error" coming out.
- Command Control Comma, then T, in an app VoiceOver is reading: TurnOver should take it.
- ChatGPT or Brave: Shift H and Shift B back through a page.
- Arabic text in TextEdit: Right Arrow at the start of a paragraph. Typing Arabic in Safari or TextEdit: each letter
  and word said.
- Command Control Comma, then A, three times: round all three modes and back.
- Switching your keyboard language, if you have more than one.
- Word: VO-T twice: alignment and line spacing at the end.

### Fixed

- Privacy, from the full review of 14 Oct: TurnOver's log on disk now keeps only the length of what was said, not
  the words (the words go into a feedback report only when you choose "with what TurnOver said"); typing on a braille
  display in a password field is never logged or echoed; what was spoken privately (a code from a notification) is
  never written by the braille display either; the AI plugin brief carries no spoken text; screen recognition drops
  its text when closed; the places remembered on web pages are stored without the page's address or search terms.
- Say all no longer stops for good on empty lines in web editors, which then left the arrows silent.
- Escape in a web page ends the by-hand focus mode choice too, so the next field switches by itself again.
- Escape, the browse-mode key and Command Control Comma and Period can't be taken away in the keys menu.
- Uninstall asks on a second list before removing anything.
- A word half typed on a braille display is dropped, with a tone, if the focus moves before it is finished, and typed
  before any command runs.
- Quitting from outside (TurnOver Key, an installer) tidies up without waiting on a stuck main thread.
- The hand-over to VoiceOver no longer toggles while VoiceOver is still starting or stopping.
- Faster: Word checks for a table once a second instead of before every arrow key; quick-navigation letters no longer
  rebuild a changing page on every press; a very long page says "page read in part"; each focus change costs half
  the round trips; chat views ask the app for the window once in half a second.
- Find (TurnOver F) lets you switch the keyboard language while the prompt is open, so you can search in Arabic or
  any other language (reported by a tester).
- Desktop items whose kind Finder doesn't give are named by their file extension instead of only "2 of 2" (reported by a tester).
- The battery report says whether the Mac is charging or on battery, and how long to full or how long is left
  (reported by a tester).
- Safari: a page opened afresh, or in a new tab, starts at the top; only Back and Forward return to where you were
  (reported by a tester).
- Safari: VO-Shift-M (Shift F10 in the Windows style) on a link opens the link's own menu, with Open in New Tab and
  Copy Link (reported by a tester).
- Arabic and other scripts read one letter at a time in their own voice, not named by the English voice ("Arabic
  letter alef"), in screen recognition and everywhere else (reported by a tester).
- Apps that rest the focus on an unnamed group between items (Spring's timeline) no longer have the list around them
  said again and again ("Home, grouping" on every arrow).
- Up and Down at the top or bottom of a box holding one line (a reply, a message, a prompt) read the line, as in a
  one-line field; documents still only bump. Apps whose line positions are wrong (Spring's reply box) are read by
  paragraph instead of saying nothing.
- Mail: coming back to Mail with the focus on the message's scroll area now reads the message; the arrows only
  scrolled it, silently.
- Marking a moment (Command Control Comma, then J) says just "marked"; the count climbing with each press sounded
  like something going wrong (reported by a tester). The count is in the TurnOver menu, Send feedback.
- Safari: a new page starts in browse mode. Focus mode left over from the page before (Google's search box) kept the
  new page from being announced, and the arrows went to the page (reported by a tester). The page title is said once, not twice,
  and Return in the address bar no longer says "new line".
- Mail: quote levels are said while you write a reply, and Command ' and Command Option ' say the new level (reported by a tester).
  "Sent" is said as soon as the message goes, not after the window behind it.
- Word: VO-Command-T puts the cursor in the table's first cell, so the arrows carry on from there (reported by a tester).
- Arabic in a table cell (and anywhere TurnOver speaks text in another script: a name, a list item, a message) is
  read by the Arabic voice; the English voice said nothing (reported by a tester).
- Audio ducking now uses macOS's own ducking, the way the system lowers sound for its voices: no "record system
  audio" permission, no sound passing through TurnOver, less battery. TurnOver's voice stays at full volume (asked for
  on AppleVis).
- WhatsApp and Messages: Tab and Shift Tab follow the screen: the sections (WhatsApp), the conversations, the
  messages, the message box. Shift Tab from the box goes up to the messages.
- WhatsApp and Messages: moving through the chats is quicker: TurnOver remembers where the list is while you arrow,
  instead of searching the window at every move.
- WhatsApp: the chat you open no longer disappears from the list. WhatsApp shows the open chat's row differently
  (as text, not a button), and TurnOver left it out.
- Marked moments can be forgotten without sending them: TurnOver menu, Send feedback, Forget the marked moments
  (reported by a tester).
- WhatsApp: after Return opens a chat, what you type in the message box is echoed again. WhatsApp moved its focus to
  an unnamed group a moment later, and TurnOver followed it there, where typing isn't echoed.
- Typed Arabic letters and short words are said in the Arabic voice in Safari, Brave and TextEdit (reported by a tester).
- Word: VO-T pressed twice adds the paragraph's alignment and line spacing (reported by a tester).
- Moving by character, "spelling error" is said on entering a misspelled word and "out of spelling error" on leaving
  it, in your main voice, not on every letter (reported by a tester).
- Right to left: Right Arrow at the start of an Arabic paragraph no longer gives the edge sound when it has moved
  (reported by a tester).
- ChatGPT, Brave and other Chromium apps: Shift H, Shift B and the other backward quick keys work (reported by a tester).
- Command Control Comma, then T, follows who is reading: where VoiceOver reads an app, TurnOver takes it, even with
  automatic switching off (reported by a tester).
- Making a plugin with ChatGPT, Gemini or Claude no longer freezes TurnOver while it looks at the app: the freeze
  handed the Mac to VoiceOver and, as Alex couldn't speak meanwhile, TurnOver switched the voice to Reed. A voice that
  has spoken is never swapped now (reported by a tester).
- Say all: an arrow that carries say all on no longer reads the line twice.
- Settings: only TurnOver itself writes them; what was there before each change is kept (settings-previous.json),
  and a copy a day for a week (settings-history), so a bad change can be undone.
- A full disk no longer stops TurnOver (its log writer gave up on it); log lines are lost instead.
- This build is smaller inside: the internal names programs carry are taken out before it is signed.

## 2.0, build 17

TurnOver is now built in Swift 6 language mode with the main-actor default: the compiler checks every thread
boundary (speech, the key tap, the background page walks), which is why the version number moves to 2.0.
Nothing changes in how it is used.

### Keys that moved: please read this first

TurnOver now has three sets of keys. In the Mac style, VoiceOver's keys do exactly what they do in VoiceOver. In the
Windows style, NVDA's keys do exactly what they do in NVDA. And TurnOver's own commands sit behind one key, the same
in both styles, that works even in an app VoiceOver reads: **Command Control Comma, then a letter**.

Why one key: Apple's own apps use nearly every Command Control letter (we read the menus of Finder, Safari, Mail,
Terminal, Preview, Xcode and more: Command Control N, T and R alone are taken by five or six of them), and TurnOver
shouldn't take shortcuts away from the apps you use. JAWS users will know this as a layered key. **Tell us what you
think of it**: Send feedback, or reply on AppleVis.

- **Command Control Comma, then N: the TurnOver menu.** In the Mac style, VO-N is now VoiceOver's: the notifications
  you've heard lately. In the Windows style, Caps Lock N still opens the menu, as NVDA's does.
- **Command Control Comma, then T: hand the app in front back to VoiceOver** (or back to TurnOver), and remember it.
  The TurnOver menu, Hand over or quit, does it too. VO-V is now VoiceOver's verbosity list, and Caps Lock V NVDA's
  screen layout. Nothing is lost: the way back to VoiceOver is always there.
- **Command Control Period: start or quit TurnOver**, a single press, from anywhere (it was Command Control T).
- The other letters: **S** settings, **K** keyboard style, **J** "that was wrong", **Slash** the shortcuts here,
  **P** the plugin maker, **C** copy the last thing said, **H** the guide, **I** describe a picture, **R** screen
  recognition. Any other key says the letters; Escape or three seconds cancels.
- In the Mac style, VoiceOver's own keys for these work too: VO-H twice the commands, VO-Slash a custom label (the
  plugin maker), VO-Shift-Slash the guide, VO-F8 settings, VO-Shift-C copy the last phrase, VO-Shift-L describe.
- **The latest messages in Messages and WhatsApp, and the parts of a window in apps with panes, are Command Control
  1 to 9** (those apps' own keys, where TurnOver reads them). In the Mac style, VO-1 to VO-0 are now VoiceOver's hot
  spots; in the Windows style, Caps Lock 1 to 5 are NVDA's again (input help, typed characters and words, command
  keys, dynamic content).
- Windows style, as NVDA: Control stops speech and Shift pauses it; Caps Lock Up and Down Arrow move the review
  cursor by line (Caps Lock L reads the line, Caps Lock A says all); Caps Lock Shift Z is sleep mode for the app in
  front. Mac style, as VoiceOver: Control pauses and carries on.

### New to try

- **Keys have moved.** TurnOver's own commands are Command Control Comma, then a letter, in both styles and any app:
  N the menu, T hand the app to VoiceOver or back, S settings, K keyboard style, J that was wrong, Slash the
  shortcuts here, H the guide, I describe a picture, C copy what was said, R screen recognition, P the plugin maker.
  Command Control Period starts or quits TurnOver. In the Mac style VoiceOver's keys, and in the Windows style NVDA's,
  do exactly what they do there.
- **The Mac style is VoiceOver's.** 178 of the 189 commands in Apple's VoiceOver guide behave as in VoiceOver, among
  them the notifications list (VO-N), verbosity (VO-V), hot spots (VO-Shift with a digit to set, VO with a digit to
  go), the speech settings (VO-Command with the arrows), the help menu (VO-H), the Find commands (VO-Shift-F),
  style changes and same-level headings (VO-Command-C, VO-Command-M), tables (VO-R, VO-C, VO-Shift-T), paragraphs
  and sentences, and moving and resizing windows.
- **The Windows style is NVDA's.** 114 of the 130 commands in NVDA's reference: the review cursor, table navigation
  (Control with Command and the arrows on a Mac keyboard), the clipboard (Caps Lock C), repeat (Caps Lock X), sleep
  mode (Caps Lock Shift Z), screen layout (Caps Lock V), the synth settings ring, and Control to stop speech and
  Shift to pause it.
- **The keypad.** Mac style: VoiceOver's NumPad Commander, with VoiceOver's own keys; VO-Clear turns it on. Windows
  style: NVDA's desktop layout (7 8 9 lines, 4 5 6 words, 1 2 3 characters, keypad 0 held as the NVDA key); Clear
  switches between commands and typing numbers.
- **Audio ducking.** Other apps' sound is lowered while TurnOver speaks: Settings, Speech, or Caps Lock Shift D in the
  Windows style. Off to start with. The first time, macOS asks to let TurnOver record system audio; nothing is kept.
- **Plugins.** Label an unnamed button, give an item a key, have it read when it changes, or keep it quiet: VO-Slash,
  or Command Control Comma then P. A careful first step: plugins can do more in coming builds, each asking for what
  it needs.
- **Google Docs, Sheets and Slides.** TurnOver reads Google's own announcements as you move and type, as NVDA does.
  Google's screen reader support must be on: Command Option Z in a document; TurnOver tells you if it's off.
- **System prompts.** Prompts that appear behind your app ("would like to use your location") are read, and Tab and
  Space work in them.
- **The TurnOver menu is tidier.** This app first, then Settings, Apps, Keys, What to test, Send feedback, Tools,
  About and updates, Hand over or quit.
- **Microsoft Excel.** Cells are read as you move, content then address ("Monday, A2"); selecting says the range.
- **Right Option T.** It says the time, and twice quickly the date.
- **Your own keys.** TurnOver menu, Keys: give any key to a command, or take one away.
- **Speech.** Capitals can be said at a higher pitch, and speech can play on a chosen device: Settings, Speech.
- **Messages, Finder and Safari.** In Messages, Command T opens the Tapback reactions as a list. Finder reads desktop
  and icon view items with their kind. Safari says the new tab's title as you switch tabs.

### What to test

- The layer key: Command Control Comma, then N, S, K, J; and in an app VoiceOver reads (Calculator, say).
- Your usual work in your usual style: anything a key did before that it no longer does, tell us.
- Google Docs or Sheets, with Google's screen reader support on: moving, typing, the menus.
- The keypad, if you use one, in your style.
- A plugin: label an unnamed button in an app you use, then undo it.
- Ducking, with music playing.

### Fixed

- Word: TurnOver no longer quits when you come back into a table you had just left (reported by a tester).

- Typing straight after Backspace in Claude's prompt (and other web text boxes) came late: each Backspace waited for
  the box to report its caret. TurnOver now lets the next key through at once, as NVDA does.
- System prompts that appear behind the app you're in ("would like access to record your system audio", "would like
  to use your current location") are now said, as VoiceOver says them, and get the keyboard. In these protected
  prompts Tab and Space go straight to macOS, and if macOS refuses a VO-Space press TurnOver puts the focus back on your
  choice and asks for Space.
- In a dialog, Tab and VO-Space now agree: VO-Space presses the choice Tab reached.
- VO-Command-C (next style change) gives up after a third of a second rather than holding TurnOver up in a long note.
- The keypad stops speech as other keys do, and leaves sleeping apps and "pass next key" alone.
- Sleep mode no longer traps TurnOver's own menu over a sleeping app.
- "That was wrong" only marks the moment; pressing it twice no longer sends a report by itself.
- The clipboard (NVDA+C), link addresses and notifications are spoken but no longer written into the log or
  reports, which could carry a copied password or a two-factor code.
- The shortcuts list shows only keys that really do what it says in the current style.

- TurnOver Shift T no longer says the time: it was a tester's preference, not NVDA's or VoiceOver's (VO-Shift-T is a
  table's row and column now, in the Mac style).
- Keyboard help names the modifier keys as you press them: command, shift, option, control (left or right),
  function, and caps lock, the TurnOver key. Control no longer pauses speech while keyboard help is on.
- Windows style: Control Right goes to the start of the next word and reads it, as NVDA does; it read the text
  passed over (reported by a tester).
- Opening TurnOver from Finder or Spotlight no longer leaves you on TurnOver itself ("TurnOver has no windows"): it
  steps back to the app you were in (reported by a tester).
- Feedback reports are kept in TurnOver's own folder, the newest ten, not on the Desktop (a synced Desktop sent them
  all to the cloud); a copy goes on the Desktop only when no mail app opens (reported by a tester).
- The Voice menu lists voices for the languages set on your Mac, so a Spanish speaker can choose a Spanish voice for
  TurnOver itself (a tester).
- The function keys are never touched (build 16 could switch off "Use F1, F2 as standard function keys"; turn it back
  on once in System Settings, Keyboard) (a tester).
- Reminders: Tab in a new reminder announced the window between the title and the notes. Tab out of the sidebar had
  been judged "ignored" too quickly, and TurnOver then took Tab over in text fields too. Text fields now always get
  the app's own Tab, and TurnOver waits a little longer before deciding an app ignores it.
- Right and Left on a sidebar item answer at once ("expanded", "collapsed"), with the edge sound where there is
  nothing to open; they used to wait and say nothing.
- Text is never announced as "text": iPhone apps on the Mac (Books, Audible) said "Home, text, selected".
- Icon buttons with only a tooltip are named by it, as VoiceOver does (Cyberduck's Back, Forward, Browser,
  Bookmarks and History were just "button").
- Web pages inside apps (Bambu Studio's release notes): list numbers say "1", not "unknown, 1"; a heading is one
  stop, not read twice; icon-font symbols are no longer read as names.
- After waking or unlocking the Mac, TurnOver could hear none of your keys for several seconds (the lock screen's
  password field keeps the Mac's secure input on for a moment). VoiceOver now keeps the Mac until that is over, then
  TurnOver takes back the app in front.
- Chrome and Edge: tables are read once, by rows (they were read by rows, then by columns, then the header again);
  each item of a list is its own line (Google Drive's files ran together); toggle buttons say "toggle button,
  pressed", not "check box"; dialogs, menu bars and tool bars are named as you enter them.
- Excel opened fresh: its cells are read from the first arrow (it said nothing until Excel had been open a while).
- Switching to an app whose first focus has no name (Excel) no longer leaves the last app's text box in charge: its
  arrows were answered silently.
- Preview: pages are read as "page", not "unknown, unavailable"; tool groups are "grouping"; lists and other
  containers are no longer said to be "unavailable".
- A dot between words (Byword's "Markdown • 61 words") is read as a pause, not "bullet". A value that repeats the
  name is said once (Excel's headings). Review no longer stops on a table's untitled columns (Ulysses).
- Reminders: Tab between a reminder's title and its notes said the window and the list before each field. The
  window's passing focus is now held a quarter of a second and said only if nothing else takes the focus.
- Tabs say which one is showing ("Input, tab, selected, 2 of 2"). On the Mac the arrows move between tabs without
  switching, and Space switches; TurnOver did not say which was selected (System Settings' Sound).
- Switches say "switch, on" or "switch, off", as VoiceOver does, not "toggle button, pressed".
- A control reported twice (SwiftUI apps such as System Settings hand over two references for one) is read once.
- Review reads a row once: no more the row, then its cell, then each text in it (Reminders, Contacts, System
  Settings; the duplicates heard in the Windows style). Faster in long lists (Contacts).
- Focus on a scroll area itself says what it holds ("…, scroll area"), where it was silent (Shortcuts' editor).
- Safari: Enter or Space on a button you have tabbed to (a cookie banner's "Accept all cookies") pressed the link
  before it, or went to the group around it. They now go to the button the keyboard is on.
- Web pages: misspelled words in fields now say "spelling error", and inside a line, not only at its start (reported by a tester).
- Live regions inside other live regions are said once, not twice (a tester, The Playroom).
- Finder: Command Down with nothing selected (after Command Up to the top) says so, rather than nothing (a tester).
- WhatsApp with no chat open: the arrows go straight into the conversations (it said nothing until Tab), the
  arrows and Return work the sections when WhatsApp's own focus is on one, and Escape no longer drops the cursor
  (10 Oct 2026).
- Function keys: TurnOver no longer changes them at all. They behave as set in System Settings, Keyboard ("Use
  F1, F2, etc. keys as standard function keys"). Earlier builds switched them with the reader and put them back
  as media keys every time (a tester).
- TurnOver T reads the window's title as it is now; after a Safari tab switch it said the old one (a tester).
- Space in Podcasts, Music and other lists now plays and pauses, and in Finder opens Quick Look: TurnOver only
  takes Space when the selected row has a check box to tick (10 Oct 2026).

- Speech follows the Mac's output device: headphones or speakers chosen after TurnOver started now get its voice
  (headphones left TurnOver on the speakers, 9 Oct 2026). Confirmed by switching back and forth.

## 1.0, build 16

### New to try

- A slider or other control read as its value changes now reads the new value, not the one it had when it took the
  focus; a slider from 0 to 1 is said as a percentage.
- Mac style: VO M twice, the status menus, now includes TurnOver's own item at the end.
- Mac style: on a web page, typing while the reading position is on a text field goes into that field, as it does
  once VoiceOver's cursor lands on one; the field takes the focus and focus mode starts. In the Windows style letters
  stay quick-nav keys until Enter or Tab goes into the field, as in NVDA.
- Tab on a web page no longer announces the group a control sits in ("Description of App, grouping" on AppleVis).
- TurnOver Shift T reads the time, twice for the date, for Macs without an Insert key or the function keys (reported by a tester).
- A short start-up tone when TurnOver starts while VoiceOver has the Mac, so with Open at login you know it is there
  (a tester).
- Force quit, spoken. Command Option Escape (and Control Shift Escape in the Windows style) lists the running
  applications; choose one, then confirm to force quit it or ask it to quit normally. The Mac's own Force Quit
  window is silent with VoiceOver off. Also in the TurnOver menu as "Force quit an application".
- Automatic language switching now works in any app, not only where the text is marked with its language: a line in another script (Arabic under an English voice, or the other way round) is read with that language's voice in TextEdit, Pages or anywhere else, and so is a single character when you move by character (reported by a tester).
- The formatting key (VO T; TurnOver F in the Windows style) reports the first selected character when text is selected, and says "selected" first. Pressed twice, it gives the detail: colour, background colour, superscript or subscript, and alignment where the application reports it (requested by a tester).
- Word tables: TurnOver Up and Down move by row and Left and Right by column from wherever the caret is, and the table's size is said once. A new switch in Preferences, Document formatting, "Table row and column headers" (requested by a tester).
- Under the bonnet: Messages and WhatsApp are now described by small recipe files rather than code (the first step towards adding apps without a build, and towards plugins). You can put your own recipe for another chat app in ~/Library/Application Support/TurnOver/recipes; a file that won't load is named in the log.
- Windows style: a review step (TurnOver and the arrows) onto a control took the keyboard focus with it, as VoiceOver's cursor does, so after reviewing TextEdit's toolbar the arrows had left the text. NVDA's review cursor never moves the focus, so it no longer does in the Windows style; a setting in Preferences, Keyboard ("Keyboard focus follows the cursor") chooses: by style, on, or off.
- Safari: H on a heading long enough to wrap over two lines read only its first line, and the next H landed on its second line as if it were another heading (reported in testing). Quick navigation now reads the whole heading and skips to the next one.
- Finder: Command Up and Command Down made TurnOver hand over to VoiceOver for a few seconds (macOS reported TurnOver's own process in front for a moment), which felt like a crash. TurnOver no longer hands over on account of its own process unless one of its own windows is showing (reported by a tester).
- Mac style: VO M no longer has the focused item spoken over "Apple menu"; and after closing a menu with Escape, the focused item is read once, not three times (reported by a tester).
- Under the bonnet, from this week's code review: TurnOver's keys are decided on its main thread now, so an application that stops answering can no longer make macOS switch TurnOver's keyboard off (a TurnOver chord's letter then landed in the document). Nothing changes in how the keys work; it should feel the same or quicker.
- The App Store's End key (reading to the end of a long page) and Word's headings list (VO U) no longer hold TurnOver up while they wait for the application: "please wait" is said if they take long, and speech carries on meanwhile.

### Fixed
- Mac style: after reading from a field with the VO keys (VO Command Shift H from Claude's prompt), the first letter typed was taken as a quick-navigation key and only the later ones went into the field. A typed key now goes straight back to the field (reported in testing).
- If a chosen voice went silent, the guide now says how to get speech back: Command Control T for VoiceOver, then one line in Terminal (under "If something goes wrong").
- VO Right and VO Left along a big window (Music's grid, System Settings) asked the application thousands of questions a key; the answer is kept for a moment while you step along the same group.
- The log's "ms after the last key" figure was nonsense before the first key.
- TurnOver now has automated tests that run on every build, and a way of recording a window so an app can be tested without it running (TESTING.md).
- Quitting TurnOver from outside (a kill, an installer) now tidies up as a quit from the menu does: the top row back to the media keys, the curtain off.
- A BAUM display unplugged while TurnOver was using it could crash it later; fixed.
- Switching TurnOver off and on again at once could leave its keyboard layer half torn down; each start now has a layer of its own.
- A hand-over to VoiceOver that needed a second try could be read as you pinning the app to VoiceOver by hand; fixed.
- The code that decides which focus reports to follow is now nineteen named rules, one per special case, with tests; it should behave exactly as before, so please report any app where the focus seems to go astray.

## 1.0, build 15

### New to try
- Messages and WhatsApp (previews, off until you turn them on in the TurnOver menu, Applications). Your keyboard stays in the message box. Tab takes you to the messages, starting on the newest, and Shift Tab to the conversations. There, Up and Down move, Home and End go to the first and last, Return opens a conversation, and the shortcut menu (VO Shift M, or the right Option key in the Windows style) lists the message's own actions: reply, tapback, copy and so on. Escape goes back to the message box. TurnOver 1 to 9 read the latest messages from anywhere in the window, 1 the newest. New messages in the open conversation are read as they arrive. With no conversation open (WhatsApp), Tab goes straight to the conversations. In WhatsApp, the shortcut menu on a message opens WhatsApp's own menu for it (reply, react, forward and more), and Tab goes on from the chats to WhatsApp's bar of sections (Chats, Updates, Communities, Calls, Archived, Starred): Return shows that section's chats. The chats are found in whichever section is showing.

- Spelling errors anywhere: TurnOver E and TurnOver Shift E (VO Command E and VO Command Shift E in the Mac style) go to the next and previous misspelled word in any text, not just Word: TextEdit, Mail's message body, and text boxes on web pages, such as AppleVis's comment box.
- Braille: the display now shows what you're on, not what TurnOver says. Try arrowing through Mail's list, the TurnOver menu, a menu-bar menu, WhatsApp's chats and Music's shelves, and reading back through Terminal; try typing on the display in Claude's prompt or a chat box.
- Document formatting has a new setting, "Heading, link and button: say them": after the words, as VoiceOver ("AppleVis, heading level 1"), or before them, as NVDA. Out of the box it follows the keyboard style: after in the Mac style, before in the Windows style (requested by a tester).
- Notifications from other apps (a new message, a calendar alert) are read as they appear, as VoiceOver and NVDA do. Presentation has a switch for it (requested by a tester).
- Browse mode has NVDA's "screen layout" setting: links flow with the text as on screen, or each goes on a line of its own (requested by a tester).
- Browse mode has NVDA's automatic focus mode setting: a field taking the focus switches to focus mode by itself, or only when you ask (requested by a tester).
- The menu bar, as each style has it. Mac style: VO M lands on the Apple menu's title, Left and Right go along the bar, Down opens the menu and Escape leaves, as VoiceOver. Windows style: Command on its own opens the Apple menu, and Up and Down move through it as a list, as NVDA. Both start at the Apple menu, as the Mac does. The status menus too: VO M twice in the Mac style lands on them, Left and Right move along, Down opens one; Option B in the Windows style lists them.

### Fixed
- A review of the whole code base (8 Oct 2026) fixed: feedback reports no longer include what the braille display showed, notification banners, page titles or speech in other languages; speech comes back by itself when headphones or AirPods connect (the audio engine stopped and stayed stopped); say all says "end of document" after blank lines and the next arrow no longer resumes it; the braille cursor shows at the end of a line; a held dot 7 stops deleting if the display drops; settings are saved atomically and a settings file that won't read is kept beside the new one, not thrown away; a new setting can no longer wipe the list of apps TurnOver leads in; VoiceOver is started by opening VoiceOver.app if its shortcut doesn't bring it back; the tester-key-withdrawn alert is read; switching into focus mode by itself always says so; a page that gets shorter no longer leaves Left and Right stuck; five crashes on odd accessibility answers (a window closing mid-read, a stale item index in Music, a shrinking Finder sidebar, position values that aren't positions, Word's table cells).
- Mail: Return in the search field now says how many results there are and goes to them (nothing was said, and Tab went to the toolbar). Command Option F no longer reads the whole message the focus passes through on its way to the search field.
- Music: Return on a song in the library says "playing"; VO Shift N in the library says what's playing, not the table's hint.
- Terminal, Mac style: VO Up and VO Down read back through the output, as VoiceOver reads the screen.
- Mac style: leaving the menu bar with Escape or VO M says where you are.
- Mail: Command Shift D says "sent" once the message has gone (reported by a tester).
- Status menus: items that give no name (Control Center's on macOS 26) are named from their identifiers instead of all being "Control Center" (reported by a tester). In the Mac style, VO M twice lands on the status menus and Left and Right move along them, as VoiceOver.
- Menus: moving between menu-bar menus with Left and Right no longer reads the app's focus ("message body") in the gap between one menu closing and the next opening (reported by a tester).
- Mail's shortcut menu: letters go to its search box, which filters the menu; TurnOver now says what you've typed, and "no matches" when nothing is left, instead of going quiet.
- Mail: VO arrows in a big message list slowed down with every key until VoiceOver took over. They now answer straight away, however many messages there are (reported by a tester).
- Next and previous spelling error (TurnOver E, TurnOver Shift E, VO Command E) work in any text: TextEdit, Mail's message body and web pages' text boxes (AppleVis's comment box), not just Word (reported by a tester).
- A voice that doesn't speak in TurnOver no longer leaves it silent: TurnOver goes back to a voice that works and tells you (reported by a tester).
- Mail: a message opened in its own window could leave you stuck on its header, a blank field where the arrows read nothing. Reading now starts in the message.
- The cursor no longer says a heading's name twice ("Discover, heading, Discover" in the App Store).
- Terminal: new output wasn't read at all, and Return said "new line". A macOS update changed how Terminal describes itself; TurnOver recognises it again.
- Podcasts: search results are read properly (no more just "Explicit"), Return opens a show, and a show's page no longer reads the search results behind it. Follow, Play and the other header buttons are each their own item.
- Music, Podcasts and TV: Tab now reaches a fourth area, the tool bar, with Back, Share, More and Search. More opens the menu with Unfollow, Add to Library, Delete from Library and the rest.
- Music, Podcasts and TV: Space says what it did (playing, paused, stopped), and corrects itself if the app changes its mind. Live radio's Stop and a played episode's Replay are understood. If something doesn't start (it may need a subscription or a download), TurnOver says so instead of "playing".
- Music, Podcasts and TV: searching reads the results and puts you on them. "Middle dot" and "bullet" are no longer read in titles. Status lines such as "Refreshing content" and "Loading…" aren't items any more.
- Music, Podcasts, TV and the App Store: opened from the Dock or Spotlight (not switched to), they now read the page as soon as it appears, instead of just the app's name.
- Alerts in Music and the App Store ("Delete these songs?") say each button as you Tab.
- WhatsApp: Tab in the search field goes to the results (chats, contacts and messages that match), even with a chat open.
- WhatsApp: Media is in the sections; Calls lists your calls; Settings works with Tab, the arrows and Caps Lock arrows, each page says its title, and Escape goes back a page or closes Settings (WhatsApp ignores Escape and Command W there).
- WhatsApp: coming back with Command Tab says where you are; opening a chat says the message box once, not twice; your own message isn't read again when it changes from sent to delivered to read.
- Messages: Return in the message box says "sent", not "new line".
- Mac style: VO Right and VO Left read a window column by column (WhatsApp's sidebar, chats and chat no longer interleave), and start with the window's close, minimise and full screen buttons, as VoiceOver does. Text that keeps its words in a description (WhatsApp's sidebar) is no longer skipped, and nested headings say their name.
- VO Space on something that opens and closes (WhatsApp's More) says "expanded" or "collapsed".
- Something focused inside a container of the same name (WhatsApp's Settings) is said once.
- Word: closing Find with Escape reads what was found; Command Tab back to Word reads the line you're on; dialogs and the Save sheet no longer say "document" between their fields; inserting a table no longer says "out of table".
- Word, Mac style: VO Up and VO Down move by rows in a table, as VO Left and VO Right move by cells. In the page, VO Left and VO Right move by character, as VoiceOver, instead of jumping to the sidebar.
- Windows style: Caps Lock F reports the formatting, as NVDA+F. Find is Caps Lock Control F, with Caps Lock F3 and Shift F3 for the next and previous match.
- Formatting says the language by name ("English (United Kingdom)"), not its code.
- Return on a button in an alert sheet presses that button, not the alert's default: in Claude's "Claude is still working" alert, Return on "Quit anyway" pressed Cancel.
- Word: choosing a heading in the rotor (VO U) goes to it and reads it, instead of landing in the sidebar.
- Lists whose rows hold their name as a heading (System Settings, Privacy & Security, Automation) read the name, not just "collapsed".
- Braille: the display shows what you're on, not what TurnOver says. "New line", window names, "selected …" and "end of document" no longer cover the line for seconds; Mail's list, the TurnOver menu, WhatsApp's and Messages' chats and messages, and the shelves of Music, Podcasts, TV and the App Store all show on the display and stay there. Roles and states use NVDA's short forms (btn, chk, lnk, h2). A message gives way as soon as you move.
- Braille in Word: the line you're on shows as you type and move (it showed only "doc").
- Braille: menu items show on the display as you arrow through a menu (a "Mail menu" message was hiding them), and the menu bar's title no longer comes back after the menu closes. Terminal's review lines show on the display as you read back.
- Word: Command B, I and U say "bold on", "italic off" and so on once, not twice.
- Braille typing on a web page in browse mode, with the keyboard in a text field (after reading Claude's reply with VO Command H), switches to focus mode in the field, so the display shows what you type.
- Braille typing: typing fast no longer jumps the focus to the Dock. A space that lands just after a letter, while you're typing, types the letter and a space instead of running a command ("a" with space was "previous item"). Space with dots 3 4 says where you are, as in VoiceOver. Input help says plainly when a chord isn't a command.
- Braille typing: a word whose last cell was pressed together with space (the word "the" with space a moment early) is typed, not lost. Dot 7 says what it deleted. Return or dot 8 that sends a message (Claude, chat boxes) no longer says "new line".

## 1.0, build 14

### Fixed
- Podcasts: Return and Space now play an episode from the Home page and the shelves, and say how long is left. Podcasts' episodes there have no Play button, only a Play action of their own, so Return used to open the episode's page instead. Shift Return still opens the page. (reported by a tester)
- Pasting your tester key with Command V works. It did nothing in the key box until TurnOver was restarted. (reported by a tester)
- The menu bar no longer reads the window behind it: opening the menus (TurnOver M, Control F2) or moving between them could say "message body, new line" first. (reported by a tester)
- Mail: quoted replies say "quote level 1", "quote level 2" as you read into them. (reported by a tester)
- Mail: Option Backspace says each word as it's deleted, not only the first. (reported by a tester)
- Reading a link word by word says "link" once, on its first word, instead of after every word. (reported by a tester)
- New setting, TurnOver menu, Preferences, Document formatting, Table cell coordinates: turn off "row 3, column 2" as you move between table cells in Word. (reported by a tester)
- VoiceOver's find keys (VO Command H for headings, L for links, J for controls, T, X and G, with Shift to go back) now work everywhere, as in VoiceOver: on a page whose keys are going to the page (Claude's prompt, a web form), and in windows that aren't documents at all. They said "not in a document". (reported by a tester)

## 1.0, build 13

### New to try
- Your own tester key: the first time this build starts, TurnOver asks for the personal key sent to you by email. Open the link in that email, or paste the key into the box. Each beta build now works for 90 days, and every update starts that again. TurnOver menu, Tester key says whose key it is and until when this build works.
- Hints, as in VoiceOver: pause on an item and TurnOver says what you can do with it ("Space presses it", "Return opens its page"), with hints of their own in Mail, Safari, Terminal, Word, Finder, Claude, TextEdit and the App Store. Turn them off in the TurnOver menu, Preferences, Presentation, Hints.
- The App Store (preview, off until you turn it on in the TurnOver menu, Applications). Up and Down go through every app on the page, the whole of each shelf rather than three at a time; Left and Right jump between shelves, saying each one's name and size. Return opens an app's page, which reads in order: the app and its price, its rating, age rating, chart place, developer and size, the description, reviews, What's New, privacy, the developer's accessibility notes and more. Space presses the app's button (Open, Get, Update, Re-download), and so does Return on the app's own page; a price needs two presses, so nothing is bought by accident. Tab moves to the sidebar (Search, Discover, Arcade, Updates…); Command F searches and reads the results; Escape goes back.
- Quick keys wrap round the page: after the last heading, H goes on from the top and says "wrapped to the top" (Shift H: "wrapped to the bottom"). Turn it off in the TurnOver menu, Preferences, Browse mode.
- VoiceOver's way of moving, in the Mac style: VO Left and Right move within a group (a toolbar, a sidebar, a list, a pane) in the order things are on screen, and stop at its end; a group says how many items it holds ("tool bar, 9 items"), VO Shift Down goes into it and VO Shift Up comes back out. Tab and the arrows are unchanged. Turn it off in the TurnOver menu, Preferences, Keyboard.
- TurnOver Left and Right now move through everything in the window, item by item, going in and out of groups by themselves, as Narrator's Caps Lock arrows do. Handy in alerts and dialogs where Tab misses things. TurnOver Shift with the arrows still works as before. The current word is TurnOver W, and the current sentence TurnOver Control S.
- Mail: Escape leaves the message you're reading, as in Outlook on Windows: a message in its own window closes, and you're back in the message list.
- Music, Podcasts and TV (previews, off until you turn them on in the TurnOver menu, Applications). Up and Down now go through the whole page, every shelf and every item on it, reading further down as you go; End goes to the very last item. Left and Right jump between shelves, Tab moves between the sidebar, the page and the player, Return opens or plays, and Escape goes back, landing on the item you opened. A video from Music's Radio page plays in its own player; Space plays and pauses, Escape leaves it.

### Fixed
- Braille tables in every language macOS has, not only your Mac's own: TurnOver menu, Preferences, Braille, Braille table, Other languages (Slovenian, Italian, Arabic and many more). (reported by a tester)
- Finder's sidebar: move TurnOver's cursor into it (TurnOver Right in the Windows style, VO Shift Down in the Mac style), then Up and Down go through it, Return or Space opens that place, and Left and Right close and open its sections; Escape goes back. Finder never gives its sidebar the keyboard, so TurnOver works it for you. Tab and Shift Tab go round the window as in Windows Explorer: files, sidebar, toolbar, search, and back to the files. Elsewhere, when the cursor lands on something that can take the keyboard, the keyboard now goes there too, as in VoiceOver and Narrator. The toolbar's Back and Forward and its four view buttons are now items of their own.
- More of VoiceOver's keys in the Mac style: VO Home and End (first and last item), VO Command Home and End (top and bottom of the window), VO Up and Down, VO Shift Escape, VO J (jump to the linked item), VO Return (select), VO Backslash (disclosure triangle), VO Shift Space (click), VO Shift H (help tag), VO Shift N (hint), VO Shift W (read the window), VO Shift U (link address), VO Command Space (actions) and VO F2 twice (window chooser).
- The list of shortcuts (TurnOver Slash) shows the keys for the style you're using: in the Windows style, the VoiceOver keys were hiding some Windows ones.
- Return on a button you've tabbed to in an alert now presses that button. macOS sends Return to the alert's default button whatever has the focus, so "Open System Settings" could press "Deny".
- Claude: a summary line that stayed the same ("Ran 23 commands, compacted the session…") was read again every few seconds while Claude worked. A name is now read only when it changes.
- Hints are only spoken for where you still are: a hint for the message list was said as a message window came up.
- Mail: quoted text says its level as you read into it ("quote level 1", "quote level 2"), as VoiceOver does; and a message opened in its own window (with the preview pane hidden) starts reading in the message, not on the toolbar (reported by a tester).
- Pages in two languages: TurnOver's own words ("link", "heading") are said by your main voice, not the other language's; text in another script is read by that language's voice even when the page doesn't say which language it is; and each language can have its own speech rate (TurnOver menu, Preferences, Speech, the language, Rate) (reported by a tester).
- Hints are no longer spoken over a page being read out, and edit fields no longer get the obvious "Type to enter text".
- Typing: after deleting a letter, the word is said as it now is ("think", Backspace, Space says "thin"), and Option Backspace says "deleted" and the word (reported by a tester).
- Brave, Chrome and Edge: H and Shift H move through every heading both ways; Shift H said "no previous heading", and H could skip one (reported by a tester).
- Selecting a paragraph on a web page or in a message (Shift Option Up and Down) is read, as character, word and line selection are (reported by a tester).
- New to try: each thing to try opens into a list of its lines, to arrow through, instead of one long item (reported by a tester).
- In a one-line field (a search box, the To field), Up and Down read the field instead of only playing the edge sound (reported by a tester).
- "New line" on Return can be turned off: TurnOver menu, Preferences, Keyboard, Say new line on Return (reported by a tester).
- Reading quickly with the arrows no longer plays the edge sound in the middle of text (reported by a tester).
- Touch ID and password prompts (such as the App Store confirming your Apple Account) now say their message first, then their button, instead of "coreautha, Untitled, window".
- Dialogs that are more like pages (the App Store's account window) are read line by line with Up and Down, text as well as buttons; a web page inside a dialog is read in browse mode.

## 1.0, build 12

### New to try
- Screen recognition (OCR), as NVDA's TurnOver R: TurnOver reads the text in the window from the screen, for apps that don't tell a screen reader what's in them (games, Steam, pictures of text). Press TurnOver R where TurnOver leads, or Command Control R anywhere, even where VoiceOver leads. Up and Down move through rows; Left and Right by character, with Option or Control by word; Tab jumps between columns and sections; Return or Space clicks the word you're on, Shift Return right-clicks, Option Return double-clicks; M moves the mouse there without clicking; TurnOver R again re-reads; Escape closes. Columns, like a sidebar beside the main text, are read one after the other, and lists and tables row by row. It works on a braille display too: routing keys move to a word, and pressed again click it. The first time, macOS asks for Screen Recording permission for TurnOver. Options are in Preferences, Screen recognition.
- Application chooser: every app with a window, including system alerts that Command Tab leaves out (such as macOS asking to allow Screen Recording), with each app's windows under it. Return switches there. Mac style: TurnOver F1 twice, as in VoiceOver. Windows style: Option Tab, as Windows+Tab is Task View.

### Fixed
- Safari: after reloading a page, the arrows could say "nothing on this page yet" while the page was there (Tab reached it). Safari had swapped the page for a new one; TurnOver now moves to it.
- Context menus say "context menu" as they open, from VO Shift M, the right Option key or Shift F10.

## 1.0, build 11

### New to try
- Keyboard style: Mac, which works like VoiceOver key for key (as now), or Windows, which makes the Mac feel like a PC with NVDA: NVDA's commands on the TurnOver key, Command alone for the menus, Option alone for the Dock, F1 to F12 as function keys, and in Finder, Return opens and F2 renames. Switch with TurnOver Shift K, or Keyboard style in the TurnOver menu. More Windows keys are on the way.
- Windows keys for editing, in the Windows style: Control C, X, V, A, Z, S, O, N, P, F and W do what Command does with them; Control Y redoes; Home and End go to the start and end of the line, Control Home and Control End to the start and end of the document; Control with the arrows moves by word or paragraph; Control Backspace deletes a word; Command F4 quits an app (Alt F4). Terminal keeps its own Control keys. These apply where TurnOver leads; where VoiceOver leads, the keys are the Mac's as always.
- Input help: press Escape twice to leave it.
- Unverified apps: in the TurnOver menu, Applications, Unverified apps lists every app you have open that TurnOver hasn't been checked with yet. Switch any of them to TurnOver to try it; they may not read well, and feedback on them is welcome.

### Fixed
- The Dock: after Escape, TurnOver kept reading the Dock with nothing selected and the arrows went back into it. Escape now returns to the app you were in, and the arrows in the Dock are the Dock's own (Left and Right move, Up opens the item's menu).
- Safari: when a page stopped answering for a few seconds, TurnOver could be left with nothing to read until you switched apps. It now looks again once Safari answers, and treats a page with no address yet as still loading.

## 1.0, build 10

### Fixed
- Sleep and the lock screen: if the Mac slept or locked while TurnOver was in charge, VoiceOver stayed off and the login screen had no speech. TurnOver now turns VoiceOver on as the Mac sleeps or locks, and takes over again once you're back in.

## 1.0, build 9

### New to try
- TextEdit joins the previews: TurnOver menu, Preferences, Applications, TextEdit, "TurnOver leads".

### Fixed
- First run: TurnOver never asked for Input Monitoring, so on a new install it could not take over until you found the setting yourself. It now asks straight after Accessibility, and if macOS doesn't show the question, TurnOver explains and opens the right page of System Settings.
- Braille: plugging the display in by USB while it was connected over Bluetooth left it with nothing on it. TurnOver now moves to USB by itself, notices when a Bluetooth display stops answering, and keeps looking for a display after losing one.
- Braille: with the TurnOver menu open, the display's joystick and keys moved through the application behind it (Mail's message list) instead of the menu. They now drive the menu: up and down move, the routing keys or joystick press choose, letters typed on the braille keyboard jump to items, and space with dots 1 2 closes it.

## 1.0, build 8

### New to try
- Braille: TurnOver now drives your braille display while it leads, using the same drivers and braille tables as VoiceOver, so any display VoiceOver supports should just work. It shows the line you're on (contracted, with the word at the cursor uncontracted), the item in focus, and what TurnOver says by itself, such as live updates. Panning, routing and the display's keys work as with VoiceOver, and you can type on its braille keyboard, contracted or letter by letter. USB displays need nothing setting up; for Bluetooth, pair the display in VoiceOver Utility, then turn on "Use a braille display paired over Bluetooth" in TurnOver menu, Preferences, Braille, where you'll also find the table, typing and display settings. TurnOver 1 and TurnOver slash cover the display's keys and chords. Please tell us which display you have and how it goes.
- Pages in other languages are read with a voice for that language, as in NVDA. TurnOver menu, Preferences, Speech: turn it off, or choose the voice for each language.
- "That was wrong": press TurnOver Shift J the moment TurnOver gets something wrong. It quietly marks the moment and you carry on. Send all your marked moments together later from the TurnOver menu, Send feedback, or press the key twice to send straight away.
- Want TurnOver to support an app? Switch to it, then TurnOver menu, Preferences, Applications, Request support (at the end of the list). An email to us opens with a description of how the app is built (no content); add a line about what you use it for. The most-asked apps come first.
- The TurnOver menu from anywhere: Command Control N opens it even in apps VoiceOver leads, as does "TurnOver menu" in the menu bar. TurnOver steps in for the menu and hands back when you close it.
- Word says the page number as you arrow onto a new page; TurnOver Shift L says the page and line.
- Finder and Claude are in the Applications list as previews, off until you turn them on (TurnOver menu, Preferences, Applications).
- Control now pauses speech, and pressing it again carries on, as in VoiceOver.
- After each update, TurnOver tells you what's new to try, and lists it in the TurnOver menu under New to try.

### Fixed
- Safari: a page that was still loading, or stopped answering, could leave TurnOver with nothing to read, and every arrow said "top" or "bottom". TurnOver now says the page has nothing on it yet, keeps looking, and reads it as soon as it arrives. (reported by a tester)
- Menus: moving along the menu bar quickly, a menu's name ("Edit menu") could be cut off as the menu opened. It is now always said.
- Uninstall now offers to remove just the app, keeping your settings and permissions for when you install it again.

## 1.0, build 7

- Long paragraphs are now read in full. Before, speech often stopped after the first sentence or so of a long paragraph and moved on to the next: Say All in Word skipped most of each long paragraph, and long lines on web pages and in Mail were cut short too. (reported by a tester)
- Moved TurnOver from Downloads to Applications? Command Control T and the TurnOver Key login item now follow the copy you open, rather than looking for the old one. (reported by a tester)
- TurnOver menu: Left goes back a level from any submenu, including one made only of settings. Left and Right still turn a number up and down (rate, volume); Shift Up and Shift Down step a choice back. (reported by a tester)
- Safari: video players switch to focus mode by themselves, so YouTube's own keys work (K plays and pauses, J and L skip). Escape goes back to browse mode. (reported by a tester)
- TurnOver menu, Uninstall TurnOver: removes TurnOver, its settings, logs, login items and permissions, and turns VoiceOver on. Handy for starting clean.

## 1.0, build 6

- Mail: Shift Tab from the message list goes to the mailbox list, and Tab comes back. Mail only lets Tab reach its mailboxes while VoiceOver runs.
- Mail: writing a message, Tab now reaches the Priority, From and Signature pop-ups after the subject, so you can change which address you send from.
- Menus: in Mail's Move To list, each account's name is read as you move into its mailboxes. Submenus Mail opens by itself are no longer announced at every step, and nothing is read twice. Right Arrow into a submenu now always works, and the edge of a menu gives a bump.
- Mail's context menu: the "Ask Siri" box at the top is now read.
- Typing: with word echo on, an apostrophe is no longer read separately ("I've", not "apostrophe, I've").
- Screen Curtain: when VoiceOver's Screen Curtain is on, TurnOver keeps the screen black while it is in charge. Before, the curtain ended when TurnOver took over. (raised on AppleVis)
- Turn the curtain on or off for now with TurnOver Shift Escape (or VoiceOver's own VO Shift Underscore). To choose always, never, or the same as VoiceOver: TurnOver menu, Preferences, Speech, Screen Curtain while TurnOver leads.

## 1.0, build 5

- Word: a document opened while Word is still starting up is now read. Before, Word kept the page from TurnOver, and you heard nothing until you switched away and back. TurnOver now does that switch for you, without VoiceOver coming on.

## 1.0, build 4

- Fixed: macOS could say it "could not verify" TurnOver and refuse to open it, depending on how the download was unzipped. (reported by a tester)
- Word: the question "TurnOver wants to control Microsoft Word" no longer disappears after five seconds. It now waits for your answer, and TurnOver tells you what is being asked. (reported by a tester)
- Word: next and previous spelling error (TurnOver E) now search the whole document, not just the pages near the cursor. (reported by a tester)

## 1.0, build 3

- When an app is slow to answer, TurnOver now says "please wait" instead of "not responding". It is usually just busy, such as a page still loading.
- Mail: Command Shift N now says "checking for new mail".

## 1.0, build 2

- TurnOver's speech was quieter than VoiceOver's. It now matches VoiceOver at the same Mac volume.
- A speech volume setting: TurnOver menu, Preferences, Speech, Volume (Left and Right change it, 10 to 200 percent).

## 1.0, build 1

- The first beta. TurnOver leads in Mail, Safari and Terminal, with Microsoft Word as a preview you can turn on (TurnOver menu, Applications).
- Updates arrive by themselves; TurnOver menu, Updates, to check now or to install them automatically.
- Send feedback is in the TurnOver menu.
