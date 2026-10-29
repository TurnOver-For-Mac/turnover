# Patterns: what Mac apps do, and how TurnOver copes

Lessons from testing, written down so the next session (and plugin authors) start from them. Each pattern is
handled in TurnOver's core, so it works in every app; an app module is only for a quirk of one app. When a new app
misbehaves, check this list first.

## Focus

- **A control takes the focus, then the app moves it away at once.** Safari's settings buttons: focused, then 10 ms
  later Safari puts the focus back on the toolbar. Fix: after TurnOver moves the focus, focus news for anything else
  is set aside for 0.3 s; if the control has lost the focus by then, TurnOver holds the place on it (reads it, Space
  and Return press it, Tab goes on). `SettingsPanePlugin.focus`.
- **A pane grabs the focus when it loads.** Mail's and Safari's settings tabs pull the focus into the new pane (the
  Homepage field). Fix: hold the focus on the tab while switching; put it back, looking the tab up afresh (loading
  can rebuild the toolbar). `PreferenceTab.go`.
- **An unnamed window claims the focus.** Safari, and its SandboxBroker helper, report an untitled window as focused
  during pane switches. Fix: ignore it and read the app's real focus. `AXHandler.focusChanged`.
- **A frame keeps the focus.** A Cloudflare check left Tab on its frame. Fix: if a nested web area still has the
  focus after 0.25 s, say its name and "frame".
- **Some controls do not say which window they are in.** Safari's settings controls have no AXWindow. Fix: walk up
  the parents to the window. `SettingsPanePlugin.windowOf`.

## Keys the app ignores

