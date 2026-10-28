# Testing TurnOver

## Unit tests (every build)

`turnover-tests` (Sources/TurnOverTests) is a plain executable: no XCTest, so it runs with the command line tools alone.
build.sh runs it after compiling and refuses to install if a test fails (`TURNOVER_SKIP_TESTS=1 ./build.sh` to skip).

```bash
swift build -c release --scratch-path ~/Library/Developer/TurnOver/build --product turnover-tests && ~/Library/Developer/TurnOver/build/release/turnover-tests -v
```

`turnover-tests <word>` runs only the tests whose name contains the word. The files: PureTests.swift (functions
with no application behind them), FixtureTests.swift (objects and views against recorded windows, and the scale
tests on a generated 1,000-row window with call budgets), PolicyTests.swift (the decisions that can leave a blind
user with no reader: who leads, what the speech queue drops, the VoiceOver Activity's archive against a real export;
and every recorded fixture read within a budget), GamesTests.swift (the Steam helper's
line protocol), ControlChannelTests.swift (partial socket writes, slow readers, queued-output limits, concurrent-send deadlines,
disconnects and descriptor reuse),
PluginTests.swift (the parked plugin format, still tested so it does not rot), and
PluginArchiveTests.swift (real ZIPs: entry and expansion limits, misleading size fields, corrupt data, encryption,
outside-file sentinels for malicious paths and links, and cleanup). `turnover-tests archive:` runs the archive
checks without installing a plugin.

The control-channel tests use private socket pairs and package-internal connection setup; they do not connect to
the running reader or bypass its public peer-authentication path. Tiny socket buffers force partial writes and
backpressure. The write-buffer test also supplies interrupted, would-block, zero and fatal write results.

## Speech recovery (every build)

`turnover-tests 'speech recovery' -v` drives the production queue-watch state with synthetic time: repeated grace
deferrals, resumed heartbeats, stale completions, single recovery ownership and replacement retirement. The
replacement-attempt tests verify that deadline expiry and cancellation reject late builders and main callbacks.
Warning tests run silent system tools, including an explicitly ready child which ignores SIGTERM, to verify the
two-second production wait has a deadline and kills only the owned warning. A separate test backstop prevents a
broken wait from hanging the harness. These tests neither start an audio engine nor interrupt the running reader.

A live listening check remains required before release: normal speech, sleep/wake, and recovery after a simulated
player stall. Name macOS, the voice/output device, keyboard style and reader mode. Passing these tests does not
establish how a real CoreAudio stall or a device handover sounds.

## Privacy regressions (every build)

`turnover-tests privacy -v` exercises typed-key diagnostic masking, braille input and feedback redaction using
synthetic text. Braille tests replay ordinary and password fields, intercept every text/key post, and supply a
test translator; they never type into another app, open the user's logs or disable VoiceOver. The speech sink
checks the private flag on actual typing/deletion echo, rather than relying on empty history with speech off.
The Steam helper's `--self-test` checks its page/element diagnostic formatters too.

Feedback always redacts diagnostic logs, even when speech is included. Consented speech comes from the current
session's history; private typing is excluded there. This also prevents old unmarked braille echo in disk logs
from being exported as speech. Existing logs on disk are not rewritten or deleted by this fix.

Before releasing, check on a real braille display: contracted and uncontracted typing, late-space chords, word
and character echo, and dot-7 deletion of a pending cell in a disposable password field. Use synthetic text;
verify the cell is removed silently and ordinary echo still sounds right. Name the display, USB/Bluetooth,
macOS version and keyboard style. The automated tests do not establish driver delivery during Secure Input or
how speech sounds on hardware.

## Accessibility window search

`turnover-tests "AX window search"` exercises the production reading-order traversal and serial worker with fake
providers: forward/backward order, indexed row neighbours, delayed and cancelled matches, cycle/depth/work limits,
coalesced repeated keys, and completed results cancelled before main can publish them. No live app or reader is changed.
`turnover-tests "AX read scope"` uses replayed public sample elements to check nested/throw cleanup, thread confinement,
typed and legacy cancellation, nested profile action reads, and separate provider-operation/AX-query budgets.
Known transport failures and client backoff must produce incomplete search results; unsupported optional attributes
retain their existing fallbacks.
The deadline is cooperative: an AX call already in flight cannot be preempted, and retains the existing messaging
timeout. The large search stays off main; these tests do not establish live speech, focus-following or app coverage.
Landing on a result, speech presentation and focus-following still perform accessibility work on main; this change
bounds search collection rather than all object navigation or action presentation.

## Braille driver thread (every build)

`bash Tools/tests/braille-thread-test.sh` compiles the real Objective-C bridge with a fake driver which runs its
run loop while waiting. Explicit gates hold a poll, write, blank or unload; main must remain responsive, release
must stay pending, and repeated close requests must share one attempt. Successful release completes on main
only after unload returns YES. An unload NO reports failure and retains the display and driver without retrying.
The test also checks non-nesting, the latest pending frame, idle deallocation and no calls after unload. No real
display, permissions or private frameworks are needed. The test has a fifteen-second failure deadline, removes
its executable on exit, and runs from `build.sh` alongside the unit tests. This tests the additive asynchronous
bridge API; production callers still use the synchronous close while the hand-over policy in issue 160 is reviewed.

