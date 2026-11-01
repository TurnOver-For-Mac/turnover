# Messages

- Bundle id: com.apple.MobileSMS
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Moving to conversations produced a numbered response; previous-message and next-part commands reached their expected handlers. The 12 October record also reports latest-message reading checks. Sending and new incoming-message announcements were not established by this regression. The later chat-key phase stopped for user activity before completing.

Recorded checks: masked latest-message commands passed 4/4 in each keyboard style on 12 October; the valid regression pass also records the core chat checks passing. This is evidence for reading commands, not message sending or a complete messaging workflow.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared chat implementation](../Chat/ChatAppModule.swift). [Shared chat reading model](../Chat/ChatView.swift). [Messages recipe](../../../Resources/recipes/com.apple.MobileSMS.json).
