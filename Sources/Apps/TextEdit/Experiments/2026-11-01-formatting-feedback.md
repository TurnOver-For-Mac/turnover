# Formatting shortcut comparison — 1 November 2026

## Result and scope

A new unsaved TextEdit document was converted to rich text for comparison with Ulysses. TextEdit 1.21, macOS 27.2 (26B118), installed TurnOver 22.5, Mac keys, VoiceOver off. Local runtime candidate `8514e13` is installed and launched; both full build gates and the repeated live metadata checks passed. Oliver's listening trial remains pending.

In an empty rich-text editor, closed Format → Font → Bold/Italic menu items return a checkmark after the relevant shortcut and `AXError.noValue` after toggling off. This works without existing characters to sample. The candidate adapter uses this observed TextEdit convention only, requiring the matching enabled shortcut and unique English menu identities. Unsupported attributes, failed queries, missing/ambiguous items and changed menus remain unknown.

The native key still passes through. Queries run on the bounded shared worker; focus, window and selection context are checked. Unit fixtures cover large menus, state errors and cancellation. This formatting work makes no claim about the separate native-menu navigation issue 194.

Repeat with an empty rich-text document, text selected, caret at the end, repeated toggles and an immediate app switch. Confirm speech once per completed Command-B/I, then check Word's existing behavior. Do not infer all-editor support from this TextEdit result. Issue [212](https://github.com/TurnOver-For-Mac/turnover/issues/212).

## Local candidate validation

Runtime source is local commit `8514e13` on `codex/format-shortcut-feedback`. Both `./build.sh --no-install` and `./build.sh` passed 463 unit tests, braille thread checks and all three helper self-tests. The corrected app is installed and launched. Strict deep signing verification passed; installed executable and core-library hashes match the build. A verified rollback of the previous 22.5 app is retained. No runtime code has been pushed.

Captured focus and foreground AX references are used only for identity checks. The worker reacquires matching references and applies its 50 ms timeout only to its own objects, including Ulysses text reads and final revalidation. Both app collectors have regression cases proving the original handles never reach the timeout setter while verified states still succeed. This prevents persistent AX timeouts from changing later reader navigation.

All 27 existing live cases passed again on `8514e13`: 17 covered Ulysses end-caret, selected and nested states plus TextEdit empty rich-text on/off; 10 covered Ulysses empty text, a tag before a space, and turning styles off after typing trailing spaces. Subsequent typed characters were plain after the closing tag. The disposable sample was restored to plain text and Ulysses left focused.

Live verification combines public-sample AX state with privacy-masked speech lengths; regression tests check exact wording and once-only response ownership. Audio was not independently heard. Existing Ulysses selection announcements can precede formatting feedback and are not counted as duplicate state responses. Oliver's listening trial remains the publication gate.
