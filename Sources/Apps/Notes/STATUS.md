# Notes

- Bundle id: com.apple.Notes
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 1 November 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

The bundled recipe defines Folders, Notes list and Note parts, using the shared Panes implementation. Registration is recipe-driven. This establishes existing app-specific configuration, not a new live navigation or editing result.

Current-build task coverage remains unassessed. Next: Use public sample notes to check movement between folders, note list and editor, opening a note, and returning to its list.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Panes implementation](../Panes/README.md) · [Notes recipe](../../../Resources/recipes/com.apple.Notes.json)
