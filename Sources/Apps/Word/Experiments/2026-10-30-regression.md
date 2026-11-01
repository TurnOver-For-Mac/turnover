# Microsoft Word: regression checks, 30 October 2026

## Result

The scenario sent sample typing keys in a scratch document, then verified character/review-command dispatch. A separate Windows-style scenario verified previous-sentence dispatch with nonempty speech, next-sentence dispatch and a comment response.

[Scenario](../../../../testing/scenarios/regression/core/word.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-word.txt | mac style | 3 | 0 | 30 |
| day-word.txt | windows style | 3 | 0 | 44 |
| word.txt | windows style | 6 | 0 | 218 |

## Scope and remaining checks

This grade covers the stated document-navigation checks. Exact spoken text, page-boundary reading, reflow, selection and the boundary-sound change were not validated by these assertions.


The separate sentence/comment scenario is `scenarios/keys-apps/word.txt`. The preceding chat-key phase stopped when user activity was detected; no additional chat result is inferred.
