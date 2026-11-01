# Sleep and wake restoration follow-up

30 October 2026. Codex implementation and review for Oliver. Tracking: [issue 204](https://github.com/TurnOver-For-Mac/turnover/issues/204), following [PR 197](https://github.com/TurnOver-For-Mac/turnover/pull/197).

## Scope

Keep VoiceOver available while the Mac is still locked, secure input is active or no ordinary app is ready. Retain ownership of VoiceOver that TurnOver enabled for the lock until restoration is observed to succeed. Retry failed restoration without overlapping handovers, and cancel stale work after another lock or a deliberate reader choice. VoiceOver already on before sleep is the user's reader and is not claimed.

## Baseline and earlier evidence

Public source 0ed2ab4, build 22.4, macOS 27.2 (26B118). The 29 October log from the previous fix records two successful returns to TurnOver after unlock. Code review found that the ten-second foreground wait could expire into an unguarded restore, and that restoration intent was cleared before asynchronous handover could fail. Those edge cases were identified by code review, not claimed as reproduced live failures.

The TextEdit candidate remains on its separate branch. No folder migration or Safari extension changes are part of this fix. Private release scripts in this checkout are preserved.

## Checks

Regression scenarios use the production restoration state with a supplied monotonic clock. They cover foreground delays beyond the old deadline, secure input and missing input permission, failed settling and retry spacing, retry exhaustion, another lock, user reader choices, delayed VoiceOver startup without spending retries, a new lock before a previous startup completes, and observed VoiceOver-off success. Twelve named regression cases exercise these transitions. No tests sleep or toggle an actual reader.

The final `./build.sh --no-install` gate passed: 418 tests, 0 failures, including all 12 wake regressions. Braille thread tests and the steam-speech, trackpad-gestures and voiceover-quiet self-tests passed. The final native integration review found no remaining blocker. The subsequent full `./build.sh` install loop also passed 418 tests and all helper checks. Build 22.5 is installed and running from `/Applications/TurnOver.app`. Deep strict signature verification passed; executable and core-library hashes match the newly built bundle. The startup log records Accessibility trusted, VoiceOver off, swap off and the keyboard tap active. These are startup checks, not a live sleep/wake result. The local candidate is labelled 22.5, with no public release implied. Passing these state-transition tests alone does not establish native wake notification ordering or speech behaviour.

## Review limits

The native notification/timer integration was independently reviewed. Any off request now captures its lock cycle and rechecks current lock state before delayed actions. The bounded wake watch restarts on later app activation or an owned VoiceOver-on notification. An already-issued macOS application launch cannot be cancelled; ownership therefore remains until its on state is seen rather than treating an initial off snapshot as successful restoration.

The inherited `lockTurnedVoiceOverOn` attribution remains one-shot: if a requested lock-screen start never produces an on notification, a much later manual on event is not inherently distinguishable from a delayed owned start. Normal off notifications and explicit reader choices retire restoration. This patch does not claim to resolve all possible macOS notification attribution, force a hung VoiceOver process to exit, or validate native timing through the pure-state tests.

## Implementation map

- `Sources/TurnOver/LeadWatcher.swift`: native sleep/lock notifications, bounded readiness watch and handover callback eligibility.
- `Sources/TurnOverCore/WakeRestoration.swift`: ownership, attempt generations, readiness and retry allowance.
- `Sources/TurnOverTests/WakeRestorationTests.swift`: 12 named deterministic regression cases; registered in the existing test runner.
- `Resources/Info.plist`: local bug-fix candidate 22.5; changelog and architecture updated. No dependency or private API added.

## Local trial to record

With TurnOver reading and the swap off, sleep or lock, then unlock. VoiceOver should read the password screen; TurnOver should resume when secure input is off and an ordinary app is ready. Repeat once. Separately, when VoiceOver was already on before locking, it should remain on after unlocking. Read the newest installed-app log and record what Oliver actually heard.

Slow readiness and failed handovers are covered by controlled regression scenarios; do not delay system processes, revoke permissions or manufacture a broken reader on Oliver's Mac to reproduce them.

## Rollback and publication

The current installed 22.4 bundle was copied to ~/Library/Developer/TurnOver/rollback/TurnOver-before-wake-edge-fix-20261030.app and verified by matching 145 file hashes and deep strict code-signature verification. A corresponding hash manifest is beside it. This local rollback path is not portable contributor evidence.

No code push, PR update or release before Oliver tries the local installed result. GitHub status updates identify checks performed and remaining trial limits.

## User trial and publication checkpoint

30 October 2026: Oliver reported that the installed 22.5 wake build works. This is a general confirmation of the local trial, not a claim that every delayed-start or failure ordering was individually reproduced. Both full build loops passed 418 tests, including the 12 wake regressions, plus the braille thread and three helper self-tests. Installed signature, Accessibility and keyboard startup were verified. The notification-attribution limit above remains documented.

The wake fix is submitted separately from the folder migration, following the review's publication order.
