# Calculator

- Bundle id: com.apple.calculator
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; reader leadership and keyboard style unverified.

## Findings

The TurnOver menu-open and menu-close response checks passed while Calculator was frontmost. Reader leadership was not established, so this result does not verify handover. Calculator digits, operators, display reading and arithmetic were not tested.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](CalculatorAppModule.swift). Record Calculator and macOS versions, keyboard style and VoiceOver state with the result.
