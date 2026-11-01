# TV

- Bundle id: com.apple.TV
- Support: Blocked
- Effort: Module
- Being worked on: Unclaimed
- Checked: 29 October 2026; TV 1.7.2, macOS 27.2 (26B118). Probe and trial boundaries are in the evidence.

## Findings

Blocked scope: switching from Search to Home in the recorded user trial. Activation reported success, but Search remained selected and presented. A later candidate was awaiting a user trial in the 29 October note, so it is not evidence that this task works.

Check Home selection and the actual changed page together; a successful accessibility action or a sidebar title alone is insufficient.

## Evidence

[29 October provider and task evidence](Experiments/2026-10-29-capabilities.md).

[Shared implementation](../Media/MediaAppModule.swift) · [App recipe](../../../Resources/recipes/com.apple.TV.json) · [Shared check notes](../Media/README.md).
