# TurnOver Workshop

A proposed way to organise TurnOver's code, app support and investigations. This is a browsable demonstration, not the live project or a new reader build.

Start with the [app index](APPS.md). It shows support, effort and who is working on each app. The [reply to Claude and migration proposal](docs/CODEX-REPLY.md) explains the changes and how the team could adopt them.

## The layout

- Sources/Core: shared reading behaviour, including text, speech, keys and accessibility.
- Sources/Views: reusable lists, shelves, transcripts and web presentation.
- Sources/System: Mac integration and module registration.
- Sources/Apps: one home per app for its status, adaptations, tests and experiments.
- Sources/Experiments: investigations that affect several apps.

Tools and documents have separate homes. Shared modules such as Media are linked from Music, Podcasts and TV; each app still has its own support record.

## How to use it

[Contributing](CONTRIBUTING.md) defines the grades and short record format. [Ownership](OWNERSHIP.md) explains claiming work. [Testing](TESTING.md) and [build boundaries](docs/BUILD-BOUNDARIES.md) describe what must stay intact during migration.

Source and test files are placeholders. Effort categories reflect existing adaptations where known; blank effort means it has not been assessed. Support claims are limited to their stated evidence. No person is assigned by this demo.
