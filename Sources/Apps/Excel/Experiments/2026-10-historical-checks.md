# Excel: cell reading and selection, 10–12 October 2026

## Provenance and setup

The retained project notes `testing/2026-10-10-notes.md` (Day 2 apps, Excel highlighting and cold start) and `testing/2026-10-12-notes.md` (corrected regression rerun before build 17) record these results. The driver used an authored sample workbook in read-only mode after dismissing the trial offer. Mac and Windows are TurnOver keyboard styles on macOS. Exact app/macOS versions and binary hashes are not recorded.

## Results

- 10 October: cell value/address checks passed 7/7 in each keyboard style after focus and selected-cell handling were corrected.
- Selection announcements have separate user evidence: Oliver reported the range feedback worked. The driver's selection keys did not reproduce the same action reliably, so its results are not substituted for that user report.
- A cold grid became available after Excel was brought to the foreground under VoiceOver. The implementation temporarily handed over before returning to TurnOver. A query flag alone, background VoiceOver and repeated window walks had not produced the grid in that check.
- 12 October: the corrected sample-workbook rerun passed 7/7 Windows and 6/7 Mac checks. The initial Mac-style Control-Home arrived during the three-second grid handover; the remaining cells read.

## Limits and later evidence

Cold-start input remains the recorded gap. The user selection result and driver cell-reading results cover different actions. Editing, formulas and a complete workbook workflow are not established by these checks.

The [30 October regression](2026-10-30-regression.md) stopped at a Microsoft 365 offer before reaching the workbook. It supplies no contrary cell-reading result and does not reset the earlier assessment merely because it used a later build.
