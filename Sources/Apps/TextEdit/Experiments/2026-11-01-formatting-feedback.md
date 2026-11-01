# Formatting shortcut comparison — 1 November 2026

## Result and scope

A new unsaved TextEdit document was converted to rich text for comparison with Ulysses. TextEdit 1.21, macOS 27.2 (26B118), installed TurnOver 22.5, Mac keys, VoiceOver off. The candidate is installed; live metadata checks passed. Oliver's listening trial remains pending.

In an empty rich-text editor, closed Format → Font → Bold/Italic menu items return a checkmark after the relevant shortcut and `AXError.noValue` after toggling off. This works without existing characters to sample. The candidate adapter uses this observed TextEdit convention only, requiring the matching enabled shortcut and unique English menu identities. Unsupported attributes, failed queries, missing/ambiguous items and changed menus remain unknown.

The native key still passes through. Queries run on the bounded shared worker; focus, window and selection context are checked. Unit fixtures cover large menus, state errors and cancellation. This formatting work makes no claim about the separate native-menu navigation issue 194.

Repeat with an empty rich-text document, text selected, caret at the end, repeated toggles and an immediate app switch. Confirm speech once per completed Command-B/I, then check Word's existing behavior. Do not infer all-editor support from this TextEdit result. Issue [212](https://github.com/TurnOver-For-Mac/turnover/issues/212).

## Local candidate validation

Both required build commands completed: 461 unit tests, braille thread checks and all three helper self-tests passed. The optional real VoiceOver preferences export was skipped because TURNOVER_VOPREFS was not set. Runtime source is local commit `829eb8e` on `codex/format-shortcut-feedback`; the installed bundle and built bundle match and strict signing verification passes. A verified rollback of the previous 22.5 app is retained. No runtime code has been pushed.

Seventeen initial installed cases covered Ulysses end-caret, selected and nested states plus TextEdit empty rich-text on/off. Ten final Ulysses checks covered empty text, a tag before a space, and turning styles off after typing trailing spaces. Subsequent typed characters were plain after the closing tag. The final probe returned the disposable sample to plain text.

Live verification combines public-sample AX state with privacy-masked speech lengths; exact wording and once-only response ownership are checked by the regression tests. Audio was not independently heard. Existing Ulysses selection announcements can precede formatting feedback, and those were retained in the evidence rather than counted as duplicate state responses. Oliver's listening trial remains the publication gate.
