# Testing in the proposed layout

## This demo

The source and test files are explanatory placeholders. There is no Package.swift or reader build to run here. Creating these folders is not a passed test of TurnOver.

## During a real migration

TurnOver uses its custom test executable. Moving a test must preserve its target membership, registration in the runner and fixture paths. App-local Tests folders must be excluded from production targets. See [build boundaries](docs/BUILD-BOUNDARIES.md).

Record fixture sources using only public or disposable sample content. Automated checks complement live checks; they cannot establish how speech sounds, reader handover behaves or real pages populate.

## Installed trial

Follow the real repository's full build/install loop, not commands in this demonstration. Preserve a verified rollback and install the signed app for Oliver's trial. Record the app and macOS versions, TurnOver revision, hardware where relevant, keyboard style, reader mode, tested tasks and results.

Compare app loading with TurnOver processing before attributing a delay. Keep untested machines and network conditions explicit.
