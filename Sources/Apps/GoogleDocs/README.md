# Google browser editors

[GoogleDocs.swift](GoogleDocs.swift) supports Google Docs, Sheets and Slides hosted in a browser. It recognizes editor URLs and typing targets, checks for the service's screen reader support, and reads its announcement region while the editor is focused. Dated source comments describe the observations behind this route.

## Browser records

Record support as browser tasks under [Safari](../Safari/STATUS.md) or [Chrome](../Chrome/STATUS.md). This website integration has no native Mac app bundle identifier.

## Checks

Use a public sample document. Record the browser and version, which Google editor, its screen reader support setting, TurnOver's keyboard style and focus mode, and what typing, caret movement and selection announce. Check each editor separately. Keep private document text out of fixtures and logs.

## Document adapter

`GoogleDocs.swift` matches document URLs. `GoogleDocsSession.swift` owns one document's editor focus,
announcement baseline, polling and support warning. `GoogleDocsQuery.swift` collects AX data off main through
bounded workers. The browser's app module is unchanged; shared Core code uses the document-adapter contract.

Caret movement, selection, Backspace, forward Delete and Return keep their native delivery. Google supplies their
feedback through `docs-aria-speakable`; TurnOver does not start a hidden-field caret wait or add a second edit report.
Announcement text remains private speech. A first key received while the initial sample is pending can still be read.

Changing focus, document address, foreground window or reader ownership retires pending replies. Cached regions
are checked against their document root; incomplete reads do not replace a complete sample or establish that screen
reader support is off. The existing English `Accessibility` menu match and Command Option Z instruction are retained.

`GoogleDocsTests` uses public synthetic browser trees and controlled asynchronous replies. These checks do not
establish live Docs, Sheets or Slides behavior in either browser. Keep their listening results separate and retain
this record's existing limitations. See [document adapters](../../../docs/DOCUMENT-ADAPTERS.md).
