# TextEdit File menu navigation

- Date: 29 October 2026
- Being worked on: Codex, [issue 194](https://github.com/TurnOver-For-Mac/turnover/issues/194)
- Setup: TextEdit 1.21 (419), macOS 27.2 (26B118), TurnOver local trial based on 280d7bf, Mac keyboard style, Mac VoiceOver off.
- Status: investigation; a proposed recovery is not yet installed or user-tested.

## Question

Why can the reader move between TextEdit's menu-bar titles but not down into File's items?

## Observations

Oliver confirmed failure with both plain Down and Control–Option–Down. In the installed reader's log, pressing File's title returns success. Subsequent Down keys route to the underlying list or document. An AXMenu focus report sometimes arrives, but that alone does not establish the reader's tracked open-menu state. Edit, in the same observed session, receives the normal opening notification and its Down keys use menu navigation.

The initial read-only probe confirms both File and Edit expose AXMenu children. When closed, their size is zero and selected-child count is zero. Native accessibility permission is already granted. A sandboxed sample could not enumerate TextEdit; the authorised unsandboxed sample did, so the first result was not evidence the app was closed.

## Proposed recovery

Recognise a visibly open, native, correctly owned AXMenu focus report before duplicate-focus filtering, using the same deduplicated bookkeeping as the normal opening notification. Exclude web menus, detached elements, background apps and zero-sized menus. This belongs in shared menu handling, not a duplicate TextEdit-specific reader.

## Diagnostic scope

The textedit-menu gate in the separate turnover-probe executable samples bounded menu metadata. Default mode is read-only. Explicit --open-file and --open-edit modes require TextEdit already frontmost, press only that top-level title, then attempt cancellation and report whether it closed. No document text, menu-item labels, recent-file names, app activation or injected keys are used.

The gate uses 50 ms timeouts on retained exact references, capped calls and references, a two-second cooperative deadline, and an external process timeout. These limits are measurement boundaries, not a guarantee about arbitrary provider behaviour.

## Evidence

Only structural metadata and a sanitised summary of relevant log events belong in Evidence. Raw speech logs and document names are not copied.

## Decision

Confirm native File/Edit opening behaviour, run the focused regressions and full build checks, install with a verified rollback, then obtain Oliver's live menu trial. No code push or pull request precedes that trial.

## Follow-up on 30 October

The signed probe compared File and Edit in TextEdit 1.21 (419), macOS 27.2 (26B118), with Mac VoiceOver off. Both AXPress calls succeeded and their menu children acquired positive geometry with native menu-bar ancestry and the correct application owner. The app's AXFocusedUIElement remained AXTextArea after both presses. File's first post-press AXRole query returned cannotComplete after 53.9 ms with the probe's 50 ms timeout, followed by a successful size read after 14.1 ms. Edit's first role read completed and positive geometry was available about 44 ms after the press.

File's AXCancel succeeded but immediate size readback still showed it open. A subsequent read-only sample confirmed File and Edit closed. Edit's cancellation readback was immediately closed. The probe now permits three short readbacks within its existing cleanup allowance. No command was selected and no document text was read or changed. The harness stayed action-free when Codex was foreground; the prepared TextEdit window was then explicitly brought forward for this authorised comparison.

This supports validating a native menu candidate before pressing its title and confirming positive size immediately afterwards. A focus-only recovery would miss the demonstrated document-focus state. The candidate also routes exact Mac-style reader arrows through native menu navigation after opening, preserving other modifiers, Windows commands and web-menu routes. A real installed trial is still required.

## Current gate and baseline

The initial suite failure was a replay-node identity collision with another test's cached focus. The tests now use an isolated ID range while retaining the focus assertion. A later routing test had incorrectly assumed the existing Windows command; it now compares the actual closed-menu baseline.

The complete ./build.sh --no-install gate passed on 30 October: 444 tests, zero failures, braille-thread checks and all three helper self-tests. This is the candidate on the local integration branch based on 7cf3498, not a validation of a patch applied to public main.

Oliver changed the priority to reviewing yesterday's public 22.4 work and planning migration. No TextEdit candidate was installed or pushed. Public main is now 0ed2ab4 and deliberately excludes the Safari extension still carried in this older integration branch. Forward-port only the reviewed TextEdit change onto current public source and repeat the full check/install/user-trial loop before publication. The installed 22.4 bundle remains untouched; its verified rollback is /private/tmp/turnover-textedit-22.4-rollback/TurnOver.app (temporary local path, not portable evidence).

New structural evidence: [File opening](Evidence/open-file-metadata.txt), [File later confirmed closed](Evidence/after-file-closed-metadata.txt), [Edit opening and closure](Evidence/open-edit-metadata.txt).

## Migration note — 30 October 2026

The preceding results describe the separate TextEdit candidate and its historical setup. They are preserved as investigation history, not results for the migration build. Candidate commit `1af6d40` remains separate from migration baseline `e0a6b74`; the 444-test result belongs to that older candidate. No TextEdit production patch is imported here.

The installed reader subsequently became the unrelated wake-fix build 22.5, which Oliver reports works. Any earlier mention of an untouched 22.4 installation or a temporary rollback path is historical. TextEdit's candidate still requires a forward-port, full checks, a verified current rollback and both Down variants in an installed trial. Migration does not count as that trial.
