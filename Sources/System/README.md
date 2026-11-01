# Mac integration and app registration

These shared production files compile into `TurnOverCore`, with its existing main-actor default and dependencies. The folder groups responsibilities; it does not add a Swift target or change how the app is packaged.

## Finding the code

- [BuiltInModules.swift](BuiltInModules.swift) registers the built-in app implementations and recipe-backed apps. The reader, core test tool and unit tests use this same assembly.
- [AppWake.swift](AppWake.swift) nudges apps whose accessibility interface needs activation before it answers.
- [ApplicationChooser.swift](ApplicationChooser.swift) lists applications and their windows, including system prompts outside the ordinary Command-Tab switcher.
- [ForceQuit.swift](ForceQuit.swift) provides the spoken force-quit chooser and confirmation.
- [MenuNavigation.swift](MenuNavigation.swift) handles native menus; [StatusMenus.swift](StatusMenus.swift) handles the menu bar extras.
- [SystemPrompts.swift](SystemPrompts.swift) watches macOS authentication and permission prompts.
- [NotificationBanners.swift](NotificationBanners.swift) handles notification announcements as an extension of `AXHandler`; [NotificationCentrePanel.swift](NotificationCentrePanel.swift) opens and reads Notification Centre.

The [Dock module](../Apps/Dock/DockAppModule.swift) includes the native Command-Tab switcher. The [Spotlight module](../Apps/Spotlight/SpotlightAppModule.swift) stays with its app record. App-specific changes belong in those homes.

## Build boundaries

[Package.swift](../../Package.swift) discovers production Swift files in this folder, `Core` and `Views`, while listing app files explicitly. New production Swift files here do not need individual manifest entries. Documentation, `Tests`, `Experiments` and `Fixtures` must remain excluded from the reader target; update the manifest exclusions before adding such directories. [The membership check](../../Tools/check-migration.py) rejects omitted or duplicated sources, wrong-target membership and compiled samples.

The app lifecycle, keyboard tap and VoiceOver coordination remain in the separate [TurnOver executable](../TurnOver/). Accessibility, speech, braille and local control retain their existing targets. [Helpers](../../Helpers/) retain their separate packages; resources, bundles and signing paths are unchanged. Filing a shared source here does not permit changing its actor isolation, runtime owner or helper boundary.
