# Portable Mirroring evidence

Selected results from the 29 October 2026 investigation. This is a small evidence pack for the layout demonstration, not the full investigation archive or a new test.

Read [the findings and limitations](SUMMARY.md) before interpreting individual result flags.

## Included results

- [Ordinary native service lookup](native-paired-ax-service-result.json): found the matching connected phone, but did not obtain the AX service object.
- [Signed system-tool discovery](native-paired-remotectl-result.json): listed both accessibility services on the matched wireless connection.
- [Modern transport attempt](native-paired-netcat-dtx-result.json): failed before DTX negotiation or an AX request.
- [Modern transport follow-up](native-paired-netcat-dtx-diagnostic-result.json): classified socket connection failure; no underlying error number established.
- [Legacy transport attempt](native-paired-shim-capabilities-result.json): no check-in reply or capability query.
- [USB Calculator clear](turnover-iphone-dtx-calculator-clear-result.json): controlled native press and zero display postcondition verified.
- [USB Calculator seven](turnover-iphone-dtx-calculator-native7-verified-result.json): controlled native press and zero-to-seven change verified; subscription-stop cleanup was not confirmed.

## Provenance and privacy

These seven JSON files are byte-for-byte copies of the same filenames from the investigation's diagnostics directory. [SHA256SUMS.txt](SHA256SUMS.txt) records their hashes. The original investigation remains unchanged.

Every string value was inspected. No device identifier values, network endpoint addresses, account details, user filesystem paths or private app content are included. UUID and IP-related keys describe types or matching outcomes, not actual values. Calculator label values are fixed public control names and digits from the disposable test.

No raw logs, probe scripts or third-party source code are included. The full original archive needs its own sanitisation, licence and provenance review before migration or publication; this pack does not replace it.

## Diagnostic boundary

The signed remotectl experiments used an Apple system tool with additional private entitlements. That distinguishes their results from an ordinary third-party client. They found services, but did not establish working wireless accessibility reading. These are diagnostic observations, not an approved integration or a proposal to ship TurnOver using Apple's privileged tool.
