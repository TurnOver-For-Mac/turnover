# Architecture of this layout demonstration

## Responsibilities

Core contains shared reading behaviour. Views provides reusable presentation. Apps interprets app-specific interfaces. System assembles Mac integration and registers app modules. Experiments holds work that is not established product behaviour.

The dependency direction we want is application assembly towards app modules, shared views and core interfaces. Core should not need to import an individual app implementation. A compiler boundary enforces type dependencies, not the absence of an app name in a string.

## Existing boundaries remain important

The current TurnOverAX, TurnOverSpeech, TurnOverBraille and TurnOverControl libraries are distinct. The existing speech queue, braille thread, keyboard thread and main-actor reader state keep their owners. Grouping files under Core does not imply combining those targets or moving blocking work onto main.

Helpers, the Safari extension, resources and signatures have their own packaging requirements. Putting the Safari extension beside Safari in this demo makes it discoverable; it does not eliminate its separate build and permission arrangements.

## Before a real source move

Specify exact package paths, target dependencies, registration interfaces, test roots and resource paths. Preserve narrow private-API bridges and fallback behaviour. See [build boundaries](docs/BUILD-BOUNDARIES.md).

Capture ownership and evidence first, then pilot one app. Keep mechanical moves separate from behaviour changes and interface extractions. Full checks and Oliver's local trial remain required before publishing reader changes.
