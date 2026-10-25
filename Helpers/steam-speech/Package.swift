// swift-tools-version:5.9
// SPDX-License-Identifier: GPL-3.0-or-later
// Steam speech's program: reads Steam's Big Picture (and Steam games built on Electron) and hands TurnOver the words.
// Open, MIT. TurnOver builds it from this source, signs it with TurnOver and starts it without TurnOver's permissions.
import PackageDescription

// TurnOver's build.sh sets TURNOVER_STRINGS: the program's words are listed for TurnOver's translations, beside
// TurnOver's own (its make-strings.py).
let translatable: [SwiftSetting] = Context.environment["TURNOVER_STRINGS"].map {
    [.unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path", $0 + "/steam-speech"])]
} ?? []

let package = Package(
    name: "steam-speech",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "steam-speech", path: "Sources/steam-speech", swiftSettings: translatable)]
)
