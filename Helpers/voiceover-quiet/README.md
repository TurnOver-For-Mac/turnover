# voiceover-quiet

The small program TurnOver uses to keep VoiceOver quiet while TurnOver reads, published so anyone can check what it
does.

## What it does

While it's told "on", VoiceOver's sound (speech and sounds) is kept from the speakers. VoiceOver keeps running, so it
is ready the moment it's needed. Told "off", or when TurnOver stops for any reason, VoiceOver is heard again.

It uses macOS's audio process taps (macOS 14.2 and later): a tap on VoiceOver's process, set to mute, run through a
private audio device whose only job is to throw the audio away.

## What it doesn't do

It records nothing, saves nothing, analyses nothing and sends nothing. It has no network code. The audio callback is
empty. The whole program is one file: `Sources/voiceover-quiet/main.swift`.

## How TurnOver talks to it

One word a line on standard input: `on`, `still`, `off`, `quit`. It answers `on`, `off` or `error <what>`. When
TurnOver's end of the pipe closes, it stops, and VoiceOver is heard. While VoiceOver is silent TurnOver sends `still`
every second; if three seconds pass without it (TurnOver frozen), VoiceOver is heard until TurnOver speaks again.

## Building

    swift build -c release

`voiceover-quiet --self-test` checks it can reach Core Audio, without silencing anything.

MIT licence.
