# Microsoft Excel

- Bundle id: com.microsoft.Excel
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 10–12 October 2026 cell-reading and selection checks; 30 October developer build of 22.4 source 0ed2ab4 was stopped by an offer. Setups are in the evidence.

## Findings

Cell values and addresses passed 7/7 driver checks in each style on 10 October. Oliver separately confirmed selection announcements. The corrected 12 October rerun passed 7/7 in Windows style and 6/7 in Mac style; the first cold-start key arrived during the temporary VoiceOver handover for grid activation.

On 30 October, a Microsoft 365 offer stopped the workbook test, so all seven expectations missed in each style. That setup failure does not invalidate the earlier working cell-reading route. Cold-start readiness remains a gap; formula editing and a complete spreadsheet workflow are not assessed.

## Evidence

[Cell reading, selection and cold-start findings](Experiments/2026-10-historical-checks.md).

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](ExcelAppModule.swift).
