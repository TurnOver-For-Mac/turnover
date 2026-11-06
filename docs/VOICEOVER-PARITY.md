# VoiceOver parity in the Mac style (12 Oct 2026)

The aim: "this is all the voiceover stuff that should be in perfect parity" (Apple's VoiceOver User Guide, "VoiceOver
commands and gestures on Mac", vo14111, and its seven command pages: General, Interaction, Orientation, Navigation,
Web, Text, Search; 189 keyboard commands). The rule (same day): the Mac style is VoiceOver's keys exactly, the
Windows style NVDA's; no keys from people's preferences; every variation is put to the maintainer.

How it was checked: every command's keys were put to TurnOver itself (turnover-plugin explain, Mac style), which says
which command answers. Where an NVDA command answered a VoiceOver key in the Mac style, the Mac style now does
VoiceOver's (the Windows style keeps NVDA's).

## Where it stands

After the decisions (built the same day, VoiceOverDecisions.swift; checked key by key with the key explainer):

| | Commands |
|---|---|
| VoiceOver's own command answers, as in VoiceOver | 178 of 189 |
| Says "not available in TurnOver yet" (caption and braille panels, visuals, Activities, page columns, table grouping) | 11 |

Built today (VoiceOverParity.swift): the help menu and commands (VO-H, VO-H-H), the Find commands menu (VO-Shift-F),
VO-Command find by kind (bold, italic, underline, colour and font changes, plain text, visited links, blockquotes,
different and same kind of item, frames), read to here (VO-B), paragraph and sentence moves, phonetic spelling
(VO-W-W-W, VO-C-C), tables (VO-R, VO-R-R, VO-C, VO-C-C, VO-Shift-T, VO-Shift-T-T), VO-F3 in text and VO-F3-F3, VO-F5
three ways, VO-F6, window and item size and place (VO-Command-F2, F3), mouse to cursor and back (VO-Command-F5,
VO-Shift-F5), window to the front (VO-Shift-F2), the desktop (VO-Shift-D), Notification Centre (VO-O), Control
Centre (VO-Shift-O), parent folder (VO-Command-Backslash), scroll bars (VO-Shift-S), groups (VO-Shift-Left, Right),
window spots (VO-Left and Right Bracket, and your own with Command), page statistics and the sort button
(VO-Shift-Vertical Line), Screen Curtain (VO-Shift-F11), describe image (VO-Shift-L; off a picture, the window, since 2 Nov 2026), save the last phrase
(VO-Shift-Z), lock the VO keys (VO-Semicolon), cursor tracking off and on (VO-Shift-F3), move and resize the window
or the item (VO-Grave Accent, VO-Tilde, with Command for the item), multiple selection (VO-Command-Return), sticky
mouse (VO-Command-Shift-Space), arrow-key Quick Nav (VO-Shift-Q).

## To decide: TurnOver's own commands on VoiceOver keys

Each is a TurnOver command (neither VoiceOver's nor NVDA's) on a key VoiceOver uses for something else.

1. **VO-N**: VoiceOver's Notifications menu (the notifications heard lately); TurnOver's menu here. Recommended:
   VO-N the notifications; the TurnOver menu by Command Control N (it already works everywhere).
2. **VO-V**: VoiceOver's Verbosity rotor; TurnOver's "hand over to VoiceOver" here. Recommended: VO-V a verbosity
   list (punctuation, item details, hints); handing over by Command Control Shift T, which already switches readers.
3. **VO-Shift-K**: VoiceOver's Option key Commander on or off; TurnOver's keyboard style switch here. Recommended:
   VO-Shift-K turns your right Option keys on or off; the style switch stays in the TurnOver menu (Settings,
   Keyboard), and TurnOver Shift K stays in the Windows style.
4. **VO-Shift-J**: VoiceOver's jump to the autocorrect or input method panel; TurnOver's "that was wrong" mark here.
   Recommended: VO-Shift-J VoiceOver's; the mark on VO-Command-Shift-J (free in both).
