# NVDA parity in the Windows style (12 Oct 2026)

The aim: "I'm building for parity between voiceover in mac mode and NVDA in windows mode." The Windows style is NVDA's
keys (the laptop layout, Caps Lock as the NVDA key); no keys from people's preferences; every variation is put to
the maintainer. The VoiceOver side is VOICEOVER-PARITY.md.

How it was checked: every command in NVDA's command reference (reference/nvda-docs/keyCommands.html; the core
sections, 130 commands with a laptop key) was put to TurnOver itself (`turnover-plugin explain <key> com.apple.TextEdit
--style windows`), which says which command answers. NVDA's Alt is the Mac's Command key, by position (WINDOWS-MODE.md).

## Where it stands

After the decisions (built the same day; checked key by key with the key explainer, and by reading for the keys it
can't see: Control and Shift taps, keys that only answer in a table, in Word or on a page):

| | Commands |
|---|---|
| NVDA's command answers, as in NVDA (or adapted to the Mac, below) | 114 of 130 |
| Not built: no Mac form, or later (listed at the end) | 16 |

Built today (NVDAParity.swift, Windows style only; the Mac style is unchanged, checked key by key): repeat last spoken
(NVDA+X), pass next key (NVDA+F2), clipboard (NVDA+C, which had VoiceOver's VO-C), read the window (NVDA+B), status bar
(NVDA+Shift+End), shortcut key (NVDA+Control+Shift+Period), link destination (NVDA+K), review follows focus and caret
(NVDA+7, NVDA+6), flattened object moves (NVDA+Shift+Brackets), review cursor location (NVDA+Shift+Delete), the text
review cursor (NVDA+Period, Control+Period, Shift+Period, Control+Home and End, Control+Left and Right, Home and End,
Alt+Home and End, Shift+A, F9, F10, Shift+F9, Shift+F), table navigation (Control+Alt+arrows, Home, End, Page Up and
Down, and NVDA+Control+Alt+arrows for rows and columns; Control+Command on a Mac keyboard), mouse clicks and locks
(NVDA+Brackets, with Control), mouse and navigator (NVDA+Shift+M, N), refresh the page (NVDA+F5), back to the page
(NVDA+Control+Space), NVDA's settings keys open the TurnOver menu's section (NVDA+Control+G, V, A, U, K, M, O, B, D),
the synth settings ring (NVDA+Shift+Control+arrows, Page Up and Down: voice, rate, volume, punctuation), save and
revert the settings (NVDA+Control+C, R), the log (NVDA+F1), the app module (NVDA+Control+F1), reload plugins
(NVDA+Control+F3).

## Variations to decide

1. **Stop and pause.** NVDA: Control stops speech, Shift pauses it. TurnOver: Control pauses (and stops), Shift does
   nothing. Recommended: as NVDA in the Windows style (Control stops, Shift pauses).
2. **NVDA+Up and Down Arrow.** NVDA's laptop layout: the previous and next line in review. TurnOver: the current line
   and say all (NVDA's desktop layout, where NVDA+L and NVDA+A do those on a laptop). Recommended: the laptop meaning.
3. **NVDA+Left and Right Arrow.** NVDA's laptop layout: the previous and next character in review. TurnOver: the
   previous and next object, as Narrator (your choice, 7 Oct), so review by character has no key. Recommended: in
   text, NVDA's (review by character); elsewhere, yours (objects).
4. **NVDA+Shift+Z.** NVDA: sleep mode (NVDA silent in this app). TurnOver: repeat last spoken (now also on NVDA+X).
   Recommended: NVDA+Shift+Z sleep mode, which TurnOver can do as "VoiceOver reads this app" (Apps menu).
5. **NVDA+V.** NVDA: screen layout on or off in browse mode. TurnOver: hand over to VoiceOver. Recommended: NVDA's;
   handing over by Command Control Shift T (as item 2 in VOICEOVER-PARITY.md).
6. **NVDA+Control+S.** NVDA: the Select Synthesizer dialog. TurnOver: the current sentence. Recommended: NVDA's (the
   Speech section); NVDA has no "report sentence", so it leaves the Windows style.
7. **NVDA+Shift+D.** NVDA: audio ducking. TurnOver: describe image. Recommended: keep describe image there (ducking is
   a Windows audio feature).
8. **App commands on NVDA's keys.** Word: NVDA+M and Shift+M next and previous comment (NVDA: mouse tracking and mouse
   to navigator), NVDA+Page Up and Down pages (NVDA: review modes). Terminal: NVDA+Home and End the history (NVDA:
   start and end of the line in review). Music: NVDA+Shift+C (NVDA: set column headers). Claude: NVDA+Shift+R (NVDA:
   set row headers). Music, Podcasts, TV: NVDA+Shift+N what is playing (NVDA: navigator to mouse). Recommended: keep
   them in their apps (NVDA's app modules do the same), and move Word's comments to NVDA's own Word keys (NVDA+Alt+C
   reports the comment; Word's comments list is in the elements list, NVDA+F7).
9. **Alt+Up and Down Arrow** (NVDA in Word: previous and next sentence). On a Mac keyboard Alt is Command, and Command
   Up and Down go to the top and bottom. Recommended: the sentence in Word only, as NVDA.

## To build (build 23)

- NVDA+U progress bar output, NVDA's way: a beep whose pitch rises with the percentage as a progress bar moves (a
  download in the App Store, a copy in Finder), with the spoken percentage as the other setting. Asked for by Oliver on
  27 Oct 2026: "that's a good thing to have".

## Not built (no Mac form, or to decide)

- NVDA+M mouse tracking (TurnOver doesn't speak under the pointer as it moves), NVDA+Alt+T
  braille mode, NVDA+Control+T braille tether (TurnOver's display follows its own cursor already), NVDA+Alt+S sound
  split (a Windows audio feature), NVDA+Shift+F10 native selection mode (WebKit offers no such mode), NVDA+Page Up and
  Down review modes (TurnOver has object review only), NVDA+Shift+Page Up and Down page in review, Comma and Shift Comma
  (past the end or to the start of a list or table in browse mode), NVDA+Shift+C and R set table headers, NVDA+Control+
  Shift+F1 copy part of the log, Control+Alt+N start NVDA (Command Control T starts TurnOver).

## the decisions (12 Oct 2026, one by one)
1. Stop and pause: yes, as NVDA in the Windows style: Control alone stops, Shift alone pauses and resumes. The Mac
   style keeps VoiceOver's Control.
2. NVDA+Up and Down Arrow: yes, the laptop meaning (review previous and next line). Current line on NVDA+L, say all
   on NVDA+A; the desktop meanings with the keypad layout.
3. NVDA+Left and Right Arrow: yes: in text, review by character (as NVDA); elsewhere, the flattened object moves.

Rule (12 Oct): same key, same purpose; the method adapted to the Mac where NVDA's own would be worse (the
Mac's deeper tree of unnamed groups; no screen review), each adaptation written here and put to the maintainer.
4. NVDA+Shift+Z: yes, NVDA's sleep mode: TurnOver silent in that app, every key passed through, remembered per app
   until pressed again (no hand-over to VoiceOver). Repeat last spoken on NVDA+X.
5. NVDA+V: yes, screen layout on or off (virtualBuffers.screenLayout); handing over on Command Control Shift T, in the
   update notes.
6. NVDA+Control+S: yes, the TurnOver menu at Speech (the voice); report sentence leaves the Windows style, no Command
   Control key.
7. NVDA+Shift+D: yes for now: says "audio ducking isn't available on a Mac"; describe image on Command Control I in
   both styles (VO-Shift-L stays in the Mac style; Command Control D is macOS's dictionary). Ducking is to be looked into:
   it isn't confirmed impossible. Leads: Core Audio process taps (macOS 14.2+, CATapDescription, muted when tapped,
   replayed lower; asks for audio capture permission); lowering the output while TurnOver speaks and raising its own
   gain to match. Prove one with a probe before promising it.
8. App commands on NVDA keys: yes, kept in their apps (Terminal, Music, Claude, media apps; Word's pages), except
   Word's comments: NVDA+Alt+C (Caps Command C and Caps Option C) and the elements list; NVDA+M and Shift+M do NVDA's
   mouse commands in Word too.
9. Alt+Up and Down (Word): yes, in Word only in the Windows style, Command Up and Down move by sentence (Control Home
   and End still go to the top and bottom).

## The keypad (built 12 Oct, Keypad.swift)

NVDA's desktop layout on the keypad, every numpad command in NVDA's reference except the review modes (NVDA+keypad 7
and 1). Adapted: a Mac keypad has no Num Lock, so Clear, in its place, switches between NVDA's commands (the default,
as Num Lock off) and typing numbers; keypad 0 held is the NVDA key (NVDA's numpad Insert). Caps Lock Up and Down keep
the laptop meaning (decision 2).

## Audio ducking: the probe (12 Oct)

~/Library/Developer/TurnOver/tools/duckprobe (built, not yet run): a Core Audio process tap of every process but
itself, muted while tapped, played back through the output at a gain it chooses (full and 30 %, every 2 s, for 12 s),
then removed. macOS asks once for permission to record other apps' audio, so it runs with someone there to answer. If it works,
TurnOver can duck: the gain drops while TurnOver speaks. Unknowns: the permission's wording for testers, latency
added to other apps' sound, and AirPlay or Bluetooth outputs.
- Keypad default (12 Oct, on my recommendation: "we'll soon hear if it's a problem"): commands on in the
  Windows style; the first keypad key says once "Keypad commands, as NVDA with Num Lock off. Clear switches to
  numbers."; the choice is remembered.

Ducking built (12 Oct, Ducking.swift), off by default as in NVDA: NVDA+Shift+D cycles no ducking, while speaking,
always; the menu has it under Speech. Safety: set-up off the main thread, unmuted until TurnOver's
playback runs, unmute first on stop, nothing played back if muting fails. Proven by ear with duckprobe;
TurnOver's own version is untested until it is switched on.
