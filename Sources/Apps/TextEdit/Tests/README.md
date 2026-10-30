# Checking TextEdit menus

## Live check

Use a disposable document. Enter the menu bar, move to File, open it and move through items with plain Down. Repeat with Control–Option–Down. Include a second press immediately after opening, for both key combinations.

Repeat with Edit. Check left/right menu changes, Escape, and normal document navigation after the menu closes. Do not select a destructive menu command.

Record the TextEdit and macOS versions, reader build, keyboard style, VoiceOver state and what was spoken. The expected result is that the open menu owns navigation until it closes; the underlying document must not receive those arrow commands.

## Regression checks

Changes to shared menu handling should cover visible native menus, repeated opening notifications, hidden or zero-sized menus, menus belonging to another app, web menus and disappearance during navigation. Test both plain arrows and the Mac reader-arrow commands. These cases belong in the [existing test runner](../../../TurnOverTests/main.swift); this folder holds the app's check instructions.

Follow [TESTING.md](../../../../TESTING.md) for the automated build checks. Keep the listening result separate from the test count.

## Evidence and issue

The [dated investigation](../Experiments/2026-10-29-menu-navigation.md) preserves the original observations and experiments. [Issue 194](https://github.com/TurnOver-For-Mac/turnover/issues/194) tracks the menu-navigation gap and current fix status.
