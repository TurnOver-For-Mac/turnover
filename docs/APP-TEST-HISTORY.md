# App evidence and support grades

App records cover generic reading, shared implementations, recipes, plugins and dedicated modules. Each record tells
contributors which tasks work, where help is needed and what evidence supports the grade.

## Grading a recorded task

Use the best available evidence for the named scope. Works means those tasks worked in the recorded setup; Partial
means useful tasks have known gaps; Blocked means the task has no usable tested route. Use Not assessed when the
evidence is insufficient to establish a task result. Blocked does not prove that every possible route is impossible.

Checked carries the actual test date and build, including older results. A new build does not automatically erase a
grade. Update it when a further check or regression changes what is known. State missing setup details as unknown.
Do not extrapolate a welcome-page check or a few successful keys to the whole app.

## Evidence types

- Source inventory or a format test establishes that an implementation exists.
- A snapshot or bounded probe establishes which structure was exposed in the sample.
- A driver interaction establishes the named commands and recorded responses, with its keyboard style and scope.
- A user trial records what the user heard or completed.
- A planned or unfinished check has no completed task result.

A driver pass can support a grade for the task it exercises; it does not establish how every utterance sounded.
A corrected test expectation can explain a failure without fixing app code. Ulysses' 12 October rerun, for example,
counted a text boundary sound that the earlier runner overlooked. Keep that distinction in the record.

## Dates, source records and privacy

Dated Experiments summaries record setup, method, result and limits. STATUS.md summarizes the strongest relevant
results and links to those records. Preserve conflicting or unsuccessful observations when they explain a limit.

Earlier source records include `testing/APP-TEST-LIST.md`, the 10–12 October notes, `testing/2026-10-14-parts-sweep.md`
and `Application library.txt` dated 29 October. These local records contain historical environment and personal-session
context. Summarize the relevant result; do not copy them wholesale into the source tree.

A fixture records a sampled window. Link a named test when claiming that the harness exercises it. Use public sample
content, excluding personal text, titles, accounts, connected servers and credentials from fixtures and summaries.

Verify bundle identifiers from app metadata, module registration or recording metadata. Otherwise use Not recorded.
A format-test example or app name is not a reliable identifier source.

## 30 October 2026 regression run

The 32 dated app records summarize a developer build of TurnOver 22.4 source `0ed2ab4`, tested with Mac and Windows
keyboard styles on macOS. These are keyboard styles, not different operating systems. App/macOS versions and
VoiceOver state were not recorded per case. Each record names the actions and assertions, their result and limits.

The [published scenarios](../testing/scenarios/README.md) drive installed apps and check TurnOver's log. They are
separate from the unit-test executable. Follow that README's setup and privacy instructions before running them;
they operate the Mac's real apps. The scripts were cleaned for publication in PR211 after the run; the dated results
are historical evidence, not a claim that the published copies have since been rerun.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech
assertion checks emitted text, not a listening review or exact wording. Some scenarios also accept a boundary sound.
The local release handoff reports 327 passed and 23 missed across the suite; these totals are not any one app's score.

The original `release-logs/22.4-regression-dev.log` and release handoff are retained locally on the test Mac because
logs may hold personal screen content. They are not repository files or prerequisites for understanding the summaries.
The tables' local log line numbers preserve a route back to those originals for the maintainer. Filenames such as
`day-ulysses.txt` are the runner's labels; each record links to the corresponding published scenario.

## Local application-library notes

The 29 October `Application library.txt` is a private working note retained locally, not a repository document.
The linked app records contain its relevant setup, method, measured result and remaining limits in words. They
separate structural provider probes, automated checks and Oliver's observations; none implies an unrecorded live
trial. The source note identifies installed local build `280d7bf` at that checkpoint, but does not identify every
earlier user trial's binary separately. Personal content and session details remain in the local source.

## Keeping the library complete

Compare module registration, recipes, generic/shared-code adaptations, fixtures and earlier test records. Give each
app its own record even when it shares implementation, such as iTerm2 with Terminal, Messages/WhatsApp/Discord with
Chat, and Notes with Panes. A record needs no empty wrapper module.

Google Docs, Sheets, Slides and Drive are browser-hosted tasks. The 10 October synthetic page used Docs/Sheets/Drive
patterns; it was not a live-site task check. Keep that evidence distinct from checks of the actual websites and
record their coverage with the browser used.

For a new check, use a public or disposable sample. Record app/macOS versions, reader build, keyboard style, reader
mode and VoiceOver state. Include incomplete or failed paths, and change the grade only within the checked scope.
