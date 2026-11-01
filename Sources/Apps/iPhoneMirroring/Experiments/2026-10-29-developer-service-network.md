# Native accessibility service discovery without the cable

- Date: 29 October 2026.
- Investigation: Codex working with Oliver.
- Being worked on: Unclaimed
- Verdict: wireless discovery succeeded; opening the advertised service sockets failed.

## Question

Can native phone accessibility be reached over the existing paired wireless connection?

## What was done

Earlier Bonjour, usbmux and named-service attempts did not reach accessibility. A later native pairing assertion identified the matched phone with transport reported as network. Apple's signed diagnostic tool advertised both modern and legacy accessibility services. Bounded connection attempts then tested those service sockets.

## Result

Both socket attempts failed before remote accessibility communication. No phone controls or text were read over these connections. Test resources were cleaned up.

The earlier error 4000 was a generic connection failure, not proof of an entitlement denial. An ordinary client's empty service list did not establish that the services were absent: the signed tool subsequently listed them.

The recorded lock metadata did not establish the current physical lock state for every sample. Neither a working locked Mirroring session nor a locked-phone accessibility rejection was demonstrated.

## What would change the verdict

A specific explanation and reproducible resolution of the socket-opening failure, or a separately verified native transport that returns phone accessibility in the intended Mirroring configuration.

## Evidence

[Current investigation and result-file links](Evidence/SUMMARY.md) and [CoreDevice error interpretation](Evidence/SUMMARY.md).

## Diagnostic boundary

Apple’s signed remotectl tool has additional private entitlements. Its discovery result did not demonstrate ordinary TurnOver access, and socket attempts failed before accessibility reading. Depending on its privileged access is not proposed as a product route.
