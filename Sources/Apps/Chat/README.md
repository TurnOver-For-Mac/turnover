# Shared chat support

[ChatAppModule.swift](ChatAppModule.swift) supplies shared behavior for Messages, Discord and WhatsApp. Recipes select the implementation and describe each app's controls. This folder is a shared implementation, not an app support grade.

## App records and recipes

[Messages](../../../Resources/recipes/com.apple.MobileSMS.json), [Discord](../../../Resources/recipes/com.hnc.Discord.json) and [WhatsApp](../../../Resources/recipes/net.whatsapp.WhatsApp.json).

## Checks

Use a public sample conversation to check conversation selection, transcript reading, arrival of a new message and movement to the composer. Keep sending as a separate check. Record the app and macOS versions, keyboard style and VoiceOver state.

## Reading model

[ChatView.swift](ChatView.swift) builds the conversation, transcript and composer view shared by these app recipes.
