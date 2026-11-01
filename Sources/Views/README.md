# Reusable reading models

Views turns windows and documents into models the reader can navigate. Its sources compile in TurnOverCore with the main-actor default.

- [FlatView.swift](FlatView.swift): a flat reading model for a window area.
- [FlatScreen.swift](FlatScreen.swift): a screen model discovered through accessibility hit tests.
- [WebBuffer.swift](WebBuffer.swift): the accessibility-derived virtual document used by browse mode.
- [PanesView.swift](PanesView.swift): named parts and navigation for panes recipes, used by the [Panes app module](../Apps/Panes/README.md).

FlatView and FlatScreen use the `flatView` developer switch. The [flat-view plan](../../docs/FLAT-VIEW-PLAN.md) records their design rationale.

## Related code

Browse commands, selection and activation live in [Core/BrowseMode](../Core/BrowseMode/), text access in [Core/Text](../Core/Text/), and generic list controls in [Core/Objects](../Core/Objects/). App-specific reading models live with [App Store](../Apps/AppStore/STATUS.md), [Media](../Apps/Media/README.md) and [Chat](../Apps/Chat/README.md).

See the [source map](../README.md) for build rules and the [experiment index](../Experiments/README.md) for investigation records.
