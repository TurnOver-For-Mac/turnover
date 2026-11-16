# Zoom meeting window: what is reachable and what is announced

- Being worked on: Jakob Rosin
- Contributors and tools: Jakob Rosin; Claude Code (Claude Fable 5.2) with turnover-plugin snapshot, menus and try.
- Date and setup: 13 November 2026. Zoom Workplace 7.1.9 (88375), macOS 27.2.1, TurnOver Developer, Mac keys, VoiceOver off. First a running meeting with four participants, joined as a participant. Then a test meeting, alone as host.
- Review point: after the first installed-build trial by ear.
- Status: Observed; module written from it. What was heard in an installed build is in STATUS.md.

## Question

Why do Zoom's own keys for mute, video, the hand, reactions and who is speaking say nothing?

## Method

Snapshots of the window before and after each key, `turnover-plugin try` for the keys, and the log for each. In the running meeting the hand was not raised, nothing was typed in the chat and the meeting was not left. Names are left out of this note.

## Result

Zoom's own keys:

- Command Shift A changed the state both times (the own tile's description and the Meeting menu's item changed) and the log shows the key and no notification of any kind from Zoom.
- The Meeting menu's item with Command Shift A is "Unmute audio" while muted and "Mute audio" while unmuted; the one with Command Shift V was "Start video" with the camera off.
- Command 2 from the meeting window said nothing about a speaker; focus arrived in the Zoom Workplace window on the second of seven navigation tabs. Zoom's next-window key returned to the meeting.
- Correction from Jakob Rosin the same day: on the Mac, Zoom's key for the active speaker's name is Command Shift 2, and Command 2 opens another view; both are Zoom's own. Command Shift 2 said nothing under TurnOver (his report).
- A tile's description is the name, the audio state, the video state, and ", active speaker" on the one speaking.
- Option Y, in the test meeting: logged as a typed key that passed through. A window titled "Reactions", of unknown subrole, appeared with one child, a "Lower hand" button. The own tile gained an element "(name) sends Raise hand". A second Option Y removed both. Nothing was said either time.
- Option Command 5, in the test meeting: the same "Reactions" window with one child, an image described by the emoji; the tile gained "(name) sends thumbs_up_yellow". Nothing was said.
- Command Shift Y opened the reactions panel as its own window ("Menu window, dialog, Send with effect, Reactions"). Tab read six emoji buttons with their keys, More reactions, and Yes, No, Slow down and Speed up as "Not checked" buttons. The panel closes when Zoom leaves the front.

Possible explanation, not established by a running trace: Zoom makes its screen-reader alerts only while VoiceOver is on. Read from the program file with `strings`: `Prism.framework` holds the names `speakStringIfVoiceOverOn:`, `isVoiceOverRunning`, `voiceOverEnabled`, `NSAccessibilityVoiceOverStatusChanged` and `NSSpeechSynthesizer`. That points at the system's public VoiceOver state and Zoom's own synthesiser, not at a private VoiceOver interface. Zoom's own Command Shift 2 under TurnOver produced no notification in the log.

Not tested: Zoom in a language other than English.

## Evidence

The module's opening comment and tests (`Sources/TurnOverTests/ZoomModuleTests.swift`, with made-up names). No recording of the meeting is kept: it held other people's names and captions.

## What would justify another attempt

A Zoom version which announces state changes without VoiceOver.

## Decision

Continue: a module, sent in parts, one mechanism each.
