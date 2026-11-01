# Terminal

- Bundle id: com.apple.Terminal
- Support: Works
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

After a command was entered in a new terminal window, the previous-line review handler ran and emitted nonempty speech. This grade covers terminal-line review in the tested setup; the assertion did not compare the spoken line with expected command output. Emoji/combining-character editing, long scrollback and shell-specific erase behavior remain separate checks.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](TerminalAppModule.swift).
