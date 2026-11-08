# TurnOver Settings

- Bundle id: com.turnover.settings
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 8 November 2026; synthetic slider notification regressions and installed Rate listening trial on macOS 27.2, Xcode 27.2; Windows keyboard style, TurnOver leading.

## Findings

The module handles labels and Tab order in TurnOver’s Settings window. Move between sidebar sections and controls with Tab and Shift-Tab, and check their names and current values.

Rate changes on macOS 27.2, TurnOver 2.0 build 23, produced three slider value-change events and speech requests for one arrow. The labelled Settings object now suppresses repeated identical numeric values and descriptions while focused. Real value changes, description updates, focus reentry and other controls retain their feedback. This is confined to the Settings module.

## Evidence

[App implementation](TurnOverSettingsAppModule.swift). Record the tested tasks and setup here when assessing support.

[Slider regression tests](../../TurnOverTests/TurnOverSettingsTests.swift): nine synthetic cases cover repeated notifications, rapid changes and reversal, formatted values, focus changes, separate sliders, unavailable values and non-slider controls. No private window content is recorded. The reporter confirmed a successful installed Rate test. Live logs for one down-arrow and one up-arrow each show three slider notifications but only one speech request and audio start. Other slider and focus behaviors are covered synthetically; no additional live result is claimed.
