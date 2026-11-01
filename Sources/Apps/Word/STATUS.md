# Microsoft Word

- Bundle id: com.microsoft.Word
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

The scenario sent sample typing keys in a scratch document, then verified character/review-command dispatch. A separate Windows-style scenario verified previous-sentence dispatch with nonempty speech, next-sentence dispatch and a comment response. This grade covers the stated document-navigation checks. Exact spoken text, page-boundary reading, reflow, selection and the boundary-sound change were not validated by these assertions.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](WordAppModule.swift).
