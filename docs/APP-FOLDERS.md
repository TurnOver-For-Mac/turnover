# Working with app folders

App implementations and support records live in `Sources/Apps/<App>`. The [app index](../Sources/Apps/README.md) lists
support for recorded tasks, implementation effort and current work.

## Code and build targets

App modules compile in TurnOverCore with its MainActor default. `Sources/System/BuiltInModules.swift` registers them.
Shared Mac shell behavior and app wake code live in `Sources/System`; the app executable lives in `Sources/TurnOver`.
App-specific views belong with their app modules, reusable reading models in `Sources/Views`, and shared objects,
text and navigation in `Sources/Core`. See the [source map](../Sources/README.md).

`Package.swift` discovers Core, Views and System sources recursively. Add each new app Swift implementation to
`coreSources`. Run `python3 Tools/build-app-index.py` after adding or changing app records or documentation: it writes
the app index and the generated Apps exclusions in Package.swift. Do not edit that generated block by hand.
`--check` validates records and local links and rejects stale index or exclusion output.

## Records

Use a short STATUS.md with the fixed fields and Findings/Evidence headings shown in the index. State the tasks tried,
the result, known gaps, relevant issue and how another person can check them. Grade from the best available evidence
for those tasks. Keep its actual date and build in Checked; a newer build alone does not reset the grade. Use
Not assessed where evidence is insufficient, and update the grade when further checks establish a result or regression.

Keep dated experiment observations separate from the status summary. Build installation paths, migration inventories
and rollback history belong in review material. Shared implementations such as Media, Chat, Panes, Games, Catalog
and GoogleDocs have a README; each app has its own support record.

Unknown work stays Unclaimed. If evidence lacks a verified bundle identifier, write `Bundle id: Not recorded` until
it is checked. AI help does not assign permanent ownership. Use relative links and public sample content, preserving
outcomes, limitations and licences.

The inventory includes apps handled by shared code, recipes and plugins, as well as dedicated modules. Include dated
findings from earlier test runs. Keep planned tasks, structural probes, driver checks and listening results distinct;
see [the evidence guide](APP-TEST-HISTORY.md).

## Tests and investigations

Tests live in `Sources/TurnOverTests`, fixtures in `Tests/Fixtures`, with explicit runner registration. App Tests
folders hold instructions. Diagnostic experiments are excluded from production builds. Shared investigation records
are indexed in [Sources/Experiments](../Sources/Experiments/README.md), which is excluded from every default package
target. Use the [experiment template](EXPERIMENT-TEMPLATE.md) for new work.

For a byte-identical move, compare source bytes, modes, target membership, settings and named tests, then run the full
build checks. Such a move needs no reinstall or listening trial; behavior changes require the installed-app trial.
Keep frozen comparisons in review material and update CODEOWNERS so moving a file preserves review ownership.
