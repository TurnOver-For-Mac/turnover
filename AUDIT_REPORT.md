# TurnOver technical audit

Date: 21 October 2026
Branch: `codex-audit`
Scope: the tracked repository at audit start, including documentation, Swift/Objective-C/C/Python/shell sources,
helpers, resources, fixtures, plugins, and tests.

## Executive summary

The repository is a substantial macOS screen-reader implementation: 449 tracked files, including 266 Swift files,
45,815 lines under `Sources/`, 1,455 helper lines, and 2,582 tool lines. The highest-risk paths are the keyboard event
tap and Caps Lock/HID layer, AX calls and virtual-buffer construction, speech rendering and device changes, VoiceOver
audio handover, watchdog/restart behavior, plugin/control-channel trust, and build/install signing.

Two verified defects were fixed:

1. Control-channel writes assumed one Unix-socket `write()` transferred a complete JSON line. Short writes could
   truncate replies or requests. All control-channel writes now use a retrying `writeAll` loop, including server
   replies, broadcasts, one-shot clients, and persistent clients. A 256 KiB pipe regression test covers partial writes.
2. `build.sh` suppressed the `swift build` exit status and did not clear every release product before rebuilding. A
   failed or partial build could therefore proceed with stale tool/test artifacts. The script now preserves the build
   status and clears all release products used by the build.

No installed application was replaced or launched. No macOS Accessibility, Input Monitoring, Screen/System Audio
Recording, TCC, or other security setting was changed. No upstream repository was modified and nothing was pushed.

## Repository map and contracts read

Read in full: `README.md`, `CONTRIBUTING.md`, `ARCHITECTURE.md`, `TESTING.md`, `PATTERNS.md`, `PLUGIN-GUIDE.md`,
`NOTICE.md`, `PUBLIC-ROADMAP.md`, `CHANGELOG.md`, all `Guides/*.md`, all active `docs/*.md`, the three archived design
notes, helper READMEs, and the plugin schemas/resources.

The architecture is divided into:

- `TurnOverCore`: object/text model, focus/events, speech policy, browse mode, app modules, recipes, plugins, settings,
  Braille, screen recognition, and VoiceOver/NVDA parity.
- `TurnOver`: macOS event tap/HID watcher, lead switching, VoiceOver handover, watchdog, menus, lifecycle, updater,
  installer/uninstaller, and status item.
- `TurnOverAX`, `TurnOverSpeech`, `TurnOverBraille`, `TurnOverControl`: AX safety/timing, audio rendering, Apple
  Braille integration, and the signed local control channel.
- `TurnOverKey`, `TurnOverSettings`, `TurnOverPlugin`, `TurnOverProbe`, `TurnOverCoreTest`: helper apps, settings,
  plugin tooling, diagnostics, and live/fixture tooling.
- `TurnOverTests`, `AXFixtures`, `AXReplayShim`, `PluginTestKit`: executable tests and recorded AX-tree replay.
- `Helpers/`: Steam speech, trackpad gestures, and VoiceOver quiet process helpers.

## Findings

### A-01 — control socket short writes — fixed, verified

Files: `Sources/TurnOverControl/ControlChannel.swift:46-64, 207-218, 216-222, 240, 298`.
Severity: Medium.
Status: Verified in code and regression-tested.

The channel is newline-delimited JSON, but server and client paths compared a single `write()` result with the full
buffer length or ignored the result. Blocking stream sockets may legally write fewer bytes. The peer could receive an
incomplete JSON line and wait indefinitely or discard a settings/plugin response. `ControlChannel.writeAll` now loops,
retrying `EINTR`, and every control write uses it. The same change also closes a file descriptor when an overlong socket
path is rejected by `ControlServer.start`.

### A-02 — build failure could be masked and stale products reused — fixed, verified

Files: `build.sh:49-63`.
Severity: Medium.
Status: Verified in code; the corrected full build completed successfully.

The old `swift build ... | grep ... || true` discarded the compiler's exit code. Only the main reader, key helper, and
core library were removed before rebuilding; a failed build could leave old settings/plugin/test/core-test products in
the release directory. The script now records `PIPESTATUS[0]`, exits on a compiler failure, and clears all release
products it later packages or runs.

### A-03 — concurrent speech callback captures — unresolved, suspected

File: `Sources/TurnOverSpeech/SpeechPlayer.swift:259`.
Severity: Medium.
Status: Suspected; compiler warning, not reproduced as a crash.

Swift 6 reports a concurrent capture of `self` in the device-refresh callback before dispatching to the speech queue.
The class is intentionally `@unchecked Sendable`, and this path coordinates engine/device state across callback and
serial-queue contexts. It deserves a dedicated ownership audit and a test that changes the default output device while
speech is active. No change was made because altering the queue/device lifecycle without hardware coverage could worsen
speech reliability.

### A-04 — `DisclaimedSpawn` actor-isolation warning — unresolved, suspected

Files: `Sources/TurnOverCore/DisclaimedSpawn.swift:21`, `Sources/TurnOverCore/VoiceOverCommands.swift:66`.
Severity: Medium.
Status: Suspected; compiler warning, not reproduced as a runtime failure.

The helper-spawn API is inferred as main-actor isolated, but a nonisolated command path calls it synchronously. This is
especially sensitive because the spawn is used to keep helper processes from inheriting screen-reader permissions. The
current compiler emits a Swift 6 actor-isolation warning. The API should be explicitly marked with its intended
isolation (or moved to a clearly owned actor) and tested for both permission-disclaim behavior and responsiveness.

