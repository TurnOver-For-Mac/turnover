# Bold and italic shortcut feedback — 1 November 2026

## Result and scope

Oliver reported silent Command-B/Command-I in Ulysses while Word already announced them. This investigation concerns toggling formatting, not increased verbosity while reading. Shared delayed feedback with a Ulysses-specific adapter reports the resulting state. Oliver confirmed both shortcuts work at the typing cursor and with text selected on 1 November 2026, using TurnOver 22.5 runtime `8514e13`.

## Live evidence

Ulysses 42 (84473), macOS 27.2 (26B118), TurnOver 22.5 runtime `8514e13`, Mac keys, VoiceOver off. A disposable public sheet was supplied by Oliver and normalized to `TurnOver formatting sample`. The signed metadata-only `format-state` probe and existing HID test driver were used. No personal writing was recorded.

- At an end caret, Command-I inserts `_`; Command-B inserts `**`. Repeating removes the marker. Marker font attributes remain plain, so they do not establish pending typing style.
- At a word boundary before a space, an opening tag also enables the style. Ulysses can auto-insert a closing tag while typing; the formatting shortcut then moves the caret past it to turn the style off. Spaces adjacent to tags are valid here, unlike assumptions borrowed from some Markdown parsers.
- At a midpoint inside a word, the same opening markers continue their style through the remaining text. The following character's font reflects the style.
- Selected text is wrapped in `_..._` or `**...**`; removing the outer matching style restores plain text.
- Nested selection `**_..._**` remains bold when Command-B is pressed inside the emphasis span: the app leaves it unchanged. Feedback must report the resulting state, not flip a remembered boolean.
- Strong/Emphasis menu marks return `noValue` in all these states. Their toolbar buttons expose neither value nor selected state.
- Edit → Convert Markup identifies the active built-in Markdown XL with a checkmark. The adapter requires this and the observed English menu identities and shortcuts.

## Implementation limits

Read a complete paragraph, at most 8,192 UTF-16 units, through bounded public AX range queries off the main thread. Recognize the observed `**` and `_` rules, escaping and nesting. Custom markup, alternative/unverified delimiters, complex markup, cross-paragraph selections, incomplete ranges and provider failures remain unknown and silent. Do not infer semantic markup solely from rendered fonts.

Every new key, focus/window change or reader deactivation retires pending feedback. Native shortcuts keep their normal delivery. Word retains its own handlers. The probe is separate from production behavior.

The upstream [Markdown XL guide](https://help.ulysses.app/introduction/markdown-xl) explains the default tags; [custom markup documentation](https://stories.ulysses.app/tips-ulysses-markup/) explains why the active scheme must be checked.

## Repeatable trial

In a disposable Markdown XL sheet, test empty and end carets, a midpoint, selected text, nested bold/italics, closing an active span after typing, rapid toggles and immediate app switching. Expect one accurate state per completed shortcut and no late response in another context. Check Word still speaks once. Inspect only metadata and speech from the public sample. Automated tests do not establish how speech sounds.

## Recorded verification

The 1 November installed-app checks covered end-caret, selected and nested states; empty text; a tag before a space; and turning styles off after typing trailing spaces. Subsequent typed characters were plain after the closing tag. The disposable sample was restored to plain text. Public-sample AX state and privacy-masked speech lengths supplied the automated live evidence; regression tests checked exact wording and once-only response ownership. Existing selection announcements can precede formatting feedback and are not duplicate state responses.

Oliver subsequently answered “Both are working” to the trial question covering Command-B and Command-I at the typing cursor and with text selected. This is the listening result for the named Ulysses cases, not a claim about every markup shape.

Captured focus and foreground AX references serve only as identity checks. The worker reacquires matching references and applies its 50 ms timeout only to its own objects, including text reads and final revalidation. Both app collectors have regression cases proving the original handles never reach the timeout setter while verified states still succeed. This prevents persistent AX timeouts from changing later reader navigation.

Issue: [212](https://github.com/TurnOver-For-Mac/turnover/issues/212). Sanitized summaries are sufficient to understand these results; private logs retained on Oliver’s Mac are not repository prerequisites.
