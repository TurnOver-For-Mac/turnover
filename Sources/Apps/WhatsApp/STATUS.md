# WhatsApp

- Bundle id: net.whatsapp.WhatsApp
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Conversation, previous-message, previous-part, next-item and return-to-composer commands reached their expected handlers. These five assertions check dispatch. The 12 and 15 October records separately establish message reading and older/archived-row navigation. The later 30 October chat-key phase stopped for user activity; sending and incoming-message behavior are not covered.

Recorded checks: masked latest-message commands passed 4/4 in each keyboard style on 12 October. On 15 October the driver reached newly loaded Archived rows and measured faster movement between parts. Corrected row numbering had not yet been heard after that change, and full messaging remains unverified.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared chat implementation](../Chat/ChatAppModule.swift). [Shared chat reading model](../Chat/ChatView.swift). [WhatsApp recipe](../../../Resources/recipes/net.whatsapp.WhatsApp.json).
