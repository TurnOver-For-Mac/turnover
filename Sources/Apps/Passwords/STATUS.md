# Passwords

- Bundle id: com.apple.Passwords
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Five of six navigation checks passed in each style; the first item key produced no accepted response. Earlier checks covered the locked screen. The release handoff also identifies a silent first key. Vault access, secret fields and editing are not assessed.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md).
