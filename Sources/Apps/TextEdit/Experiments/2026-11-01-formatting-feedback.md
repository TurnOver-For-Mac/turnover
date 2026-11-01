# Formatting shortcut comparison — 1 November 2026

## Result and scope

A new unsaved TextEdit document was converted to rich text for comparison with Ulysses. TextEdit 1.21, macOS 27.2 (26B118), TurnOver 22.5 runtime `8514e13`, Mac keys, VoiceOver off. Oliver reported successful bold and italic shortcut feedback by ear on 1 November 2026; Claude recorded that result in his review. This investigation concerns shortcut feedback, not increased formatting verbosity during ordinary reading.

In an empty rich-text editor, closed Format → Font → Bold/Italic menu items return a checkmark after the relevant shortcut and `AXError.noValue` after toggling off. This works without existing characters to sample. The adapter uses this observed TextEdit convention only, requiring the matching enabled shortcut and unique English menu identities. Unsupported attributes, failed queries, missing/ambiguous items and changed menus remain unknown.

The native key still passes through. Queries run on the bounded shared worker; focus, window and selection context are checked. Unit fixtures cover large menus, state errors and cancellation. This formatting work makes no claim about the separate native-menu navigation issue 194.

## Repeatable trial

Repeat with an empty rich-text document, text selected, caret at the end, repeated toggles and an immediate app switch. Confirm speech once per completed Command-B/I, then check Word's existing behavior. Do not infer all-editor support from this TextEdit result. Issue [212](https://github.com/TurnOver-For-Mac/turnover/issues/212).

## Recorded verification

The 1 November installed-app checks exercised bold and italic on/off in an empty rich-text document. Public-sample AX state and privacy-masked speech lengths supplied the automated live evidence; regression tests checked exact wording and once-only response ownership. The automated run did not assess audio by listening. Oliver’s subsequent successful trial, recorded by Claude, supplies the listening result; its exact selection/caret variants were not separately recorded.

Captured focus and foreground AX references serve only as identity checks. The worker reacquires matching references and applies its 50 ms timeout only to its own objects. Both app collectors have regression cases proving the original handles never reach the timeout setter while verified states still succeed. This prevents persistent AX timeouts from changing later reader navigation.

Sanitized summaries are sufficient to understand these results; private logs retained on Oliver’s Mac are not repository prerequisites.
