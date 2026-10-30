# Shared media support

[MediaAppModule.swift](MediaAppModule.swift) supplies shared behavior for Music, Podcasts and TV. Recipes select the implementation and describe each app's controls. This folder is a shared implementation, not an app support grade.

## App records and recipes

[Music](../Music/STATUS.md), [Podcasts](../Podcasts/STATUS.md) and [TV](../TV/STATUS.md).

## Checks

Check sidebar movement, content loading, shelves, item activation and return from detail pages in each app. Record the app and macOS versions, keyboard style and VoiceOver state; a result from one app does not establish support in the others.

## Reading model

[MediaView.swift](MediaView.swift) builds the shared sidebar and shelf view. [MediaWorkOwner.swift](MediaWorkOwner.swift), [MediaShelfReadiness.swift](MediaShelfReadiness.swift) and [MediaSidebarSelection.swift](MediaSidebarSelection.swift) keep background work, staged loading and sidebar changes with that implementation.
