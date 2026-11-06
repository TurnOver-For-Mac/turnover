# Shared Apple catalog support

[Catalog.swift](Catalog.swift) sends a search term to Apple's public catalog, reads the returned list and opens the selected entry through the app's URL scheme. It is on for everyone from build 23, and falls back to reading the app's own page when the catalog cannot answer.

## App records

`kind(for:)` selects [App Store](../AppStore/STATUS.md), [Music](../Music/STATUS.md) and [Podcasts](../Podcasts/STATUS.md). It excludes [TV](../TV/STATUS.md), despite a TV query kind in the code: the 28 October 2026 investigation found missing Apple TV+ results.

[Media](../Media/README.md) contains the shared media app implementation. Record support against each app and task, rather than this shared helper.

## Checks

Record the app, storefront assumption, public search term, reader mode and actual destination opened. Check the native page or purchase action separately from the catalog response. The [flat-view plan](../../../docs/FLAT-VIEW-PLAN.md) and [Apple reports](../../../docs/APPLE-FEEDBACK-2026-10-28.md) explain the design and platform findings.
