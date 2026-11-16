# Zoom

- Bundle id: us.zoom.xos
- Support: Partial
- Effort: Module
- Being worked on: Jakob Rosin, [#318](https://github.com/TurnOver-For-Mac/turnover/issues/318)
- Checked: 16 November 2026; Zoom Workplace 7.1.9 (88375), macOS 27.2.1, VoiceOver off, Windows and Mac keyboard styles; in a meeting with other people and in a test meeting alone. Heard by Jakob Rosin in an installed build of this part alone: mute, video, raised hand, reactions and who is speaking.

## Findings

The module adds:

- Command Shift A and Command Shift V say the new state: muted, unmuted, video on, video off. Zoom itself announced nothing.
- Option Y says "hand raised" or "hand lowered". Option Command 4 to 9 say the reaction sent. Zoom itself said nothing for either.
- Command Shift 2, Zoom's own key for the active speaker's name, says who is speaking in the meeting window. Zoom itself said nothing. Command 2, Zoom's key for another view, is left alone.

Zoom's own screen-reader alerts do not arrive: its program file suggests it makes them only while VoiceOver is on (see the experiment note).

Not assessed:

- Zoom in a language other than English.

## Evidence

- [App implementation](ZoomAppModule.swift) and its [wording](ZoomWords.swift).
- [Hand test](Tests/README.md).
- [13 November 2026 meeting probe](Experiments/2026-11-13-meeting-window.md).
- [Dated observations and limits](Experiments/2026-10-historical-checks.md).