### A-05 — plugin archive extraction has no uncompressed-size cap — unresolved, suspected

File: `Sources/TurnOverCore/PluginLibrary.swift:231-268`.
Severity: Medium.
Status: Suspected security/availability issue.

The signed index caps the downloaded ZIP's compressed byte count and validates its SHA-256, then extracts it with
`ditto`. There is no explicit cap on the expanded size or file count before extraction. A trusted-index compromise or
maliciously packaged signed entry could cause excessive disk use or extraction work before the post-extraction checks.
The signature and policy checks substantially reduce attacker reach, so this is recorded for a focused follow-up rather
than changed in this audit.

### A-06 — VoiceOver helper output assumes one read equals one line — unresolved, suspected

File: `Sources/TurnOver/VoiceOverTap.swift:72-76`.
Severity: Low/Medium.
Status: Suspected; no live VoiceOver audio test was run.

The readability handler converts one `availableData` chunk to a trimmed string and compares it with a complete response
such as `on`. Pipe reads can combine multiple newline-delimited responses or split one response. A combined chunk can be
ignored, leaving `said` and retry state out of sync. The helper protocol should use a persistent line buffer, with a
fixture test for split/coalesced responses.

### A-07 — slow virtual-buffer timing remains an architectural risk — known upstream context

Files: `Sources/TurnOverCore/WebBuffer.swift:98-105` and browse-mode callers.
Severity: Medium.
Status: Suspected/known design risk, not newly fixed.

Buffer construction is bounded to two seconds on the main actor because AX tree reads are currently coupled to the
object model. This avoids an unbounded freeze but can still delay key resolution and produce a partial page. Upstream's
open issues #1 (“Keys pile up while a slow page's buffer is built, then run all at once”) and #4 (“Browse mode: timing of
keys in the virtual buffer”) directly cover this risk. The audit confirms the relevant deadline and partial-buffer
contract but does not claim an independent fix.

## Areas reviewed without a verified new defect

- VoiceOver coexistence: lead policy, secure-input/password handling, audio-tap lease, emergency watchdog handback,
  VoiceOver restart detection, and shutdown ordering were traced. The helper is isolated and has a self-test; live audio
  handover was not exercised because that would require changing runtime reader state.
- Keyboard interception: the event tap runs off-main; decisions have a bounded wait and late-answer replay; marker
  events, bypass mode, Caps Lock state, remapping, direct-app routing, and shutdown ordering were inspected. No new
  reproducible defect was established.
- Speech: cancellation/generation handling, AVAudioEngine reconfiguration, output-device tracking, silent-voice
  fallback, tones, ducking, and privacy history were inspected. The compiler warning in A-03 remains.
- AX/accessibility performance: AX calls are timed, unresponsive applications are rested, slow-drip accounting is
  tested, tree walks are bounded, and fixture call budgets pass.
- Braille, screen recognition, app switching, security prompts, recipes, plugin policy/signatures, feedback redaction,
  and startup/shutdown were inspected against their documentation and fixtures. Live-device behavior remains outside
  what can be proven by repository tests alone.

## Upstream consultation

The upstream issue and pull-request pages were consulted on 21 October 2026. At that time the upstream repository listed
four open issues and one open pull request. Relevant issue titles were:

- #1 — keys pile up while a slow page's buffer is built, then run all at once;
- #2 — app-specific exceptions living in shared code;
- #3 — reader state is hard to isolate in tests;
- #4 — browse-mode timing of keys in the virtual buffer.

The open PR was “Add agent guidance documentation for repository” (#5). These were used to avoid restating the known
browse-mode and architecture work as new fixes.

## Changes and commits

The audit changes are intended as two logical commits:

1. `Control channel: handle short socket writes` — implementation plus `controlChannelTests` regression coverage.
2. `Build: fail closed on compiler errors` — stale-product cleanup and build-status propagation.

The audit report is kept in a separate documentation commit so the implementation commits remain easy to review.

## Test results

- Native environment: macOS 27.2, Xcode 27.0, Swift 6.4, arm64.
- `python3 -m unittest discover -s Tools -p 'test_*.py' -v`: 16 passed, 0 failed.
- `TURNOVER_BUILD=/private/tmp/turnover-audit-build ./build.sh --no-install`: completed; native build passed,
  `turnover-tests` reported 107 passed, 0 failed, and Steam/trackpad/VoiceOver-quiet helper self-tests passed.
- Focused rebuilt test: `control channel completes a large socket write`: 1 passed, 0 failed.
- Rebuilt full native tests outside the sandbox: 107 passed, 0 failed; the existing real VoiceOver export test reports
  skipped because `TURNOVER_VOPREFS` is unset.
- A direct non-elevated test invocation produced one environment failure in the existing macOS spell-check test because
  the sandbox denied the `mul-xpc` spell service. The elevated rerun passed; this is recorded rather than treated as a
  repository regression.
- No installed app, live VoiceOver session, Accessibility/Input Monitoring grant, security prompt, Braille display,
  external audio device, or real third-party app was modified or exercised.

## Remaining concerns

The suspected items A-03 through A-07 should be follow-up work, especially a line-buffered VoiceOver helper protocol,
expanded-size ZIP limits, and concurrency tests around audio-device changes and disclaimed helper spawning. The upstream
browse-mode timing issues remain the largest user-visible architectural risk.
