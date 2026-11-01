# Reusable reading models

These four existing implementations turn a window or document into a model the reader can navigate. They compile in TurnOverCore, with the same types, main-actor default and dependencies as before.

- [FlatView.swift](FlatView.swift): a flat reading model for a window area.
- [FlatScreen.swift](FlatScreen.swift): a screen model discovered through accessibility hit tests.
- [WebBuffer.swift](WebBuffer.swift): the accessibility-derived virtual document used by browse mode.
- [PanesView.swift](PanesView.swift): named parts and navigation for panes recipes, used by the [Panes app module](../Apps/Panes/README.md).

The flat view and flat screen paths retain their existing `flatView` developer switch. Filing them here neither enables a feature nor establishes new live-test results. The [dated flat-view plan](../../docs/FLAT-VIEW-PLAN.md) records the proposal and rationale; it is not a current verification report.

## Related code

Browse commands, selection and activation stay in [Core/BrowseMode](../Core/BrowseMode/), text access in [Core/Text](../Core/Text/), and generic list controls in [Core/Objects](../Core/Objects/). App-specific reading models remain with [App Store](../Apps/AppStore/STATUS.md), [Media](../Apps/Media/README.md) and [Chat](../Apps/Chat/README.md). Their current dependencies are unchanged.

See the [source map](../README.md) for build rules and the [experiment index](../Experiments/README.md) for investigation records. Views is a source folder, not a new Swift module or UI framework.