5. **VO-Slash**: VoiceOver's custom label; TurnOver's shortcuts list here. **VO-Shift-Slash**: VoiceOver's user
   guide; TurnOver's plugin maker here. Recommended: VO-Slash the plugin maker (labelling an item is what it does,
   and more); VO-Shift-Slash the TurnOver guide; the shortcuts list on VO-H-H, VoiceOver's own commands menu.
6. **VO-Command-C**: VoiceOver's next style change; TurnOver's copy of the last thing said here. Recommended:
   VoiceOver's; VO-Shift-C already copies the last phrase.
7. **VO-Command-M**: VoiceOver's next heading of the same level; TurnOver's next Word comment here. Recommended:
   VoiceOver's; Word's comments on a key of Word's own in TurnOver (to choose).
8. **VO-1 to VO-9**: VoiceOver's hot spots (with Shift to set, Command to describe, Command Shift to watch,
   VO-Shift-X the chooser, VO-Shift-Brackets next and previous); in TurnOver, the newest messages in chat apps and
   the parts of a panes app (and NVDA's input help on VO-1). Recommended: hot spots in the Mac style; the chat and
   panes digits stay in the Windows style.
9. **VO-Backspace**: VoiceOver's only use is a tab stop on TextEdit's ruler; NVDA's "review to the focus" answers
   here now. Recommended: leave it.

## To decide: VoiceOver features with no direct TurnOver form

10. **VO-F8** VoiceOver Utility: recommended the TurnOver menu's Settings.
11. **VO-Command-F8** VoiceOver Tutorial; **VO-Shift-Slash** user guide (with item 5): recommended the TurnOver
    beta guide for both, until there is a tutorial.
12. **Caption panel, braille panel, tile visuals** (VO-Command-F9, F10, F11, VO-Shift-F9, F10, VO-F10): visual aids
    for someone sighted beside you. Recommended: not now.
13. **VO-Clear**, NumPad Commander on or off: recommended it turns TurnOver's own numpad keys on or off.
14. **VO-X, VO-X-X** Activities (sets of settings per app or situation): recommended not now; TurnOver's plugins
    may carry settings later.
15. **VO-Command-Y, Shift-Y** columns on a page; **VO-Command-=** grouping in tables: WebKit offers no search for
    them. Recommended: not now.

## the decisions (12 Oct 2026, one by one)

1. VO-N: yes, VoiceOver's notifications list; the TurnOver menu on Command Control N. Make this very obvious in the
   update notes and What's new: people use it a lot.
2. VO-V: yes, a verbosity list (punctuation, item details, hints); handing over on Command Control Shift T. Cover it
   prominently in the update notes: people must not feel they've lost the way back to VoiceOver.
3. VO-Shift-K: yes, VoiceOver's Option key Commander on or off. The keyboard style switch moves to Command Control K
   in both styles (TurnOver's own keys are Command Control: N, R, T, Shift T, now K; a family kept on purpose).
   Caps Lock Shift K is not NVDA's (checked in NVDA's command reference), so it leaves the Windows style.
4. VO-Shift-J: yes, VoiceOver's (autocorrect and input method panel). The "that was wrong" mark moves to Command
   Control J in both styles; Caps Lock Shift J leaves the Windows style. (Send feedback's notes and the beta guide
   must say so.)
5. VO-Slash: yes, the plugin maker (labelling the item first). VO-Shift-Slash: the TurnOver guide. The shortcuts list
   on VO-H-H. (Windows style: check Caps Lock Slash and Shift Slash against NVDA when building; any variation goes to
   the maintainer.)

Rule (12 Oct): three layers. VoiceOver's keys in the Mac style, NVDA's in the Windows style, and Command Control
keys for TurnOver's own features in both, for people moving between Mac and Windows.
6. VO-Command-C: yes, VoiceOver's next style change; VO-Shift-C copies the last phrase. Command Control keys added,
   both styles: Command Control Slash the shortcuts here, Command Control Shift Slash the plugin maker, Command
   Control C copies the last thing spoken.
7. VO-Command-M: yes, VoiceOver's next heading of the same level. Word's comments in the Mac style through the rotor
   (VO-U, Comments) and This app; no Command Control key (Word's, not TurnOver's).
8. VO digits: yes, VoiceOver's hot spots in full in the Mac style (VO-Shift-digit set, VO-digit go, VO-Command-digit
   describe, VO-Command-Shift-digit watch, VO-Shift-X chooser, VO-Shift-Brackets next and previous). Chat messages and
   pane parts move to Command Control 1 to 9 in both styles; Caps Lock digits are NVDA's again in the Windows style.
