# Mac integration and app registration

System handles the Mac around the apps. These sources compile in TurnOverCore with its main-actor default.

## Finding the code

- [BuiltInModules.swift](BuiltInModules.swift) registers the built-in app implementations and recipe-backed apps. The reader, core test tool and unit tests use this assembly.
- [AppWake.swift](AppWake.swift) nudges apps whose accessibility interface needs activation before it answers.
- [ApplicationChooser.swift](ApplicationChooser.swift) lists applications and their windows, including system prompts outside the ordinary Command-Tab switcher.
- [ForceQuit.swift](ForceQuit.swift) provides the spoken force-quit chooser and confirmation.
- [MenuNavigation.swift](MenuNavigation.swift) handles native menus; [StatusMenus.swift](StatusMenus.swift) handles the menu bar extras.
- [SystemPrompts.swift](SystemPrompts.swift) watches macOS authentication and permission prompts.
- [NotificationBanners.swift](NotificationBanners.swift) handles notification announcements as an extension of `AXHandler`; [NotificationCentrePanel.swift](NotificationCentrePanel.swift) opens and reads Notification Centre.

The [Dock module](../Apps/Dock/DockAppModule.swift) includes the native Command-Tab switcher. Spotlight behavior belongs in the [Spotlight module](../Apps/Spotlight/SpotlightAppModule.swift).

## Build boundaries

[Package.swift](../../Package.swift) discovers production Swift files in System, Core and Views. New Swift files here need no individual manifest entry. Put guides in docs or add their paths to TurnOverCore's exclusions; exclude Tests, Experiments and Fixtures directories too. [The membership check](../../Tools/check-migration.py) rejects omitted or duplicated sources, wrong-target membership and compiled samples.

The app lifecycle, keyboard tap and VoiceOver handover live in the [TurnOver executable](../TurnOver/). Accessibility, speech, braille and local control have separate library targets; [Helpers](../../Helpers/) have separate packages. Follow the runtime ownership and concurrency rules in [AGENTS.md](../../AGENTS.md) when working across those boundaries.
