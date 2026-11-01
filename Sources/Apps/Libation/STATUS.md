# Libation

- Bundle id: org.libation.macos
- Support: Not assessed
- Effort:
- Being worked on: Unclaimed
- Checked: 14 October 2026 source observations; identity checked 1 November 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

Existing shared mechanisms explicitly cite Libation: holding a grid that emits no focus or selection events, finding deeper labels, suppressing class names as labels, reading spinner values, allowing longer plugin checks and retiring a removed view. PureTests has a Libation-parts case for the profile format. The installed app metadata identifies org.libation.macos; the com.libation.app string in a core-test example is sample input, not the verified identity. No currently enabled profile or end-to-end library workflow was established during this recovery.

Current-build task coverage remains unassessed. Next: Confirm the app identity and actual profile first, then check a public sample library, row movement, action labels and spinner values. Do not infer a complete download workflow from the format test.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared parts inventory](../../TurnOverCore/TurnOverParts.swift) · [Profile implementation](../../TurnOverCore/Profiles.swift) · [Existing format tests](../../TurnOverTests/PureTests.swift)
