# Messages

- Bundle id: com.apple.MobileSMS
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: Historical evidence recovered 1 November 2026; recorded checks from 12 and 15 October 2026. Current build not tested.

## Findings

Historical passes: masked latest-message commands passed 4/4 in each keyboard style on 12 October; the valid regression pass also records the core chat checks passing. This is evidence for reading commands, not message sending or a complete messaging workflow.

Support is Not assessed for the current build. The historical results below remain evidence for their stated tasks and setup, not a fresh app-wide assessment.

## Evidence

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared chat implementation](../Chat/ChatAppModule.swift). [Shared chat reading model](../Chat/ChatView.swift). [Messages recipe](../../../Resources/recipes/com.apple.MobileSMS.json).
