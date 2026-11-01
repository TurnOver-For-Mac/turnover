# iPhone Mirroring

- Bundle id: com.apple.ScreenContinuity
- Support: Blocked
- Effort: No route known
- Being worked on: Unclaimed
- Checked: 29 October 2026; the setups and outcomes are recorded in the linked experiments.

## Findings

The tested routes could read Mac window controls but could not read native mirrored-phone content. USB Calculator tests worked on an unlocked phone. Wireless service discovery succeeded, but connections failed. Both phone VoiceOver keyboard trials produced no response. OCR is excluded.

Apple's signed diagnostic tool could find phone services using privileges unavailable to TurnOver. This helped the investigation but does not provide a route TurnOver can ship. These results describe the tested setups, not proof that access is impossible.

## Evidence

[Experiment records](Experiments/README.md) · [Findings and results](Experiments/Evidence/README.md) · [Issue 191](https://github.com/TurnOver-For-Mac/turnover/issues/191).
