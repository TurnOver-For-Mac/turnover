# Working with app records

This is a proposed workflow. The live repository's contribution and local-trial rules still apply.

## Scope

TurnOver is intended eventually to read everything itself. VoiceOver's capabilities do not grade an app or decide its priority. Keep VoiceOver on/off and reader mode as test conditions. Readers per app remains a user feature.

## Support

- Not assessed: no recorded assessment of the relevant tasks.
- Works: the named tasks work in the recorded setup; not a promise about every task or computer.
- Partial: useful tasks work, with recorded gaps.
- Blocked: no usable route for the stated task in the tested setup; not proof of impossibility.

## Effort

- None: no app-specific adaptation is needed for the stated scope; shared code still needs maintenance.
- Settings or plugin: configuration or a small plugin/profile is sufficient.
- Module: app-specific reading or navigation logic is needed.
- Workaround: an indirect method is needed because the usual app interface is insufficient.
- No route known: no usable approach has been demonstrated for the stated task.

These are categories, not estimates in days. Leave Effort blank until there is enough evidence to choose one; the index displays “not assessed.” Missing data is not a sixth grade and must not be labelled “No route known.”

## Short, consistent records

Each STATUS.md has Bundle id, Support, Effort, Being worked on and Checked fields, followed by exactly two headings: Findings and Evidence. Keep the findings specific to the app. Put shared instructions here, not in every app record.

Being worked on contains a person and an active issue link, or Unclaimed. Record AI assistance in the evidence, separately from human responsibility. Reviewers are chosen per pull request.

Record the actual TurnOver revision, app and macOS versions, keyboard style, reader mode and tested tasks in the linked evidence. Include hardware and network conditions when relevant. Do not use a folder's presence or lack of code as a support assessment.

## Pick work and retain its history

Read the [index](APPS.md), status and experiments before claiming a bounded issue. App-specific findings belong with the app. Cross-app work has one record linked from affected apps. Use the [experiment template](docs/EXPERIMENT-TEMPLATE.md) and relative links.

After source or build changes, including mechanical file moves, run the required checks, retain a verified rollback and install for Oliver's trial before publishing code or opening/updating a pull request. A passing fixture test does not replace listening or live app checks.
