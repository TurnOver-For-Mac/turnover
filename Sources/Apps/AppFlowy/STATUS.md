# AppFlowy

- Bundle id: Not recorded
- Support: Blocked
- Effort:
- Being worked on: Unclaimed
- Checked: 14 October 2026; setup details are in the linked evidence.

## Findings

Blocked scope: reading the sampled AppFlowy 0.14 window through its exposed accessibility tree. This does not establish that all app versions or activation routes are inaccessible.

AppFlowy 0.14 exposed only its window and an app group in the captured surface. Asking for enhanced accessibility did not expand the tree; the recorded VoiceOver-on snapshot had the same seven elements. The note proposed investigating Flutter’s accessibility activation. This records an unresolved surface, not proof that every version is inaccessible.

Next check: Verify bundle identity and retest the same surface on the current app version before investigating Flutter activation. Preserve the distinction between an empty sampled tree and impossibility.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md).
