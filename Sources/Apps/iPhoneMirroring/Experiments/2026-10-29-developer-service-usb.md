# Reading native phone accessibility over USB

- Date: 29 October 2026.
- Investigation: Codex working with Oliver.
- Being worked on: Unclaimed
- Tools included pymobiledevice3 11.10.2 and the ipb protocol codec.
- Verdict: controlled Calculator test worked with the phone unlocked and connected by USB.

## Question

Can the developer accessibility service expose native controls and accept actions on the phone?

## What was done

With Calculator open on the unlocked phone and the USB connection present, read the native elements and perform controlled All Clear and Seven button tests.

## Result

The test read 24 native elements and verified both button actions. This established a controlled USB diagnostic capability, not working wireless Mirroring support.

The later failed connection attempts did not demonstrate an accessibility request being rejected because the phone was locked. Their transport failures prevented that conclusion.

## What would change the verdict

Demonstrating native reads and actions in the intended wireless Mirroring configuration, with the actual connection, lock and foreground state recorded.

## Evidence

[Current investigation](Evidence/SUMMARY.md) and [historical detailed findings](Evidence/SUMMARY.md).

These were diagnostic dependencies, not new reader dependencies. pymobiledevice3 is GPLv3; the referenced ipb codec is MIT.
