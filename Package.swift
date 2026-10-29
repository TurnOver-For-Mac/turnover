// swift-tools-version: 6.2
// TurnOver, a screen reader for macOS that works alongside VoiceOver. Copyright 2026 Oliver Kennett and contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// TurnOverAX        the thin layer over the HIServices accessibility client API
// TurnOverSpeech    the reader's own speech path (renderer + player)
// TurnOverBraille   braille displays
// TurnOverControl   the control channel: a local socket only TurnOver's own signed programs may use
// TurnOverCore      the screen reader proper, as a dynamic library: objects, text ranges, gestures and scripts,
//                   events, speech, app modules, global plugins, global commands
// turnover          the app (LSUIElement; build.sh wraps it in a bundle): the Mac keyboard layer, the VoiceOver
//                   hand-over, the built-in app modules
// turnover-key      TurnOver Key, the login item: Command Control Period, and a restart after a crash
// turnover-settings TurnOver's settings window
// turnover-plugin   the plugin tool (making and checking app plugins)
// turnover-tests    the unit tests (build.sh runs them); turnover-coretest the live and fixture tests
// AXFixtures, PluginTestKit   recorded accessibility trees and the plugin test kit, for the tests
// turnover-probe    measurement probes, run by hand
import PackageDescription

let package = Package(
    name: "TurnOver",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TurnOverAX", targets: ["TurnOverAX"]),
        .library(name: "TurnOverSpeech", targets: ["TurnOverSpeech"]),
        .library(name: "TurnOverCore", type: .dynamic, targets: ["TurnOverCore"]),
        .executable(name: "turnover", targets: ["TurnOver"]),
        .executable(name: "turnover-probe", targets: ["TurnOverProbe"]),
        .executable(name: "turnover-coretest", targets: ["TurnOverCoreTest"]),
        .executable(name: "turnover-plugin", targets: ["TurnOverPlugin"]),
        .executable(name: "turnover-key", targets: ["TurnOverKey"]),
        .executable(name: "turnover-settings", targets: ["TurnOverSettings"]),
        .executable(name: "turnover-tests", targets: ["TurnOverTests"]),
        // Dynamic: dyld honours interposing only in a library loaded at launch, never in the executable itself.
        .library(name: "AXReplayShim", type: .dynamic, targets: ["AXReplayShim"]),
    ],
    dependencies: [
        // Updates (Sparkle 2): checks a signed feed, downloads, verifies and installs. Releases are signed with the maintainer's private release tooling.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "TurnOverAX",
            path: "Sources/TurnOverAX",
            linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
        ),
        // Objective-C's exception catching, which Swift lacks (TOCatch: the audio device going mid-play).
        .target(name: "TurnOverObjC", path: "Sources/TurnOverObjC"),
        .target(
            name: "TurnOverSpeech",
            dependencies: ["TurnOverObjC"],
            path: "Sources/TurnOverSpeech",
            linkerSettings: [.linkedFramework("AVFoundation"), .linkedFramework("AudioToolbox")]
        ),
        // TurnOver's control channel: a local socket that only programs signed by TurnOver's developer may use
        // (Settings, TurnOver Key, the plugin tool, Windy). No other dependencies, so every one of them can link it.
        .target(
            name: "TurnOverControl",
            path: "Sources/TurnOverControl",
            linkerSettings: [.linkedFramework("Security")]
        ),
        // macOS's own braille display drivers, reached from Objective-C (docs/BRAILLE-PLAN.md).
        .target(
            name: "TurnOverBraille",
            path: "Sources/TurnOverBraille",
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOKit"), .linkedFramework("IOBluetooth")]
        ),
        .target(
            name: "TurnOverCore",
            dependencies: ["TurnOverAX", "TurnOverSpeech", "TurnOverBraille", "TurnOverControl"],
            path: "Sources/TurnOverCore",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Vision"),
                // Weak: the on-device model is macOS 26 and later; TurnOver runs from macOS 14 (image descriptions).
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .executableTarget(
            name: "TurnOver",
            dependencies: ["TurnOverCore", "TurnOverControl", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/TurnOver",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                // The app bundle carries libTurnOverCore.dylib in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // Replaying recorded accessibility trees without the applications (tests): a C shim that interposes the
        // HIServices calls, and the recording/replay model over it.
        .target(name: "AXReplayShim", path: "Sources/AXReplayShim", linkerSettings: [.linkedFramework("ApplicationServices")]),
        // A plugin's own tests, replayed (docs/PLUGIN-TOOLKIT-PLAN.md item 5): used by turnover-plugin test and turnover-tests.
        .target(name: "PluginTestKit", dependencies: ["TurnOverCore", "AXFixtures"], path: "Sources/PluginTestKit",
                swiftSettings: [.defaultIsolation(MainActor.self)],
                linkerSettings: [.linkedFramework("ApplicationServices")]),
        .target(name: "AXFixtures", path: "Sources/AXFixtures",
                linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]),
        // The unit tests: pure functions, and views against recorded trees (Tests/Fixtures). build.sh runs it.
        .executableTarget(
            name: "TurnOverTests",
            dependencies: ["TurnOverCore", "TurnOverSpeech", "TurnOverControl", "AXFixtures", "PluginTestKit"],
            path: "Sources/TurnOverTests",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
        ),
        // Exercises the core's text layer and script resolution against a running app, silently.
        .executableTarget(
            name: "TurnOverCoreTest",
            dependencies: ["TurnOverCore", "TurnOverSpeech", "AXFixtures"],
            path: "Sources/TurnOverCoreTest",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("ApplicationServices"), .linkedFramework("AppKit")]
        ),
        // TurnOver Settings: the settings in a window of its own, inside TurnOver.app (18 Oct 2026).
        .executableTarget(
            name: "TurnOverSettings",
            dependencies: ["TurnOverControl"],
            path: "Sources/TurnOverSettings",
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation")]
        ),
        // Command+Control+T starts and quits TurnOver: a tiny login-item helper inside TurnOver.app.
        .executableTarget(
            name: "TurnOverKey",
            dependencies: ["TurnOverControl", "TurnOverObjC"],
            path: "Sources/TurnOverKey",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon"), .linkedFramework("AVFoundation")]
        ),
        // The plugin maker's tool: brief, snapshot, check, install (PLUGIN-GUIDE.md). Ships inside TurnOver.app.
        .executableTarget(
            name: "TurnOverPlugin",
            dependencies: ["TurnOverCore", "TurnOverControl", "AXFixtures", "PluginTestKit"],
            path: "Sources/TurnOverPlugin",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "TurnOverProbe",
            dependencies: ["TurnOverAX", "TurnOverSpeech"],
            path: "Sources/TurnOverProbe",
            swiftSettings: [.defaultIsolation(MainActor.self)],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
