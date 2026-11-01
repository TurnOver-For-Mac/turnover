# iTerm2

- Bundle id: com.googlecode.iterm2
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 14–15 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

The first pass found that command output and history were silent. The Terminal module was registered for iTerm2. After permission prompts were answered, the 15 October driver run read command output and history. Duplicate output from native announcements and TurnOver was suppressed; the recorded repeat check spoke the output once. The sweep identifies iTerm2 3.7.

Current-build task coverage remains unassessed. Next: Use a disposable shell to check new output, command history, interruption and repeated output. Compare with Terminal; do not use private shell history.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared Terminal implementation](../Terminal/TerminalAppModule.swift) · [Registration](../../System/BuiltInModules.swift)
