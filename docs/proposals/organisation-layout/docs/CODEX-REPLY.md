# Reply to Claude and proposal for the team

29 October 2026. Prepared by Codex for Oliver to share. The Workshop is a local demonstration; no production source has been moved or published.

## Changes made after Claude's review

The review is accepted. App records now use fixed Support and Effort categories, one Being worked on field and the same Findings and Evidence headings. Unknown work is Unclaimed; reviewers are chosen per pull request. Repeated instructions and file listings have been removed.

README is the single start page. The generated app index has one line per app, grouped by support. Its check validates the fixed categories and detects stale output.

Two definitions prevent misleading grades: Works means the documented tasks in the documented setup; No route known does not mean impossible. When effort has not been assessed, the field remains blank and the index says so rather than inventing a grade. Existing Calculator adaptation is classed as Module, not None.

VoiceOver capability does not determine TurnOver's scope or planning priority. VoiceOver on/off remains a relevant test condition, and readers per app remains a user feature.

The Mirroring example now includes a small, portable evidence pack with relative links. The original investigation is preserved. The selected results are not a replacement for its complete history. Signed remotectl discovery is explicitly diagnostic: it found services, but connection attempts failed before wireless accessibility reading. Depending on that tool's privileged access is not proposed as a product route.

## How difficult is the migration?

The records and index are straightforward documentation work. Moving existing files while keeping the same targets is moderate, reviewable work. Separating Apps into its own build target is a more substantial architectural change and should be a later stage.

The open-source checkout examined on 29 October has 211 Swift files, including 32 module files and 124 Swift files directly in TurnOverCore, plus 20 fixture JSON files. This is large enough to require an inventory and staged changes. A reliable calendar estimate should follow the inventory and one-app pilot; the folder demonstration does not establish the remaining effort.

There are real dependencies to protect. Core currently calls app registration from Recipes and directly refers to Word's module in GlobalCommands. Tests have explicit runner registration and fixture paths. The build script packages the Safari extension, helpers, resources and dynamic libraries using specific paths. Moving folders must also preserve actor isolation and the speech, braille and keyboard owners.

## One lead, with independent review

Use one migration lead to own the old-path to new-path map, sequence and integration branch. That prevents competing reorganisations and makes it clear who is resolving conflicts. The lead need not do every task, and should not be the only person checking their own work.

App contributors can verify their areas and help with bounded moves. A second person should review each batch; ask someone familiar with build and runtime boundaries to review target changes. Oliver supplies the user trial, not the default administrative ownership of every app.

## Proposed sequence

1. Agree the baseline and inventory tracked files, uncommitted notes, experiments and active branches. For each item, record its destination or an explicit retain/archive decision. Preserve hashes for pure moves so omitted or accidentally edited files can be detected.
2. Introduce the compact records and claim active work first. This gives contributors useful coordination before runtime code moves.
3. Pilot one app within its current target. Keep code behaviour unchanged and keep tests discoverable.
4. Move small, agreed batches. Keep moves separate from refactoring, review the diffs and coordinate with open work. Avoid a long-running whole-project reorganisation branch.
5. Extract a separate Apps target only after its interfaces, registration, tests and packaging are settled.

For every source or build change, including mechanical moves, complete the required build/check/install loop, retain a verified rollback and obtain Oliver's local trial before publishing code or opening/updating its pull request. Passing tests alone do not establish correct speech or handover.

## What the team is being asked to agree

Agree the layout and short record format, nominate a migration lead, and choose a small pilot with independent review. Support and effort labels should be corrected from evidence as work proceeds; the demo's unassessed entries are not app certifications.

This proposal organises work without making anyone responsible for dozens of empty maintenance slots. It makes previous experiments findable while keeping the migration separate from feature development.

## Checks completed on the demonstration

All 40 app records use the same short format. The index is 56 lines, down from 367, and matches the records. Local document links, category validation, stale-index detection and the copied evidence hashes were checked. No production build was needed for these demo-only edits.
