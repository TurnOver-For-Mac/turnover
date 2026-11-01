# Working with app folders

App implementations and support records live in `Sources/Apps/<App>`. The [app index](../Sources/Apps/README.md) lists
recorded support, effort and current work. A folder or an existing module is not proof that every app task works.

## Code and build targets

App modules still compile in TurnOverCore, with its MainActor default. Keep existing types and registration;
`Sources/System/BuiltInModules.swift` assembles them. Shared Mac shell behavior and app wake code live in
`Sources/System`, still within TurnOverCore. The app executable remains in `Sources/TurnOver`. App-specific views and reading models live with their app modules;
reusable window and document models live in `Sources/Views`; shared objects, text and navigation live in `Sources/Core`. See the [source map](../Sources/README.md). Separate target extraction requires interface
and dependency review; a folder move does not create a module boundary.

`Package.swift` uses `Core`, `Views` and `System` as folder entries and lists app Swift files individually. A new shared
Core, Views or System file needs no manifest edit. Add each new app implementation to `coreSources`; add its records, Tests, Fixtures and
Experiments to the target's excludes. Never add all of Sources or Apps as a recursive production entry.

## Records

Use a short STATUS.md with the fixed fields and Findings/Evidence headings shown in the index. Say what was checked,
what is missing, the relevant issue and how another person can check it. Keep dated experiment observations separate
from current status. Build installation paths, migration inventories and rollback history belong with review material.
Shared implementations such as Media, Chat, Panes, Games, Catalog and GoogleDocs have a README; Music, Podcasts and TV retain individual records.
Unknown work stays Unclaimed and unknown support stays Not assessed. If historical evidence lacks a verified bundle
identifier, write `Bundle id: Not recorded` until it is checked; do not invent one. AI help does not assign permanent ownership.

The inventory includes apps handled by shared code, recipes and plugins, as well as named app modules. Recover dated
findings from earlier test runs even when no dedicated implementation exists. Keep planned tasks, snapshots, driver
checks and user listening results distinct; see [the evidence guide](APP-TEST-HISTORY.md).

Run `python3 Tools/build-app-index.py` after editing statuses. `--check` checks categories, local links and stale output.
Use relative links and public sample content. Preserve experiment outcomes, limitations and licences when filing them.

## Checks and moves

Tests remain in `Sources/TurnOverTests`, fixtures in `Tests/Fixtures`, with explicit runner registration unchanged.
App Tests folders hold instructions until a separate test-source change is reviewed. Diagnostic experiments do not
compile into the reader. Shared investigation records are indexed in [Sources/Experiments](../Sources/Experiments/README.md),
which is excluded from every default package target. Use the [experiment template](EXPERIMENT-TEMPLATE.md) for new work.

For a byte-identical move, keep a path map and compare source bytes, file modes, resolved target membership, settings
and named tests. Run the complete build checks. No reinstall or listening trial is required for that mechanical move;
behavior changes retain the normal installed-app trial. Keep large batch inventories and frozen comparisons in the
review packet, not in main. Update CODEOWNERS paths so moving a file does not change who reviews it.
