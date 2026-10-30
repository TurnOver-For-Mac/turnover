# Working with app folders

App implementations and support records live in `Sources/Apps/<App>`. The [app index](../Sources/Apps/README.md) lists
recorded support, effort and current work. A folder or an existing module is not proof that every app task works.

## Code and build targets

App modules still compile in TurnOverCore, with its MainActor default. Keep existing types and registration;
`Sources/TurnOverCore/Modules/BuiltInModules.swift` assembles them. Shared app-wake code stays with Core. App-specific
views may still be under Core while the remaining filing work proceeds. Separate target extraction requires interface
and dependency review; a folder move does not create a module boundary.

`Package.swift` uses `TurnOverCore` as one folder entry and lists app Swift files individually. A new shared Core file
needs no manifest edit. Add each new app implementation to `coreSources`; add its records, Tests, Fixtures and
Experiments to the target's excludes. Never add all of Sources or Apps as a recursive production entry.

## Records

Use a short STATUS.md with the fixed fields and Findings/Evidence headings shown in the index. Say what was checked,
what is missing, the relevant issue and how another person can check it. Keep dated experiment observations separate
from current status. Build installation paths, migration inventories and rollback history belong with review material.
Shared implementations such as Media, Chat and Panes have a README; Music, Podcasts and TV retain individual records.
Unknown work stays Unclaimed and unknown support stays Not assessed. AI help does not assign permanent ownership.

Run `python3 Tools/build-app-index.py` after editing statuses. `--check` checks categories, local links and stale output.
Use relative links and public sample content. Preserve experiment outcomes, limitations and licences when filing them.

## Checks and moves

Tests remain in `Sources/TurnOverTests`, fixtures in `Tests/Fixtures`, with explicit runner registration unchanged.
App Tests folders hold instructions until a separate test-source change is reviewed. Diagnostic experiments do not
compile into the reader.

For a byte-identical move, keep a path map and compare source bytes, file modes, resolved target membership, settings
and named tests. Run the complete build checks. No reinstall or listening trial is required for that mechanical move;
behavior changes retain the normal installed-app trial. Keep large batch inventories and frozen comparisons in the
review packet, not in main. Update CODEOWNERS paths so moving a file does not change who reviews it.
