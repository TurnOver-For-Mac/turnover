# Script Editor

- Bundle id: com.apple.ScriptEditor2
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

All seven navigation checks passed in Mac style; six of seven passed in Windows style, with a silent first key. Earlier evidence identifies the open-file panel and focus carried between styles. Script editing, execution and debugging are not covered.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md).
