# Mail

- Bundle id: com.apple.mail
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Down/Up and movement to the mailbox and message lists reached the expected Mail handlers. All four assertions are command-dispatch checks. Message text, useful spoken list output and composing were not asserted by this scenario. The 29 October public-message probe established provider structure, not a listening result.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](MailAppModule.swift).
