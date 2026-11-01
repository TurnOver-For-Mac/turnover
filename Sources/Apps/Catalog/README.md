# Shared Apple catalog support

[Catalog.swift](Catalog.swift) implements the existing catalog search route used by Apple's store apps. It sends the entered search term to Apple's public catalog, reads the returned list and opens the selected entry through the app's URL scheme. It retains the existing `flatView` developer switch and fallback to reading the app's own page.

## App records

The current bundle routing selects [App Store](../AppStore/STATUS.md), [Music](../Music/STATUS.md) and [Podcasts](../Podcasts/STATUS.md). A TV query kind exists, but `kind(for:)` deliberately does not select [TV](../TV/STATUS.md): the code records missing Apple TV+ results in the 28 October 2026 investigation. Do not infer TV catalog support from that enum case.

[Media](../Media/README.md) contains the shared media app implementation. This folder groups one app-family helper and has no independent support grade. Its types and callers are unchanged.

## Evidence and checks

The [flat-view plan](../../../docs/FLAT-VIEW-PLAN.md) and [Apple reports](../../../docs/APPLE-FEEDBACK-2026-10-28.md) preserve the original rationale and platform findings. This filing change adds no live measurements. Future checks should name the app, storefront assumption, public search term, reader mode and actual destination opened; catalog data alone cannot verify a native page or purchase action.
