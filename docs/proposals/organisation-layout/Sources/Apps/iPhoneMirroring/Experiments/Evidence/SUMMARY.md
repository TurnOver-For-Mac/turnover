# Mirroring findings and limitations

Summary prepared from the existing investigation records on 29 October 2026. No new live test was performed for this portable pack.

## Overall result

No working TurnOver adapter for native mirrored-phone content was demonstrated or installed. The Mac window's own controls were accessible. OCR is excluded at Oliver's request.

The tested setups differ. Success on an unlocked USB-connected phone is not success in a locked wireless Mirroring session.

## Mac accessibility

The bounded Mac probes found the window controls and an empty phone-content placeholder through the tested routes, including samples with Mac VoiceOver on and off. This does not establish that every public accessibility route is exhausted.

Static analysis found a real remote-content-capable client check. It did not prove that this check alone caused the observed empty tree, that all native alternatives are impossible, or that TurnOver could use Apple's private capability.

Source records: the original investigation README.md, previous-findings-2026-10-29.txt and native-bridge-evidence.md. Those full records are not reproduced in this minimal pack.

## USB Calculator

On the unlocked phone over USB, the diagnostic obtained 24 native Calculator elements with frames. A controlled All Clear press verified zero; a controlled Seven press verified the display changing from zero to seven. The two included Calculator result files support those limited outcomes.

The Seven result records a failed subscription-stop acknowledgement and a cleanup-unconfirmed status, despite its connection and tunnel closed flags. Do not simplify that record to “all cleanup confirmed.” These tests did not establish a locked-phone accessibility rejection or working Mirroring support.

## Wireless discovery and transport

The ordinary native lookup found the matched, connected phone, but returned no AX service object. Later discovery through Apple's signed remotectl tool listed both modern and legacy AX service names. Therefore the earlier empty result is not evidence that the services were absent.

Both transport attempts stopped at socket connection failure. The modern service failed before DTX negotiation; the legacy service received no RSD check-in reply and never requested capabilities. No wireless AX content or phone action resulted. Some result fields retain default false values for checks not run; read them with the recorded method and stage, not as global absence claims.

An earlier CoreDevice error 4000 was classified as generic connection failure. It did not establish an entitlement denial. The current physical lock and Mirroring foreground state were not established by every transport sample.

The signed system tool carries additional private entitlements. Its diagnostic discovery does not demonstrate ordinary TurnOver access or a shippable route. Relying on its privileged access is not proposed as product implementation.

## Phone VoiceOver keyboard trials

Oliver reported no response to either one-key pass-through navigation or Direct-mode keyboard help. Log review corroborated entering and restoring Direct mode. Actual delivery of the commands to iPhone remained unverified; phone modifier configuration, focus and Mirroring forwarding were not eliminated as possible factors.

Source records: the original investigation README.md, one-shot-pass-through-audit.md and keyboard-pass-through-findings.md. The original README's later outcome supersedes the earlier audit's pending-test wording. No raw input logs are included here.

Mac VoiceOver reading actual mirrored-phone content remains a separate unverified question. There is no pending answer from the completed phone keyboard trials.

## When to investigate again

Require a specific new hypothesis or changed condition, such as an explanation of socket failure or verified native semantic access in the same Mirroring configuration. Preserve the distinction between discovery, transport, content reading and action verification.
