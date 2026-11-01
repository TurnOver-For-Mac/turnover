# Investigation records

This is the entry point for shared investigations. Existing records remain at their evidence-bearing locations below. No example experiment or new runtime behavior has been introduced by this folder migration.

## Existing records

- [Sleep and wake restoration](../../docs/investigations/wake-restoration/2026-10-30-edge-cases.md): implementation, automated checks, local trial checkpoint and remaining limits.
- [Flat-view plan, 27 October 2026](../../docs/FLAT-VIEW-PLAN.md): a dated design proposal; consult the actual code in [Views](../Views/README.md) for current implementation. The plan is not a fresh validation result.
- [Apple accessibility reports, 28 October 2026](../../docs/APPLE-FEEDBACK-2026-10-28.md): retained platform observations and feedback references.
- [iPhone Mirroring experiments](../Apps/iPhoneMirroring/Experiments/README.md): distinct Mac accessibility, developer-service and phone keyboard routes, their results and limitations.
- [TextEdit menu investigation](../Apps/TextEdit/Experiments/2026-10-29-menu-navigation.md): app-specific evidence; [tests and live-check instructions](../Apps/TextEdit/Tests/README.md) remain separate.
- [App test history guide](../../docs/APP-TEST-HISTORY.md): how to distinguish planned work, probes, historical tests and current support across the app records.

## Starting an investigation

Use the [experiment template](../../docs/EXPERIMENT-TEMPLATE.md). Keep app-specific work in `Apps/<App>/Experiments`. Put a genuinely shared new investigation here and link affected apps to that one record. State the question, current worker, setup, evidence, review point and decision without assigning a maintainer who has not accepted the work.

Use sanitized public sample content. Record unsuccessful approaches and the evidence that could justify retrying them. Distinguish a privileged diagnostic route from access available to the installed reader. Raw local evidence and build inventories belong in the review packet when they are private or machine-specific.

## Build boundary

[Package.swift](../../Package.swift) excludes this entire folder, and [the membership check](../../Tools/check-migration.py) rejects code from it in any default package target. Existing standalone diagnostic packages retain their own build boundaries. Production implementations stay in Core, Views, Apps or System with their existing developer switches; filing a record does not turn them on or off.

Graduating an experiment requires a separate reviewed implementation change, relevant automated checks and an installed-app trial for behavior changes. Retiring it preserves the result and reason so another contributor does not repeat an unsuccessful route without new evidence.
