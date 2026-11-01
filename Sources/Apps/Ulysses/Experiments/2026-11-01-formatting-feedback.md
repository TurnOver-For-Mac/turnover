# Bold and italic shortcut feedback — 1 November 2026

## Result and scope

Oliver reports silent Command-B/Command-I in Ulysses; he confirms Word already announces them. This request concerns toggling formatting, not increased verbosity while reading. The local candidate uses shared delayed feedback with a Ulysses-specific adapter. The candidate is installed; live metadata checks passed. Oliver's listening trial is pending.

## Live evidence

Ulysses 42 (84473), macOS 27.2 (26B118), existing installed TurnOver 22.5, Mac keys, VoiceOver off. A disposable public sheet was supplied by Oliver and normalized to `TurnOver formatting sample`. The signed metadata-only `format-state` probe and existing HID test driver were used. No personal writing was recorded.

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

## Local records

Sanitized probe summaries are held in the local developer records and shared review packet. Logs are local, not required to understand the results above. Issue: [212](https://github.com/TurnOver-For-Mac/turnover/issues/212). No runtime code has been pushed.

## Local candidate validation

Both required build commands completed: 461 unit tests, braille thread checks and all three helper self-tests passed. The optional real VoiceOver preferences export was skipped because TURNOVER_VOPREFS was not set. Runtime source is local commit `829eb8e` on `codex/format-shortcut-feedback`; the installed bundle and built bundle match and strict signing verification passes. A verified rollback of the previous 22.5 app is retained. No runtime code has been pushed.

Seventeen initial installed cases covered Ulysses end-caret, selected and nested states plus TextEdit empty rich-text on/off. Ten final Ulysses checks covered empty text, a tag before a space, and turning styles off after typing trailing spaces. Subsequent typed characters were plain after the closing tag. The final probe returned the disposable sample to plain text.

Live verification combines public-sample AX state with privacy-masked speech lengths; exact wording and once-only response ownership are checked by the regression tests. Audio was not independently heard. Existing Ulysses selection announcements can precede formatting feedback, and those were retained in the evidence rather than counted as duplicate state responses. Oliver's listening trial remains the publication gate.
