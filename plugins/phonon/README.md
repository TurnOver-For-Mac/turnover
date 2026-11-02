# Phonon voice helper

TurnOver's natural voice for all speech, on the Mac that has it: Gradium's Phonon 31m (Apache 2.0) through FluidAudio
(Apache 2.0). It speaks the same pipes as the Kokoro helper in `../kokoro/helper`, and adds speed (WSOLA, at the same
pitch, from TurnOver's speech rate) and lifts Phonon to the Mac voices' level. The EQ and the volume are TurnOver's
speech player's, as for every voice.

Build it, sign it with the same Developer ID as TurnOver, and put it beside Kokoro's helper. Outside a developer's
build, TurnOver starts only a helper signed by its own developer team, so a program dropped in that folder hears
nothing. Remove the old file before copying: copying a newly signed program over the old one in place leaves macOS
holding the old signature, and it kills the new one as it starts.

```bash
cd plugins/phonon/helper && swift build -c release
codesign --force --sign "Developer ID Application: <your name> (<team>)" --identifier com.turnover.phonon-helper .build/release/phonon-helper
rm -f ~/Library/Developer/TurnOver/kokoro/phonon-helper && cp .build/release/phonon-helper ~/Library/Developer/TurnOver/kokoro/
```

TurnOver then offers Phonon's voices where the `kokoro` default is set: in Settings, Speech, Voice (one chosen speaks
everything, with the rate, volume and EQ above it, kept for each voice), in the rotor (In the rotor under Voice, or the list of voices below it), and in Natural voice
for say all only.

The first start downloads the voice (172 MB, FluidAudio's cache in `~/.cache/fluidaudio`); after that nothing leaves
the Mac. Measured on an M4 (2 Nov 2026): speech is ready 10 to 20 ms after a request; Kokoro's helper takes 40 to 120 ms.