9. VO-Backspace: yes, strict parity: VoiceOver's ruler tab stop; VO-Shift-F4 back to the focus. NVDA's review to focus
   stays on Caps Lock Backspace in the Windows style.
10. VO-F8: yes, the TurnOver menu at Settings; Command Control Comma opens Settings in both styles.
11. VO-Command-F8: yes, the TurnOver guide for now; an interactive tutorial later (a lesson per style). Command
    Control H opens the guide in both styles. (Windows style: check NVDA's user guide key when building.)
12. Caption panel, braille panel, tile visuals: yes, not now (the caption panel later, for trainers and sighted
    helpers); their keys say "not available in TurnOver yet".
13. NumPad: sooner, next after these questions ("it's important to some people"). Mac style: VO-Clear turns
    VoiceOver's NumPad Commander on or off; Windows style: NVDA's desktop layout on the keypad.
14. VO-X Activities: yes, one feature for both: per-app settings profiles (VO-X in the Mac style, NVDA+Control+P in
    the Windows style), after the keypad; until then "not available in TurnOver yet".
15. VO-Command-Y, Shift-Y, VO-Command-Equals: yes, not built (Safari gives no way); the keys say "not available in
    TurnOver".

Keypad (built 12 Oct, Keypad.swift): VO-Clear turns on the NumPad Commander with VoiceOver's own 78 default
assignments, read from macOS 27's ScreenReaderConfiguration; each runs the VoiceOver command TurnOver answers on its VO
key. Not yet: Command keypad Enter (select text under the cursor), Shift keypad 9 (to the table's header).

## TurnOver's own keys: a layer (12 Oct 2026, after the code review)

Command Control with a letter is crowded in Apple's own apps (read from the menus of 14 apps on this Mac: N in
Finder, Safari, Terminal, Preview, Xcode; T in Finder, Mail, Terminal, Preview, WhatsApp, Xcode; R, C, H, I, J, K, M,
Shift T likewise). "we shouldn't be stepping on toes of other apps". Decision: one layer key, as JAWS's
layered keys: Command Control Comma, then a letter (N menu, T switch reader, K style, J that was wrong, H guide, I
describe image, C copy last spoken, R recognition, S settings, Slash the shortcuts here). The emergency start or
quit: Command Control Period, a single press, owned by the TurnOver Key helper. Free in all 14 apps read. Testers are
asked for their opinion, with the reasoning, in the update notes.
Where VoiceOver reads the app, Command Control Comma steps in as the menu does: says "TurnOver", waits for the letter,
does it and speaks, hands back; Escape or 3 s without a letter: "cancelled", hand back (agreed).

Speech settings (12 Oct: "vo command left and right"): not on the seven command pages, so the first audit
missed them. VO-Command (older VoiceOver) and VO-Command-Shift (Apple's guide now, unac009) with Left and Right choose
a setting, with Up and Down change it: voice, rate, volume, punctuation (SynthRing; TurnOver has no pitch or
intonation setting yet). Lesson: Apple documents commands outside the command pages too.

## TurnOver's own keys in the VoiceOver style

- VO-Shift-Y (2 Nov 2026): screen recognition, the window's text read from the screen to move through and click.
  VoiceOver has no such command; VO-Shift-L did it away from a picture until Oliver asked for the two to be apart.
