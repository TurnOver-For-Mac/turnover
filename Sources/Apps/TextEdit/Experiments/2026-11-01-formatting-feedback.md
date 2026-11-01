# Formatting shortcut comparison — 1 November 2026

## Result and scope

A new unsaved TextEdit document was converted to rich text for comparison with Ulysses. TextEdit 1.21, macOS 27.2 (26B118), installed TurnOver 22.5, Mac keys, VoiceOver off. Candidate installed-build checks and Oliver's trial remain pending.

In an empty rich-text editor, closed Format → Font → Bold/Italic menu items return a checkmark after the relevant shortcut and `AXError.noValue` after toggling off. This works without existing characters to sample. The candidate adapter uses this observed TextEdit convention only, requiring the matching enabled shortcut and unique English menu identities. Unsupported attributes, failed queries, missing/ambiguous items and changed menus remain unknown.

The native key still passes through. Queries run on the bounded shared worker; focus, window and selection context are checked. Unit fixtures cover large menus, state errors and cancellation. This formatting work makes no claim about the separate native-menu navigation issue 194.

Repeat with an empty rich-text document, text selected, caret at the end, repeated toggles and an immediate app switch. Confirm speech once per completed Command-B/I, then check Word's existing behavior. Do not infer all-editor support from this TextEdit result. Issue [212](https://github.com/TurnOver-For-Mac/turnover/issues/212).
