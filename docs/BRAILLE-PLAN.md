# Braille plan (started 6 Oct 2026)

Three testers need braille (one for coding, one for university, one for Terminal and MathML). Today VoiceOver
drives the display, so braille stops when TurnOver takes over. Tested with a 20-cell BAUM display,
USB and Bluetooth.

## The VarioUltra
- USB: vendor 0x0904, product 0x6101 (20 cells), 0x6102 (40), 0x6103 (32). Interface 0 is HID, but carries BAUM's
  own protocol tunnelled through HID reports, not the standard HID braille usage page (BRLTTY's usb_devices.c and
  its "bm" driver). So TurnOver can reach it with IOHIDManager, no driver needed, speaking BAUM's protocol.
- Bluetooth: to check on the device (serial-style RFCOMM or HID).

## Steps
1. **Probe (the display plugged in by USB).** List the HID device; check whether macOS's braille service holds it while
   VoiceOver is on and lets go when VoiceOver is off; write a test pattern; read the keys and routing buttons.
2. **Display layer in the core** (NVDA's braille.BrailleDisplayDriver shape): a driver per protocol, found by USB
   ids. First BAUM over USB, then the standard HID braille page (covers most newer displays: Focus, Brailliant,
   Orbit and others), then Bluetooth.
3. **What is shown** (NVDA's braille.handler): the focus object's region and the line under the caret or review
   cursor; panning keys; routing buttons move the caret or activate; tethered to focus or review.
4. **Translation.** Computer braille (8-dot, one cell per character) first, with TurnOver's own table. Then contracted
   braille and other languages through liblouis (LGPL-2.1+: link it dynamically, ship its notice).
5. **Hand-over.** TurnOver takes the display when it leads and releases it when VoiceOver comes back, so VoiceOver's
   braille resumes.

## Licences
BRLTTY is LGPL. Use it to learn the protocol facts (ids, report layout, commands); write TurnOver's own driver from
those facts, as with the NVDA rewrites (ESCALATIONS E13).

## Built so far (6 Oct 2026, before the display was charged)
- `Sources/TurnOverCore/Braille/`: `BrailleTable` (8-dot computer braille, accented letters as the plain letter plus
  dot 8), `Braille` (what is shown: the caret line in browse mode and editable text, else the focus object;
  messages for 4 s; panning on to the next and previous line; routing moves the caret, and in browse mode activates
  a link or button; an object's routing key presses it), `BaumHID` (finds BAUM displays while TurnOver leads,
  closes them when it hands back; writes 0x01 + cells; reads routing, display keys, joystick and entry keys,
  acting when all keys are up so chords work; logs the first 40 reports in full).
- Hooks: Core.activate/deactivate, after every event and script, and Speech.speakMessage.
- Tested with a pretend 20-cell display on a test page (`turnover-coretest --web --pid N --braille`): lines, cursor,
  panning across and between lines, routing.
- Not yet installed. Next, with the VarioUltra by USB: run ~/Library/Developer/TurnOver/tools/brailleprobe, then the
  build, and read the log's "braille:" lines to fix the report layout, key names (d1 to d6, joystick values) and
  whether VoiceOver lets go of the display.

## Apple's drivers and tables (6 Oct 2026, later)
- Displays go through macOS's own drivers (TOAppleBraille in Sources/TurnOverBraille: finds the display from each
  driver's autodetect list, loads it, writes cells, polls key events, reads the model's key table). TurnOver's own
  BAUM driver is the fallback. Text goes through macOS's own translator (BRLTServiceTranslator: Duxbury, liblouis
  and Apple tables), both ways.
- Settings now (Preferences, Braille): table; contracted or letter-by-letter typing; spoken typing echo; show
  messages and message time; avoid splitting words; cursor shown, blinking, blink rate, shape; selection with
  dots 7-8; stop speech while panning; word at the cursor uncontracted.
- Typing: contracted words show as raw cells at the cursor until space or Return translates them.

## Still to match NVDA and VoiceOver
- Space-with-dots commands (VoiceOver's layout first), and the top keys 4 and 6.
- Focus context (NVDA: fill the display with the item's container, "list, 3 of 7"), tethering to the review cursor,
  reading by paragraph, a separate input table.
- VoiceOver's status cells and text style marking (bold, links) in braille.
- Bluetooth (BLE and serial drivers: SCROIOSerialElement, the autodetector's BLE path).

## Release groundwork (28 Oct 2026, issue 160)

`TOAppleBrailleDisplay.closeWithCompletion` requests release and returns without waiting on the braille thread.
The locked `releaseState` snapshot never calls the driver. Open becomes pending immediately, rejecting new writes
and polls; the existing driver-thread guard lets the in-flight call return before blanking and unloading. Every
completion runs on main after that attempt: released only when `unloadDriver` returns YES, failed when it returns NO.
A failed session retains the display, bundle and driver for the process lifetime, with no further driver calls or
retries. This intentional quarantine prevents ARC from destroying a potentially live driver on another thread.
A driver that never returns stays pending and retained. No timeout establishes release.

This is preparatory API work. The Swift adapter, display manager and hand-over callers still use synchronous
`close`, which can wait indefinitely for the attempt. Synchronous callers now retain failed sessions and can inspect
`releaseState`; they have not yet been changed to gate on it. The idle `dealloc` fallback also still waits on the
owning driver thread. No physical display or VoiceOver hand-over has been tested for this change.

Before adopting the asynchronous API, the display manager must retain closing sessions and prevent scans and
replacement drivers until every relevant release is confirmed. Delayed Bluetooth detection needs a generation
check: a result arriving after stop must itself be released before the stop can be considered complete. A pending
or failed release must not be treated as permission to reopen, or to start VoiceOver's display driver.

TurnOver-originated VoiceOver-on requests need a release gate in `LeadWatcher` before posting the toggle; the
current path can turn VoiceOver on before observing it and deactivating TurnOver. Normal quit also needs an
asynchronous termination gate. Manual VoiceOver changes and signal/watchdog recovery need a separate agreed
policy: in-process code cannot force a stuck private driver to relinquish its hardware safely. A separate driver
service is a possible later containment design, requiring USB/Bluetooth, signing and permission investigation.
These caller changes need maintainer and braille-user review, especially the policy for a release that never finishes.