- **Tab only reaches text fields** (the Mac's keyboard navigation at its default). Fix: in settings windows, Tab and
  Shift+Tab go through every control in screen order (rows top to bottom, then left to right); from the tab bar,
  Tab to the first control and Shift+Tab to the last. `SettingsPanePlugin`.
- **A list ignores the arrows** and has nothing selected (Safari's Feature Flags). Fix: TurnOver walks the rows
  itself, reading each with its position; Space ticks a row's check box. `SelectableList.moveVirtually`.
- **A web page's menu ignores the arrows** (Claude's model picker in Safari). Fix: in a menu inside a web area,
  TurnOver moves through the items itself and presses the chosen one. `MenuNavigationPlugin.webMenu`.
- **A synthetic press is ignored** (AppleVis's forum Save). Fix: when the control already has the keyboard focus,
  send the real key instead of an accessibility press. `BrowseModeDocument.activate`.

- **Tab does nothing on some controls** (Mail's compose formatting bar). If the focus has not moved 0.25 s after
  Tab, TurnOver moves it in screen order, round at the ends; the named group is remembered, and Tab there is
  TurnOver's at once (30 ms, not 300). `SettingsPanePlugin` tab trap.
- **Several scripts can share a key** (Scripts.swift: the latest declared first, the first available runs). One
  name per key had let the ribbon's Tab silently replace the settings panes' Tab.

- **Mail keeps controls out of Tab** even with keyboard navigation on: the mailbox list (reachable only while
  VoiceOver runs) and a message's Priority, From and Signature pop-ups. The Mail module adds them (Shift Tab to the
  mailboxes; the header order To, Cc, Bcc, Reply To, Subject, Priority, From, Signature, message).
- **Menus with section headings** (Mail's Move To: separator, then a dimmed title with the items' identifier): say the
  heading on entering its section. Typing in Mail's context menu goes into its "Ask Siri" box, dims the commands that
  don't match, and leaves Right moving that box's caret: open the submenu by accessibility.

## Names

- **Controls with no name**, labelled by text beside them (Safari's settings: "Safari opens with:"). Fix: take the
  static text on the same row to the left, else just above. `TurnOverObject.neighbourLabel`.
- **Rows holding a check box** read only their other text. Fix: a row's content includes the check box's name and
  state. `TurnOverObject.contentText`.
- **A state that switches silently** (a tick box ticked with Space, a toggle pressed): the rule, from 16 Oct
  2026, is that a state is said as it switches, never only when you come back to the item. Mac apps: the value
  change notification on the focused control (`Speech.speakCheckState`); Steam's pages: aria-checked and aria-pressed
  watched on the item under the cursor or the focus (the helper's observer v7).
- **The page and the buffer disagree** after a press changes the page without loading (AppleVis's menu). Fix: rebuild
  the buffer after a press, and before arrowing on a changed page.

## Shipping

- **Zip without extended attributes** (`ditto --norsrc --noextattr`): as "._" files they break the bundle's seal
  when anything but Finder unzips it, and Gatekeeper says it "could not verify" the app ().

## Editing text

- **WebKit puts an editing caret at the end of a line on the line break itself.** Read as the start of the next
  line, Down read the empty line below and skipped lines after a deletion (Mail's compose window). In editable web
  text, a caret on a break after text is at the end of that line. `WebTextInfo.lineOffsets`.
- **The app moves the caret by its own lines** while editing: never cut a line into NVDA's 100-character browse
  pieces there, or the words in between are never read.
- **Option+Right stops at the end of a word**: say the word passed over, not the space or comma after it.
- **Check it automatically**: compare the speech after each key with the line at WebKit's caret (the scratch
  check.sh harness: 70 moves, then edits).

## Stalls

- **An app stops answering accessibility questions** (Safari hung). Fix: after one timed-out question, leave that app
  for 3 s and say "Safari not responding". `AXHealth` in TurnOverAX.
- **A page's script is stuck but accessibility still answers.** Fix: read from the buffer; if a Tab brings no news
  from the app twice running, say "page not responding". `PageWatch`.
- **Anything slow on the main thread** trips the watchdog at 4 s: walk big trees off the main thread with a deadline
  (Find, Item Chooser, Rotor), cap page reads at 2 s, never wait on Word or on macOS's permission dialogs on main.
- **A background loader must not append to the arrays the keys read.** The App Store now builds a local page and
  shelf snapshot on its serial worker, then commits it on main after checking the session, request and base revision.
  Commit and finish the original command before replaying later keys; a retired completion must leave newer work
  alone. This also keeps a captured app's confirmation from patching a different row at its old index (#54, 28 Oct 2026).

## Microsoft Word

- **Tables are real accessibility tables** (AXTable, AXRow, AXCell with row and column index ranges), each cell's text
  its own text area that takes the focus. Read and move through them by accessibility (instant), not AppleScript.
  The page's text holds only a stand-in ("Table, 6 Rows, 2 Columns, , "), and Word's line ranges run past a
  paragraph mark into it. `WordTableCell`.
- **A document opens with the focus in the sidebar or ribbon**, and Word builds no page until something reads
  through the window. TurnOver reads it off the main thread and focuses the page. `WordAppModule.sidebarToPage`.
- **AppleScript to Word waits on the Automation alert**: unanswered, every script times out (even osascript's).
  The alert also lasts only as long as the script that raised it waits: Word's first script waits 300 s ().
- **Word lays out only the pages near the view** for accessibility: "nothing beyond the caret" there is not
  "nothing in the document"; fall back to Word's own whole-document search ().
- **Word started cold builds no page for accessibility** until it is activated again: TurnOver steps into its own
  windowless process and back, unseen and without a hand-over (`AppWake`). Likely true of other apps that
  build their accessibility lazily.

## Apple's shelf apps (App Store, Music, Podcasts, TV, Books): learnt on the App Store, 6–7 Oct 2026

These apps share one framework. Identifiers say so: `<App>.shelfItem.<Kind>CollectionViewCell`, `shelf.header`,
`offerButton` (App Store), `seeAllButton`. What holds for one holds for the others; AppStoreView.swift is the first
full reader of it, and the model for the rest (MediaView, for Music, Podcasts and TV, should move to it).
- **The page is a collection of shelves, and only the ones on screen are children.** Each shelf (AXSectionList) and
  each item answers AXNextContentSibling and AXPreviousContentSibling (also First, Last, Above, Below): VoiceOver's
  route through what is not on screen. Walk them, never the children. A whole page reads in about half a second.
- **Shelves far from the screen are empty shells.** A shelf's children appear once it comes near the screen: bring
  it into view (AXScrollToVisible on the shelf), wait 250 ms, read again. Read a batch (40 items), then more as the
  arrows reach the end; reading all 529 items of Discover at once took 5 s and froze TurnOver.
- **A carousel shows three items; all of them are there by content sibling.** Read the first dozen, the rest when
  the arrows reach the end of what was read. Never page with the Backward and Forward buttons.
- **Rows are reused as the list scrolls.** An element remembered for one app can show another app later, or be an
  empty shell; an item read ahead of the screen has a frame thousands of points away. Before pressing anything,
  find the row on screen again by its name; move the page there with the scroll area's AXVerticalScrollBar (its
  value is settable, 0 to 1; a binary search on it, judged by which items are on screen, takes one to three steps).
  AXScrollToVisible on a reused element scrolls to the wrong place. A press meant for WhatsApp once got another app.
- **Never press a remembered button.** Find the offer button inside the row just found, at the moment of pressing.
- **The tile's own action is the dangerous one.** An app's tile has one action, "buy for £24.99"; the row's press
  reports success and does nothing. Open an item by clicking its icon (the AXImage named for the app, not
  "Artwork"), checked to be off the offer button and inside the page's area. A price needs a second key press.
- **Controls with no press action:** sidebar tabs change only when the row is selected (AXSelectedRows on the
  outline); the account button needs a click.
- **Two layouts of the same window.** After a relaunch the sidebar's parts sat loose and the page's scroll area was
  an AXGroup; results were AXLinks with the button's words in the title. Find things by identifier and role, not
  by their place.
- **What a reader should say.** Labels come in the wrong order ("GB, SIZE, 2.76"), shouted ("GAMES WE LOVE"), or as
  a media control's name ("Video"): reorder by identifier (productPage.badge.rating and the rest), speak capitals
  as words, and prefer an item's texts to an inner button's name.
- **A sheet over the window** (Touch ID to install) has the keys, Escape included; the reader stands aside.
- **A card over the window** (Arcade's categories, such as Family): the window's children become a card
  (`productPage.pageBaseCardView`, named "Family, APPLE ARCADE") and its own scroll area; the sidebar is gone.
  Look for the page in whatever is on top, not in a fixed place; Escape closes the card.
- **Dialogs that are pages** (the account sheet: a title, settings, "Cannot Connect … Retry"): read their text as
  well as their buttons, and a web page inside one in browse mode.
- **Downloads report progress in the button's title** ("2.1% loaded", help "Cancel"): Space then cancels, so ask
  first; announce each quarter and the end.

### Music, Podcasts and TV (7 Oct 2026, MediaView)

- **Each app scrolls differently.** Music: the page's scroll bar value can be set (0 to 1); "scroll down by page" fails and the wheel does nothing. TV: the same, and its bar's value drops as the page grows. Podcasts: the bar has no value, so scroll by AXScrollUpByPage / AXScrollDownByPage on the page group (`podcasts.listen[…]`), one page at a time, waiting for each (they don't queue).
- **Only shelves near the screen exist.** Keep a model of the page and merge each new read into it by shelf title and item key; order shelves by their place on the whole page (screen position, less the page's top, plus scroll offset). Read a new page from the top.
- **Identity:** Music's and TV's item identifiers carry the item's id (`[id=ra.…`, `.id="umc.cmc.…"`); before pressing an item read earlier, check its element still has that identifier, else scroll back to where it was read and find it again.
- **Reading is slow in the background:** Music's sidebar takes 3 to 4 s (child and action calls on 35 rows); keep the sidebar when only the page has scrolled.
- **TV's carousels** list cells far to the right with no words until TV shows them; AXScrollToVisible doesn't fill them in, so skip them ("See all" has the full list).
- **Actions hidden as custom actions:** Podcasts' Home episodes have no Play button; Play is a custom action on the episode ("Name:Play, Remaining Time: 15 minutes\nTarget:…"), performed by passing that whole name to AXUIElementPerformAction. Before deciding something can't be pressed or played, check its action names for "Name:" entries.
- **Music's video player** fills the window (`Toggle Controls`); the page keys must stand aside so Escape leaves it.

## The Mac itself

- **A system prompt (SecurityAgent) can open without getting the keyboard.** TurnOver said "Password" while the
  keys went to Mail. TurnOver now gives the prompt the keyboard, and holds back typing aimed at a password field in
  an app that does not have the keyboard. Keys reaching TurnOver at all while a password field "has focus" mean it
  does not: a real one turns on Secure Input. Never log typed characters.

- **Secure Input** (a password field focused) hides every key from TurnOver. Work from the field's length instead
  (`SecureEcho`). Safari can leave Secure Input on after the field (ESCALATIONS E17).
- **AVSpeechSynthesizer.write sends an empty buffer mid-utterance** (after the first part of a long text, every
  voice, measured 6 Oct 2026), then carries on. Taking it as the end cut long paragraphs short (). The end is
  the delegate's didFinish.
- **macOS sends no "terminated" notice for a menu-bar app.** Watch by polling (the TurnOver Key helper).
- **Writing into another app's data folder** can trigger a privacy check: keep each process's files in its own place.
- **Caps Lock set to "No Action"** in Keyboard settings stops VoiceOver using it as a VO key (not TurnOver's doing).
- **Accessibility and Input Monitoring are one entry per app for the whole Mac**, tied to the signature. Two copies
  signed differently (a development build and a published one in another account) take the entry from each other
  and macOS keeps asking. Sign every build with the same Developer ID. IOHIDCheckAccess can also stay "not granted"
  in a running process after the user grants it: opening the keyboards is the real test (`InputAccess`).

## VoiceOver and the keyboard (16 Oct 2026)

- **VoiceOver reads keys below a session-level tap**: TurnOver's tap (`.cgSessionEventTap`) never sees a VO chord
  while VoiceOver is on, and during secure input it sees only modifiers while VoiceOver still hears everything.
- **A tap at the head of the HID level beats VoiceOver**: TapProbe swallowed Control Option Right and Control
  Option F1 with VoiceOver running, and VoiceOver said nothing (by ear, three presses each). This is the basis
  of running beside VoiceOver without turning it off: TurnOver owns the keys in its apps, VoiceOver keeps the rest.
- **VoiceOver can't be muted or driven from outside**: AppleScript `perform command` refuses (error 4); only `output`
  works. Its own keys, posted at the HID level, do work (the toggle shortcut; VO-Shift-S should likewise).

## Parts of a window that won't take the keyboard (Finder's sidebar, 7 Oct 2026)

- **Symptom:** the screen reader's cursor reaches the part, but the arrow keys still go somewhere else (Finder's file list).
- **Why:** its AXFocused can't be set, and a mouse click on it doesn't give it the keyboard either (Finder keeps the keyboard in the file list unless macOS's keyboard navigation is on). VoiceOver works round this privately.
- **Fix (ObjectNavigator.hold, HeldListPlugin):** when the cursor lands in a list, table or outline that refuses the focus, TurnOver *holds* it. While the cursor stays there, Up/Down/Home/End move through its rows, Return/Space choose (AXSelectedRows, as a click would), Left/Right close and open, and Escape returns to the focus. Choosing keeps the cursor there although the app's focus moves.
- **Rule:** first try to give the keyboard to what the cursor lands on (set AXFocused). Only if that is refused, hold it. Never assume the cursor and the keyboard are in the same place.
- **Tab with a held part:** the app's own Tab acts on where its keyboard really is (Finder's Tab in the file list chose the next file). While TurnOver holds a part, Tab and Shift Tab are TurnOver's: they go on round the window's parts in a set order (Finder: files → sidebar → toolbar … search → files), so Tab never sends you back into the part you just left.

## Chat apps (Messages, WhatsApp; 7 Oct 2026, ChatView)

- **Three parts:** conversations, messages, message box. Leave the keyboard in the box and let TurnOver's cursor visit the other two, with Tab, Shift Tab and Escape. Typing is never disturbed, and the app's own Tab (which jumps unpredictably) is never needed.
- **Each message's own actions** (reply, tapback, copy, pin, mark as read) are custom actions on the item. List them by name in the shortcut menu (GlobalCommands.contextMenuHandler).
- **New messages:** watch the newest message once a second while the app is in front. Read it when it changes, except just after the box was emptied (your own send) or when the conversation title changed (another conversation opened).
- **Privacy while building:** use ~/Library/Developer/TurnOver/tools/axshape (masks every word) and shape-only dumps. Never print message text into logs or the session.
- **Search results sit on top of the list:** WhatsApp leaves its chat list in the tree under the results. While anything with the results' identifiers ("ChatListSearchView_…") is showing, those are the list (Spec.resultsPrefix).
- **A section that isn't chats** (WhatsApp's Calls): its cells ("…Cell" buttons) are TurnOver's list. Don't press call rows in tests: they may ring.
- **Sheets (WhatsApp's Settings):** the chat keys stand aside while the focused window is a sheet. Escape presses the sheet's Back button, or its Close (WhatsApp ignores Escape and Command W). A page opening in the sheet focuses a nameless group: say the navigation bar's heading instead.
- **Saying "sent":** Messages says nothing when Return sends, and TurnOver's text field said "new line" as the box emptied. The chat module takes Return in the box and says "sent" if the box empties, unless the app says so itself (Spec.saysSent, WhatsApp).

## Catalyst apps (WhatsApp, Messages, Podcasts…; 7 Oct 2026)

- **The app's focus wanders:** a nameless AXGroup takes the focus moments after a press, an arrival or a chat opening. It says nothing, so it must neither cut off speech (Events: no Speech.focusMoving for it) nor end TurnOver's browsing (ChatAppModule.handleEvent: "drift").
- **Ask the app where the keyboard is:** TurnOver's focus may be that group. For "is the search field active?", read the app's AXFocusedUIElement (ChatAppModule.inSearch).
- **Setting AXFocused is ignored** on cells in a list; hold the list in TurnOver instead (as Finder's sidebar).
- **Words in the description:** texts are AXStaticText with the words in AXDescription and no value. Anything that tests "has a value" (ObjectNavigator.isItem, report) must also take the description.
- **Every text is pressable** (AXPress): don't use "has a press action" to tell controls from status lines.
- **Headings nest:** an empty AXHeading holds the named one. The inner one is the item.
- **Columns overlap:** WhatsApp's chats column starts at the window's left edge, under the sidebar. Order columns by the tree, not by their frames (ObjectNavigator.groupItems: blocks).
- **Window buttons first:** in VO navigation, close, minimise and full screen come first, whatever the frames say (Finder's content starts under its toolbar, at the top of the window).

## macOS changes under us

- **Terminal (7 Oct 2026):** the text area lost its AXTerminalTextArea subrole; it is still described as "shell". The module now matches either. When an app's support goes quiet after an update, check the subrole and identifiers it was matched on first.

## Word, stress test (7 Oct 2026)

- **Automation permission:** heading and spelling commands use AppleScript; refused (-1743), TurnOver says how to allow it. Check System Settings, Privacy & Security, Automation first when Word's commands say nothing.
- **The page blips in dialogs and sheets:** Tab in Insert Table or the Save sheet passes the focus through the page for a moment. While AXHandler.modalInFront(pid:) is true, ignore the page's focus (and don't give the page's hint). The Save sheet is sometimes the focused window itself, sometimes a child of the document's window: check both.
- **Leaving the app with the page focused** must reset "crossing a page" (event_appModuleLoseFocus), or coming back is silent.
- **Focus after a window change:** Word gives the page its focus a moment after the Find bar closes, with no event. Ask the app again after 0.35 s, but only while TurnOver's focus is still in another window (Word's table cells are TurnOver's own objects).
- **VO keys in documents:** VO-Left/Right are characters and VO-Up/Down lines in a document or text area; in a Word table, cells and rows (forward to the focus's table_* scripts).

## Braille (7 Oct 2026)

- **Speech and braille are different channels.** Speech.speakMessage also flashes the words on the display; use it only for news that isn't on screen. Words that describe what the display already shows ("new line", window names, pane names, "selected …", "end of document") use Speech.speakOnly. An item TurnOver's own cursor lands on (held lists, the menu, the VoiceOver cursor) uses Speech.speakItem, which keeps it on the display until the focus or caret moves (Braille.item / releaseItem).
- **20 cells is small:** a message is held 4 s per display width; a window name cost 12 s. Messages give way when the focus or caret moves (Braille.focusOrCaretMoved).
- **Short forms on the display:** roles and states as NVDA shows them (Braille.shortForms).
- **"Editable" isn't reliable:** Word's page doesn't say so; a document with navigable text is text for braille.
- **Log:** "braille shows (kind): text" records every change, for testers' logs.
- **Menus with a search box (Mail's shortcut menu, "Ask Siri"; macOS 26+):** letters don't jump to items, they type into the box and filter the menu; the box's caret takes the arrows when nothing matches. Read the box back and say "no matches"; don't try to take letters out or step the highlight with arrows (Down with nothing highlighted goes into the box).
- **Menu gap on Left/Right between menu-bar menus:** the old menu is found closed by its size before menuEnd arrives; count that as "just closed" (lastMenuClosed) or the app's focus in the gap (Mail's message body) is read.
- **Status items on macOS 26.5:** Control Center's items carry no title or description; name them from kAXIdentifier.

## Searching a window for a part (8 Oct 2026)

A breadth-first walk of a window that enters a list's rows is unbounded in practice: Notes' notes list had 830
rows, each with children, and one Tab held the main thread for four seconds until the watchdog handed over to
VoiceOver. A part of an app (a sidebar, a list, a text area, a toolbar) is never inside a row, a cell, a static
text or a button, so a search for parts stops at those, never descends into a table, outline or list, visits a
few hundred elements at most, and gives up after a time budget (PanesView.find). Anything found is kept for a
while and checked with one call (its role) before use. The same applies to any "find the X in the window" code:
bound the visit count and the time, and skip the roles the thing cannot be inside.

## Grids and document apps (Day 2, 10 Oct 2026)

- **A grid that moves its selection, not its focus:** Excel posts only AXSelectedCellsChanged on each arrow. Where the
  focus is in that grid, its one selected cell is the new focus (AXHandlerNotifications). A wrapper cell with one
  cell inside is unwrapped.
- **One cell, three shapes:** Excel's focused part of a cell is an AXCell named by its address, an AXTextArea named
  by its address, or an AXGroup holding the value, depending on its state. All carry AXRowIndexRange, so the app
  module walks up to the cell in the row and reads that ("Monday, A2"; ExcelAppModule).
- **The grid is only there for an assistive app:** Excel's grid appears once AXEnhancedUserInterface is set and
  Excel is in front; before that its focus is a nameless AXUnknown over the grid.
- **A new app's nameless first focus must still replace the old one:** ignoring it left the previous app's text
  box as the focus, and its caret commands answered the new app's arrows in silence.
- **Disabled is not "unavailable" for containers:** Preview's page list and PDF pages, and Excel's read-only cells,
  report AXEnabled false. Only things that can be used are said to be unavailable (Role.neverUnavailable).
- **Unmapped roles:** AXPage (Preview's PDF pages) and AXRadioGroup (segmented tool groups) were "unknown".
- **Windows keys in an app that already takes them:** Excel's grid answers Home, Control Home and Control arrows as
  on a PC; translating them (Command Up) went to the wrong cell. WindowsRemap.windowsGrid leaves them alone.
- **A separator dot is not a bullet:** "Markdown • 61 words" (Byword's status line) is read with commas.
- **An app's own first-run screens:** Excel without a licence opens on a Microsoft 365 trial dialog with the trial
  button focused; Return there would start the trial flow. Tests press "Skip to read-only mode" by name, and the
  press tool refuses any button with buy, get, trial, free, subscribe, sign in or purchase in it.

## Chromium pages (Chrome, Edge; Day 3, 10 Oct 2026)

Tested on a page with Google Docs' and Sheets' patterns (tools/web/gapps.html) in throwaway copies of Chrome and
Edge with empty profiles: no keys or clicks to a browser, only accessibility reads and TurnOver's own quick keys
simulated inside the probe.

- **Tables three times over:** a Chromium table's children are its rows, then its columns (AXColumn, each holding
  the same cells), then a group repeating the header row. The buffer reads the rows only.
- **Listbox options are bare texts:** role="option" comes through as AXStaticText inside an AXList, with no line
  break between them in the page's text, so they ran together. Each item of a list is now its own line.
- **Different names:** aria-pressed is subrole AXToggleButton (Apple's is AXToggle); dialogs are AXGroup with
  subrole AXApplicationDialog (alerts AXApplicationAlert, AXApplicationAlertDialog).
- **Chrome comes to the front on its first launch** even when opened in the background: send the front back at
  once, and check the front app before every test key.
- Edge reads exactly as Chrome does: the fixes are Chromium's, not one browser's.

## Cross-platform apps (Day 4, 11 Oct 2026)

- **Tooltips as names:** AppKit icon buttons (Cyberduck's segmented Back, Forward, Browser, Bookmarks, History) have
  no title or description, only AXHelp. A control with nothing else is named by its tooltip.
- **Web views inside apps (Bambu Studio):** list markers are AXListMarker (was "unknown"); icon fonts put private-use
  characters in names ("󰋜"); a heading's text child repeated the heading in review.
- **Bambu Studio** downloads its network plug-in by itself at launch and offers updates in a dialog whose own
  buttons are not exposed; its home page is two web views of unnamed pressable images. Plugin territory.
- **Dropbox** is a menu-bar app with no windows; its item refuses AXPress (-25204). Opening Dropbox.app from
  /Applications starts its real copy in ~/Library/Application Support/Dropbox, which restarts itself if stopped.

## iPhone and iPad apps on the Mac (Day 5, 11 Oct 2026)

- **Audible** is an iPhone app (Wrapper/Audible.app, com.audible.iphone); Books and Voice Memos are Catalyst. All
  put their words in AXDescription, texts included, so a text has a "name": its role must not be added ("Home,
  text, selected").
- **First-run questions:** Voice Memos asks to turn on iCloud (Cancel keeps the setting), Audible opens on a
  marketing offer. Tests press only what leaves a setting as it was, by its identifier or name.

## Protected system prompts (12 Oct 2026)

**How it shows:** a privacy prompt ("would like access to record your system audio", "would like to use your current
location") comes up behind the app in front and is never said; VO-Space on "Allow" does nothing, or the prompt puts
its focus back on "Don't Allow" and draws itself again.
**Why:** the prompts are drawn by agents (UserNotificationCenter, CoreLocationAgent, SecurityAgent, coreautha,
CoreServicesUIAgent) that don't always become the active app, and macOS refuses an Accessibility press on their
buttons from anything but VoiceOver. A real key from the keyboard is always accepted.
**TurnOver's answer (SystemPrompts.swift):** the agents are watched twice a second, and a new prompt is said ("system
dialog, …") and given the keyboard. In these prompts Tab and Space go to macOS untouched (the real focus moves; a real
Space presses). If TurnOver presses a button there itself (VO-Space, Return) and the prompt is still up 0.6 s later,
the focus goes back onto that button and TurnOver asks for Space. Never press a protected prompt in tests.

## A program TurnOver starts has TurnOver's permissions (13 Oct 2026)
**Seen:** the Kokoro helper, started with Process (NSTask), answered AXIsProcessTrusted true and had Input
Monitoring: macOS counts a child against its "responsible" parent, so anything TurnOver starts could read and drive
every app. **Answer:** helpers start through DisclaimedSpawn (posix_spawn with the responsibility disclaimed, as
browsers start their content processes): probed, the helper then had neither. Two traps on the way: posix_spawn
keeps signals the parent ignores (TurnOver ignores SIGTERM, so the helper couldn't be stopped: set the defaults and
an empty mask), and the parent must keep the child's pipe handles (dropping them closed the pipes and the helper
quit). System tools TurnOver runs (ditto, killall) stay on Process; any plugin's or third party's program must not.

## Keychain items and rebuilt command-line tools (13 Oct 2026)
A keychain item remembers the program that made it. An ad-hoc signed tool is a different program after every
rebuild, so the next read waits on a "wants to use your keychain" prompt, which may never show (a release tool hung
silently; no request was ever seen). Sign such tools with the Developer ID under a fixed identifier: the keychain then knows them across rebuilds. Never rebuild a keychain tool ad hoc.
## Focus resting on a nameless group between items (13 Oct 2026)
Spring (a Twitter client) moves the focus tweet, nameless AXGroup, next tweet on every arrow. The group says nothing,
but its ancestors replaced the ones compared with, so the timeline's "Home" group was entered again and said each
time. The core's answer: within half a second of a stop on a nameless group, the ancestors from before it still
count as known (FocusChanges.present, AXHandler.beforeNamelessStop; logged "passed through a nameless group").

## Safari's spell checking stops (14 Oct 2026)
After Safari had run for a day, its text boxes stopped being checked: Command ; selected nothing, the word's context
menu had no suggestions and no Ignore or Learn Spelling, and WebKit reported no AXMisspelled or AXMarkedMisspelled.
Quitting and reopening Safari brought it back. The tell, from the log: a context menu on a misspelled word
with "Look Up" first and no spelling items. TurnOver's own search (TurnOver E, VO-Command-E) does not depend on it:
with no marks from the app it asks macOS's spell checker over the whole text (Behaviors.goToMisspelling).

## Collections in sections; disabled items you can open (parts sweep, 14 Oct 2026)
AppKit's NSCollectionView (Freeform's boards) is an AXList/AXCollectionList whose children are AXSectionList sections
(each starting with an empty AXGroup header), and the items, buttons, are inside them. Each item reports
AXEnabled false though it can be selected and opened, and Up and Down in a one-row grid do nothing. TurnOver took
the section for the only row ("list, 1 of 1") and, finding the list didn't select it, walked it virtually,
keeping every arrow from the app. The core's answer: a collection's rows are its sections' items
(SelectableList.rowsAndKey), items of a section are never "unavailable", and Up or Down that changes nothing in a
collection is the edge.

## The window's own buttons have tooltips (14 Oct 2026)
The green button in SwiftUI windows (Voice Memos) carries help "this button also has an action to zoom the window"
and no title. A tooltip names an icon button, but never the window's own buttons: they're named by their subrole
(close, minimise, zoom, full screen).

## A page's own menu announces itself as opening (17 Oct 2026)
- **A web page's navigation (role="menu") posts AXMenuOpened as it loads and never posts a close.** Counted as a
  real menu it held Safari's focus back for a whole visit, and the letters typed in the next app went to menu
  type-ahead. Three guards (AXHandlerNotifications, FocusChanges.ruleMenuOpen, AXHandlerApplications): a web menu
  opening with no key for 2 s is the page's structure, not counted; focus landing elsewhere in the page ends a
  counted web menu; an application's menus are dropped when it leaves the front.

## Preview's PDFs are a document, not a web page (17 Oct 2026)
- **Preview gives its document area the focus as one element** (an AXGroup, subrole AXSharedDocumentContainer) with
  an AXPage per page (AXPageIndex; AXPageIndexDescription empty), each holding its text and AXHeading elements, and
  AXCustomRotors on each page. TurnOver's web buffer reads it unchanged (5 pages, 119 lines, 6 ms). Fix: an app
  module may name a browse root (AppModule.browseRoot); Preview names the container; the browse document says
  "page 2 of 5" as a line crosses onto a page (BrowseModeDocument.announcePageIfChanged).
- **Preview gives accessibility none of a PDF's annotations** (highlights, notes, text boxes, drawings). Fix: read the
  file with PDFKit (the window's AXDocument) and say each mark after the line it marks (PreviewAppModule.marks).


## The system's menu bar items live in MenuBarAgent (23 Oct 2026)
- **On macOS 27.2 the clock, Control Centre, battery, Wi-Fi and user items belong to MenuBarAgent**
  (com.apple.MenuBarAgent), each an unlabelled AXGroup holding the labelled AXMenuExtra; asking Control Centre's own
  process for its extras bar answers no value, and SystemUIServer's is empty. The status menus list already asked
  every process; the Notification Centre and Control Centre keys asked only Control Centre and said the panel was
  not available. Fix: StatusMenus.find(identifier:) over the three system hosts (StatusMenus.systemHosts).
- **Notification Centre's panel is not a window.** Notification Centre keeps one full-screen window for banners; the
  open panel is a scroll area in it holding the AXNotificationListItems group, one AXNotificationCenterAlert per
  notification. Nothing takes the keyboard focus; Escape or the clock closes it. Fix: NotificationCentrePanel waits
  for the list and moves the review cursor in; the banner reader remembers the panel's history instead of reading it.

## A window with nothing in it by accessibility (Parallels Desktop, 23 Oct 2026)
- **Parallels Desktop's installation assistant (App Store edition) exposes a toolbar and the three title-bar
  buttons and nothing else:** no content in the tree, every hit test answers the window, and the app does not
  implement the enhanced-interface flags VoiceOver sets. Screen recognition is the only way in and it works, but
  cards laid out in columns are read row by row (issue 73), and TurnOver says only window on arrival (issue 74).

## From a public AX probe to a reading adapter (28 Oct 2026, App Store, issue 174)

1. Record app/macOS versions, Accessibility trust, actual foreground app, and both VoiceOver's flag and observed
   process state. Compare the same public page with VoiceOver on/off; label an untested state explicitly.
2. Keep returned errors, legitimate absence and reader-process backoff distinct. A separate probe has its own
   health state. Probe with deadlines, query/decoding limits and no application actions before changing an adapter.
3. Choose the public representation that exposes the content. App Store navigation children can expose content
   missed by ordinary children. Preserve their order; successful empty is authoritative. Test typed fallback rules.
4. Carry discovered identities into the adapter, then resolve them freshly before acting. Reject ambiguous or
   recycled elements. A readable child array alone establishes neither purchase access nor complete control.
5. Try a reversible action separately and verify its resulting page/selection. Purchase/download actions require
   their own user intent and confirmation; they are excluded from the structural preview.
6. Retire work on newer focus, page or reader intent; reject stale callbacks and incomplete publication. Turn each
   observed shape into a public-content fixture with cancellation/error cases before widening live coverage.

## App probing refinements (29 Oct 2026, macOS 27.2)

- An inspected focus element must not suppress traversal when that same element is also the window. Inspection
  and traversal have different visited sets. A clipped prefix establishes only what was visited, not absence.
- Probe foreground state explicitly. Music and Podcasts initially returned cannotComplete in background samples;
  their warmed foreground samples succeeded without VoiceOver. This does not establish why the first call failed.
- Chromium's content can sit below toolbar/list branches. The bounded extended profile can reach its WebArea;
  advertised text-marker names still need successful read/action checks before claiming behavior.
- Media requests carry the actual native window, not just a process ID, page title or MainWindow. Two windows in
  one app can share those other properties. Recheck current window before publication, scrolling or activation.
- Settings' General buttons exposed AXAttributedDescription but omitted standard title/description/help. The
  narrow label bridge prefers the standard fields, caps decoding, and falls back when the optional shape changes.
- A successful AXFocused write does not prove keyboard movement. Settings re-resolves the part and reads the
  actual focused element; missing or incomplete ancestry is not proof that focus is elsewhere.

## A sidebar press that returns success without changing page (TV, 29 Oct 2026, issue 186)

TV 1.7.2 on macOS 27.2 advertised AXPress on the first cell of each sidebar row. Oliver's live trial returned
success pressing Home, but Search remained selected and later reads still held its Browse categories. A separate
bounded read-only probe confirmed Home unselected, Search selected, and AXSelectedRows settable on the outline.
The row itself did not advertise AXPress. These are different observations: an advertised operation or successful
action return is not the resulting selection. Verify selection and body change separately. A page title derived
from the sidebar selection alone cannot establish that the old content has been replaced.

## Useful media content before a fixed pause ends (TV, 29 Oct 2026, issue 188)

Nine clean shelf completions in Oliver's TV trial took 557–678 ms, including a fixed 500 ms client pause; one
overlapping current snapshot already had new items at 223 ms. The TV module now enables an optional early
read with a small work budget. An unchanged/incomplete early result waits at the same scroll position until
the existing settling point, rather than scrolling again prematurely. A current same-page publication with
genuine new item keys can fulfill that load and retire its timers. New executed navigation owns the cursor,
even if it returns to the same item; queued arrows keep their order. Other media apps keep the default timing.
This fast path does not establish that a half-second is enough for every machine or network. Timers are
scheduling choices; only observed content establishes readiness. Full provider-unavailable handling remains
a separate live-check limitation, not an invented empty page.
