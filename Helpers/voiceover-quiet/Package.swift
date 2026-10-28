// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver quiet: while TurnOver reads, VoiceOver's sound is kept from the speakers; the moment TurnOver says "off",
// stops, or crashes, VoiceOver is heard again. Open, MIT, so anyone can see it does that and nothing else: it records
// nothing, saves nothing and sends nothing. TurnOver builds it from this source, signs it, and starts it.
import PackageDescription

let package = Package(
    name: "voiceover-quiet",
    platforms: [.macOS("14.2")],   // process taps came in macOS 14.2
    targets: [.executableTarget(name: "voiceover-quiet", path: "Sources/voiceover-quiet")]
)
