# Reminders

- Bundle id: com.apple.reminders
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Three review-item movements produced nonempty speech in the opened window. The run did not check reminder text, completion states or creation. This grade covers basic control reading only.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](RemindersAppModule.swift).
