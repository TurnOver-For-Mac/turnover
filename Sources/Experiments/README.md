# Investigation records

Shared investigations are indexed here. App-specific experiments live with their app records.

## Records

- [Sleep and wake restoration](../../docs/investigations/wake-restoration/2026-10-30-edge-cases.md): implementation, automated checks, local trial and remaining limits.
- [Flat-view plan, 27 October 2026](../../docs/FLAT-VIEW-PLAN.md): design rationale for the reading models in [Views](../Views/README.md).
- [Apple accessibility reports, 28 October 2026](../../docs/APPLE-FEEDBACK-2026-10-28.md): platform observations and feedback references.
- [iPhone Mirroring experiments](../Apps/iPhoneMirroring/Experiments/README.md): Mac accessibility, developer-service and phone keyboard routes, with their results and limitations.
- [TextEdit menu investigation](../Apps/TextEdit/Experiments/2026-10-29-menu-navigation.md): app-specific evidence, with [test and live-check instructions](../Apps/TextEdit/Tests/README.md).
- [App test history guide](../../docs/APP-TEST-HISTORY.md): interpreting plans, probes, historical tests and support grades.

## Starting an investigation

Use the [experiment template](../../docs/EXPERIMENT-TEMPLATE.md). Put app-specific work in `Apps/<App>/Experiments` and shared work here. Link affected apps to the shared record. State the question, current worker, setup, evidence, review point and decision; a person must accept responsibility before being named as the owner.

Use sanitized public sample content. Record unsuccessful approaches and the evidence that could justify retrying them. Distinguish privileged diagnostic access from access available to the installed reader. Keep private or machine-specific raw evidence in local review material.

## Build boundary and decisions

[Package.swift](../../Package.swift) excludes this folder from default targets; [the membership check](../../Tools/check-migration.py) enforces that boundary. Standalone diagnostic packages have their own build instructions. Production code belongs in Core, Views, Apps or System, with its switch and availability rules documented beside the implementation.

Graduating an experiment requires a reviewed implementation change, automated checks and an installed-app trial for behavior changes. Retiring it preserves the result and reason, including what new evidence could justify another attempt.
