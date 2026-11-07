# Spotify

- Bundle id: `com.spotify.client`
- Support: Partial
- Effort: Module
- Being worked on: eleganckidenis, [#226](https://github.com/TurnOver-For-Mac/turnover/issues/226)
- Checked: 15 October 2026; setup details are in the linked evidence.

## Findings

The sign-in screen read by Tab. No account was used for further testing, so library navigation, search and playback were not assessed.

Spotify 1.3.6 on macOS 26.6.2: #226 records the volume shortcut conflict and the missing speech when the volume changes. The module forwards Command with an arrow and announces the requested playback command. Volume feedback also plays at the volume limits. The four shortcuts passed a listening trial on macOS 26.6.2.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md).
