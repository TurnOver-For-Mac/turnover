# Driving the phone's VoiceOver through Mirroring

- Date: 29 October 2026.
- Tester: Oliver, with Codex investigation and instructions.
- Being worked on: Unclaimed
- Verdict: both completed keyboard trials produced no response.

## Question

Can Mirroring's keyboard input control VoiceOver running on the physical iPhone?

## What was done

Oliver first tried TurnOver's one-key pass-through followed by Control-Option-Right Arrow. He then tried Mirroring in TurnOver Direct mode with Control-Option-K for phone VoiceOver keyboard help and restored normal mode afterward.

## Result

Oliver reported nothing happened in either test. Logs corroborated entry to and exit from Direct mode. The actual command delivery to the phone remains unverified.

The separate observation that Command-1 through Command-4 caused speech from the physical iPhone did not establish VoiceOver chord forwarding. System gestures and ordinary keyboard input can use different paths.

No working keyboard fallback was demonstrated. The results do not prove universal lack of support or intentional exclusion. No test answer is pending from these trials.

## What would change the verdict

New evidence identifying the input path or a reproducible configuration in which a VoiceOver command reaches and controls the phone. Repeating the same gestures without a new hypothesis is not the next step.

## Evidence

[Current investigation](Evidence/SUMMARY.md), [pass-through audit](Evidence/SUMMARY.md) and [keyboard path findings](Evidence/SUMMARY.md).
