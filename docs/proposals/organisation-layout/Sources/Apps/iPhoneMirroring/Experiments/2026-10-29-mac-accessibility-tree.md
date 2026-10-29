# Reading the phone through the Mac accessibility tree

- Date: 29 October 2026.
- Investigation: Codex working with Oliver.
- Being worked on: Unclaimed
- Verdict: no usable phone content through the public routes sampled.

## Question

Can a third-party reader obtain native phone controls through the mirrored Mac window?

## What was done

Bounded Mac accessibility probes sampled the window, focus, child routes, hit testing and text access. Earlier samples included Mac VoiceOver on and off. The detailed record preserves each sample's conditions.

## Result

The Mac window's own controls were exposed. The phone surface did not yield usable controls or text through the routes sampled.

Static investigation found an accessibility channel and a private remote-content client check. That finding does not establish that the check alone caused the live results or that obtaining a particular entitlement would be sufficient.

## What would change the verdict

A reproducible native query returning actual phone controls in the same Mirroring configuration, or new evidence explaining how the semantic bridge is activated and accessed.

## Evidence

[Current investigation](Evidence/SUMMARY.md) and [static bridge findings](Evidence/SUMMARY.md).
