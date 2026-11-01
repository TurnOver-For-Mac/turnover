# iTerm2

- Bundle id: com.googlecode.iterm2
- Support: Works
- Effort: Module
- Being worked on: Unclaimed
- Checked: 14–15 October 2026; setup details are in the linked evidence.

## Findings

Works scope: command output and history reading, including the checked suppression of duplicate output. Broader terminal editing remains unassessed.

The first pass found that command output and history were silent. The Terminal module was registered for iTerm2. After permission prompts were answered, the 15 October driver run read command output and history. Duplicate output from native announcements and TurnOver was suppressed; the recorded repeat check spoke the output once. The sweep identifies iTerm2 3.7.

Next check: Use a disposable shell to check new output, command history, interruption and repeated output. Compare with Terminal; do not use private shell history.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared Terminal implementation](../Terminal/TerminalAppModule.swift) · [Registration](../../System/BuiltInModules.swift)
