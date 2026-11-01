# Shared pane support

[PanesAppModule.swift](PanesAppModule.swift) supplies shared behavior for apps described by a panes recipe, including Notes. Recipes select the implementation and describe each app's controls. This folder is a shared implementation, not an app support grade.

## App records and recipes

[Notes record](../Notes/STATUS.md) and [Notes recipe](../../../Resources/recipes/com.apple.Notes.json).

## Checks

Use sample content to check movement between the folder list, item list and document. Record which app and recipe were used, the macOS version, keyboard style and VoiceOver state.

## Reading model

[PanesView.swift](../../Views/PanesView.swift) builds the named parts and navigation used by panes recipes.