## App Store structural diagnostics (issue 166)

`turnover-probe appstore-ax` samples an already-running App Store without activating it, opening a page, performing
an action, changing an accessibility flag or toggling VoiceOver. It emits structural roles, standard action names,
counts, timings and typed query outcomes. It never emits titles, values, identifiers or custom action strings.
There is no labels option. The probe's own log is identified at startup; do not substitute an unrestricted tree dump.
The header distinguishes the VoiceOver enabled flag from process presence. App Store version/build and whether it
is frontmost are metadata; the reader's active state and mute lease are reported as unobserved, never inferred.
The probe reports its own `AXIsProcessTrusted()` result without requesting a permission prompt. An actual
apiDisabled reply stops further queries and reports accessibilityDenied, rather than an empty or completed tree.

Discovery, retained-reference reads and freshly reacquired references share 96 query/configuration admissions,
12 inspected nodes, depth 6, eight elements per array prefix and a 1.5-second cooperative deadline. Depth-first
discovery follows natural container order and skips children of sidebar outlines and terminal controls; skipped
and unvisited branches are reported. Fresh-reference path replay asks for one known child index without recounting
the full array. Each exact
reference gets a 50 ms client messaging timeout; an equal but newly obtained reference needs its own timeout.
The single 250 ms sample gap spends the same deadline. The first provider cannotComplete, apiDisabled or client deferral stops
further queries. Unsupported and noValue remain provider replies, not proof of an empty application tree.

`--direct` explicitly bypasses only this probe process's AXHealth rest, still recording its actual outcome and
spending the same limits. It is diagnostic only. The probe cannot observe the running reader's AXHealth state;
`AppStoreFlatAdapter.diagnose` records typed, structural results in that process, respecting its rest. A shared
CFEqual reference or an unchanged child-index path does not prove stable item identity in a recycled collection.
The in-process sample runs at most once per two seconds, with five query/configuration admissions and a 100 ms
cooperative allowance; it never performs a direct diagnostic bypass. Its sampled child gets its own client timeout.

The deadline cannot preempt an individual accessibility API call, and Apple offers no paginated name-enumeration
API. Name enumeration is one timed call; only its first 64 names are examined directly from the CF array. Names
longer than 128 UTF-16 units are counted and omitted before bridging to Swift. Redacted output records the returned
count. Every summary states that the complete provider tree
has not been established. Run a live probe under a separate process deadline as well; no install is required.
`turnover-tests 'AX diagnostics' -v` checks shared budgets, deadlines and structural output with synthetic data.

## Recorded windows (fixtures)

A fixture is a window's accessibility tree as JSON (Tests/Fixtures/*.json): every element's attributes, the
elements it refers to, the root's ancestors up to the application, and which element had the focus. Record one
from a running application, with the window you want in front:

```bash
~/Library/Developer/TurnOver/build/release/turnover-coretest --record com.apple.TextEdit Tests/Fixtures/textedit-guide.json --limit 3000

The worked example to copy is the Finder test in Sources/TurnOverTests/FixtureTests.swift: /Applications in list
view was recorded as Tests/Fixtures/finder-applications.json (Apple's own content, nothing private), and the test
says what TurnOver should say of it (the view's name, the selected row and its position). Record a window of the
app you are working on the same way, write what you expect, and the test runs on every pull request.
```

In a test, `AXReplay.load(fixture)` serves it: `AXReplay.root`, `AXReplay.focus` and `AXReplay.application` are
`AXUIElement`s that answer like the real ones, and so does every element reached from them, so `ObjectFactory.make`,
`Speech.objectPropertiesSpeech`, the views and the browse mode buffer can be exercised without the application.
Actions and set attributes are recorded (`AXReplay.actions`, `AXReplay.sets`); text questions (string for range, line
for index) are answered from the recorded value.

How it works: Sources/AXReplayShim is a C library that interposes the HIServices functions (dyld's `__interpose`
section); elements whose pid is 900000 or more are answered from the recording, anything else goes to the real
function. dyld honours interposing only in a library loaded at launch, so turnover-tests starts itself again with
`DYLD_INSERT_LIBRARIES` pointing at libAXReplayShim.dylib beside it, and finds the shim's install function by name.

Keep fixtures free of private content: record Apple's own content (Music's Browse page, the App Store, the beta
guide in TextEdit), not mail, chats or documents.

## The key reference in the guides

Guides/09 to 11 (every key, one page per keyboard style) are generated from the command tables, not written:

```bash
~/Library/Developer/TurnOver/build/release/turnover-coretest --keys-reference Guides
```

Run it after any key or style-table change, then `python3 make-guides.py --text "Resources/TurnOver Guide.txt"`, and
commit the result. Keys that belong to a document object (Word's, a web page's) aren't in it; they are described in
Guides/03 and 04.

