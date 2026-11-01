# Discord

- Bundle id: com.hnc.Discord
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 15 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

After sign-in, masked driver checks reached channels, messages and the composer through the chat recipe. Up, Home, End and Escape were exercised. Moving above the oldest loaded message reached older messages. Incoming-message announcements were not tested because no new message was posted during that check. The earlier sign-in screen alone was not the full result.

Current-build task coverage remains unassessed. Next: In a public test server, check channel changes, older-history loading, composer return and a newly arriving message; record the app version and keyboard style.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Chat implementation](../Chat/README.md) · [Discord recipe](../../../Resources/recipes/com.hnc.Discord.json)
