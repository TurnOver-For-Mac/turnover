# Google browser editors

[GoogleDocs.swift](GoogleDocs.swift) contains the existing support for Google Docs, Sheets and Slides hosted in a browser. It recognizes editor URLs and typing targets, checks for the service's screen reader support, and reads its announcement region while the editor is focused. The original dated source comments describe the observations and limits behind this route.

## Browser records

See [Safari](../Safari/STATUS.md) and [Chrome](../Chrome/STATUS.md) for browser evidence. This is shared website-specific code, not a native Mac app module, so this folder has no invented bundle identifier or native-app support grade. Its Core and Views callers remain unchanged.

## Checks

Use a public sample document. Record the browser and version, which Google editor, its screen reader support setting, TurnOver's keyboard style and focus mode, and what typing, caret movement and selection actually announce. A browser test or a passing build alone does not establish all three editors' behavior. Keep private document text out of fixtures and logs.