## Driving the real thing

> The key driver, the scenario files (testing/) and the regression pass described below are the maintainer's and
> aren't in the public repository yet: they drive a real Mac and assume one person's setup. The unit tests and
> fixtures above are complete.

The key driver and probes run from ~/Library/Developer/TurnOver/tools (sources: Tools/drivers; t.sh, bt.sh, axshape and the rest); notes from
each day's stress test are in testing/. Browsers are never driven: checklists instead (testing/chrome-signoff-checklist.md).

## The regression pass (before every release)

`testing/scenarios/regression/run.sh` runs every part, or the parts named (`run.sh core layer`). Since 17 Oct 2026 the
parts that matter are the seventeen apps (core, day1, day2, days45), decisions, layer and keys; plugins, the Windows
style and the keypad are parked and their parts are kept only so they still run. Its
live copy is `~/Library/Developer/TurnOver/scenarios/regression/run.sh`; the tools it drives are built into
`~/Library/Developer/TurnOver/tools` from `Tools/drivers`.

Preconditions: the build under test installed as /Applications/TurnOver.app; its welcome closed (the runner refuses
otherwise); the Mac idle for five minutes at the start (then 90 s before each part); the display awake; VoiceOver on
with the Activity in (coexist is the product). The runner turns the `logSpeech` default on for the run (the
scenarios read what was said from the log, which keeps lengths otherwise) and puts it back, quits every app it
opened, and restores the front app on exit, however it ends.

What a stop means (scenario.py's exit codes): 3, the owner is at the keyboard (an idle reset not explained by the
test's own keys or TurnOver's logged hand-over); 4, the app under test is not in front (a cold start over 16 s, a
dialog); 5, a style switch failed; 6, a key was passed through. The log names the part; run that part again.

Every miss is read in TurnOver's log before it is called a regression: most are the test or the app. The known ones
(Xcode's and Script Editor's last row, Excel's cold-start first key) are listed in the day's testing notes.

## Scenarios (the daily pass as files)

`testing/scenarios/*.txt` (live copy `~/Library/Developer/TurnOver/scenarios`) describe a run of keys in an app and what TurnOver must say or which
script must run; `tools/scenario.py <file>` runs one with the key driver and reports each expectation (spoken words
masked). The format is at the top of scenario.py. They refuse to run while the user is at the keyboard.

`scenarios/run-all.sh mac` runs every scenario (the smoke pass before a build goes out; `windows` is the parked
style); `tools/privacy-check.sh <feedback.zip> <words>` looks for private words in a feedback report.

## Keyboard readiness and activation

`KeyboardSessionTests` exercises the production lifecycle and main-actor admission without opening real taps or
changing either reader. It covers denied setup, cancellation before run-loop publication, rapid restart waiting for
teardown, stale/duplicate callbacks, failed re-enable, VoiceOver taking over during pending setup with the swap off,
loss of input while core setup is in progress, and bounded ownership of automatic permission-recovery notifications
without suppressing later manual choices. These are state/ownership checks, not real event-delivery tests.

Live checks still need Accessibility denied/granted, Input Monitoring denied/granted, Caps Lock and Control+Option,
swap on/off, Coexist on/off, app changes, rapid toggles and a real failed/re-enabled tap. A valid enabled tap plus
granted input permission does not prove physical HID/Caps Lock delivery (including Karabiner). Non-Coexist and game
handover can still turn VoiceOver off before this activation acknowledgement; issue161 tracks that preflight.

## Accessibility query outcomes

`AXQueryResultTests` checks actual wrapper reads through the replay shim, bounded array slices, enumeration and
embedded batch errors. Synthetic elapsed times exercise the production health admission without delaying an app:
returned AX errors, timeout versus slow-response backoff, skipped provider calls, explicit diagnostic bypass and
legacy optional/error compatibility. A CFNull batch slot has no known AX error; a missing slot is a client decoding
failure. Neither is reported as an invented provider noValue. No live app is read by these tests.

Typed results time and classify a single query; they do not impose a walk deadline or interrupt an in-flight call.
Diagnostic callers must provide their own work limits. Health state belongs to the calling process: a fresh probe
cannot establish whether the separately running reader deferred a read. App Store probe work is tracked in #166.

## Public navigation children prototype (issue 174)

`AXNavigationChildrenTests` compares ordinary and semantic children, provider order, deduplication, authoritative
empty, unsupported count/slice value fallback, transport/backoff, malformed data, cycles and budget cancellation.
`AppStoreNavigationModelTests` drives the actual default builder/model owner with semantic-only public fixtures;
it verifies committed labels/order and refusal to replace a useful page after a cycle or final metadata failure.

The builder allows 2 s for page/sidebar/metadata, 6 s for more/carousel/resolve and 30 s for End's deliberate shelf
loading. End remains long, cancellable worker work. Navigation queries/decoding have finite caps; legacy role,
identity and action helpers outside the charged seam retain their existing limits and cooperative checks. This
prototype does not establish universal responsiveness, VoiceOver-off parity, purchase access or safe live actions.
