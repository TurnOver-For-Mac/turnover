# Document adapters

Native app modules are selected by bundle identifier. Website behavior is selected by the current document URL,
so the same integration can work in Safari and Chromium without placing the site's conditions in shared editing
or event code. This boundary addresses the Google editor ownership work in issues 2 and 70.

## Ownership

`Core/BrowseMode/DocumentAdapters.swift` owns the registry and up to forty in-memory document sessions, identified
by their native root and captured URL. `System/BuiltInModules.swift` registers trusted built-in implementations.
The adapter and its selectors live in the relevant Apps folder; app Swift files retain explicit Package.swift
membership. They still compile in TurnOverCore with its MainActor default.

API focus snapshots select the outer document without walking parents on a key path. Browse mode supplies its
captured URL when available; otherwise selection reads one root attribute. An adapter declares whether the focused
field uses native text feedback. Ordinary documents retain the shared editing behavior.

A foreground change, reader deactivation or process removal deactivates the relevant session. A reused root with a
new address selects a different session. Reactivation waits for fresh focus or caret news. Delivery also checks
reader ownership, focus/window context, menu state and the current session, because cancellation cannot recall a
callback already queued on main.

## Google browser editors

- `Apps/GoogleDocs/GoogleDocs.swift` matches Docs, Sheets and Slides URLs.
- `GoogleDocsSession.swift` owns the current editor, private announcement baseline and once-per-document warning.
- `GoogleDocsQuery.swift` owns bounded read-only collection and validates the captured address before and after it.

The session retains the existing 100 ms polling interval and three-second support-check delay. Polls coalesce while
one read is in flight. Announcement and support reads have separate serial workers, cooperative time limits of
400/250 ms, visit/depth/query caps, and provider-error tracking through AXReadScope. An AX call already in flight
cannot be preempted and retains the existing transport timeout.

Cached regions must belong to the captured root. Text reads stop at 200 nodes or 16,384 UTF-16 units; incomplete,
failed and oversized samples do not replace the last complete announcement. Initial text is a silent baseline unless
a key has already arrived. Appended text supplies only its suffix; replaced text supplies the new announcement.
All document announcements use private speech.

Support is reported off only after a complete search finds no Accessibility menu. A truncated or failed check stays
silent. Delayed hints carry the activation's validity check through to actual delivery, including when focus stays
on a reused AX element. The existing English menu match remains a limitation; this change does not add translated
selectors or turn on Google's screen reader setting.

## Verification and listening

The custom test runner registers `GoogleDocsTests`: URL matching, nested typing frames, root/region identity,
provider budgets, native editing-key delivery, private speech, delayed results, polling coalescing and support hints.
`Tools/check-app-boundaries.py` rejects Word and Google editor implementation references in shared Core/Views code.

Run the full `./build.sh --no-install` and `./build.sh` loops. A live trial must separately name browser/version,
Docs/Sheets/Slides, macOS, keyboard style, browse/focus mode and reader ownership. In a public sample, check caret and
selection keys, typing/deletion/Return feedback, leaving and returning to an editor, tab/window/document changes,
and stopping/reactivating TurnOver. Check Google's screen reader support both on and off. Automated fixtures do
not establish live announcement timing, browser coverage or the wording actually heard.
