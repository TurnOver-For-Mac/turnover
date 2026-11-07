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

// The words a person hears or reads, listed by the compiler for the translations (Resources/Localizable.xcstrings,
// make-strings.py). build.sh sets TURNOVER_STRINGS; a folder per target, because the compiler names each list after its
// source file and the programs' main.swift lists overwrote one another in a shared folder (23 Oct 2026).
func translatable(_ target: String) -> [SwiftSetting] {
    guard let folder = Context.environment["TURNOVER_STRINGS"] else { return [] }
    return [.unsafeFlags(["-emit-localized-strings", "-emit-localized-strings-path", folder + "/" + target])]
}

// Shared Core, Views and Mac system integration use folder entries; new files there are discovered automatically.
// App implementations are listed individually; records, tests and experiments are excluded from production membership.
// Tools/check-migration.py validates this boundary without fixing it to one historical checkout.
let coreSources: [String] = [
    "Core",
    "Views",
    "System",
    "Apps/AppStore/AppStoreAppModule.swift",
    "Apps/AppStore/AppStoreFlat.swift",
    "Apps/AppStore/AppStoreModel.swift",
    "Apps/AppStore/AppStorePageBuilder.swift",
    "Apps/AppStore/AppStorePurchaseConfirmation.swift",
    "Apps/AppStore/AppStoreView.swift",
    "Apps/Books/BooksAppModule.swift",
    "Apps/Calculator/CalculatorAppModule.swift",
    "Apps/Calendar/CalendarAppModule.swift",
    "Apps/Catalog/Catalog.swift",
    "Apps/Chat/ChatAppModule.swift",
    "Apps/Chat/ChatView.swift",
    "Apps/Claude/ClaudeAppModule.swift",
    "Apps/Claude/ClaudeTranscript.swift",
    "Apps/Contacts/ContactsAppModule.swift",
    "Apps/Dock/DockAppModule.swift",
    "Apps/Excel/ExcelAppModule.swift",
    "Apps/Excel/ExcelNVDAKeys.swift",
    "Apps/FaceTime/FaceTimeAppModule.swift",
    "Apps/Finder/FinderAppModule.swift",
    "Apps/Freeform/FreeformAppModule.swift",
    "Apps/Games/Games.swift",
    "Apps/GoogleDocs/GoogleDocs.swift",
    "Apps/Keynote/KeynoteAppModule.swift",
    "Apps/Kindle/KindleAppModule.swift",
    "Apps/Mail/MailAppModule.swift",
    "Apps/Maps/MapsAppModule.swift",
    "Apps/Media/MediaAppModule.swift",
    "Apps/Media/MediaShelfReadiness.swift",
    "Apps/Media/MediaSidebarSelection.swift",
    "Apps/Media/MediaView.swift",
    "Apps/Media/MediaWorkOwner.swift",
    "Apps/Numbers/NumbersAppModule.swift",
    "Apps/Pages/PagesAppModule.swift",
    "Apps/Panes/PanesAppModule.swift",
    "Apps/Photos/PhotosAppModule.swift",
    "Apps/Preview/PreviewAppModule.swift",
    "Apps/Reminders/RemindersAppModule.swift",
    "Apps/Safari/SafariAppModule.swift",
    "Apps/Safari/SafariReplyEnvironment.swift",
    "Apps/Shortcuts/ShortcutsAppModule.swift",
    "Apps/Spotify/SpotifyAppModule.swift",
    "Apps/Spotlight/SpotlightAppModule.swift",
    "Apps/SystemSettings/SystemSettingsAppModule.swift",
    "Apps/SystemSettings/SystemSettingsLabels.swift",
    "Apps/SystemSettings/SystemSettingsParts.swift",
    "Apps/Terminal/TerminalAppModule.swift",
    "Apps/TextEdit/TextEditFormatting.swift",
    "Apps/TurnOverSettings/TurnOverSettingsAppModule.swift",
    "Apps/Ulysses/UlyssesFormatting.swift",
    "Apps/Ulysses/UlyssesFormattingSyntax.swift",
    "Apps/Word/WordAppModule.swift",
    "Apps/Word/WordDocument.swift",
    "Apps/Word/WordHeaderFooter.swift",
    "Apps/Word/WordScripting.swift",
    "Apps/Word/WordSpelling.swift",
    "Apps/Word/WordTableCell.swift",
    "Apps/Word/WordTableNavigation.swift",
    "Apps/Word/WordTextArea.swift",
    "Apps/Word/WordTextInfo.swift",
]

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
            path: "Sources",
            exclude: [
                "AXFixtures",
                "AXReplayShim",
                "PluginTestKit",
                "TurnOver",
                "TurnOverAX",
                "TurnOverBraille",
                "TurnOverControl",
                "TurnOverCoreTest",
                "TurnOverKey",
                "TurnOverObjC",
                "TurnOverPlugin",
                "TurnOverProbe",
                "TurnOverSettings",
                "TurnOverSpeech",
                "TurnOverTests",
                "README.md",
                "Core/README.md",
                "Views/README.md",
                "Experiments",
                "System/README.md",
                // BEGIN GENERATED APP EXCLUDES (Tools/build-app-index.py)
                "Apps/ActivityMonitor/Experiments",
                "Apps/ActivityMonitor/STATUS.md",
                "Apps/AppFlowy/Experiments",
                "Apps/AppFlowy/STATUS.md",
                "Apps/AppStore/Experiments",
                "Apps/AppStore/STATUS.md",
                "Apps/AppleGames/Experiments",
                "Apps/AppleGames/STATUS.md",
                "Apps/Audacity/Experiments",
                "Apps/Audacity/STATUS.md",
                "Apps/Audible/Experiments",
                "Apps/Audible/STATUS.md",
                "Apps/BambuStudio/Experiments",
                "Apps/BambuStudio/STATUS.md",
                "Apps/Books/Experiments",
                "Apps/Books/STATUS.md",
                "Apps/Byword/Experiments",
                "Apps/Byword/STATUS.md",
                "Apps/Calculator/Experiments",
                "Apps/Calculator/STATUS.md",
                "Apps/Calendar/Experiments",
                "Apps/Calendar/STATUS.md",
                "Apps/Catalog/README.md",
                "Apps/Chat/README.md",
                "Apps/Chrome/Experiments",
                "Apps/Chrome/STATUS.md",
                "Apps/Claude/STATUS.md",
                "Apps/Clock/Experiments",
                "Apps/Clock/STATUS.md",
                "Apps/Console/Experiments",
                "Apps/Console/STATUS.md",
                "Apps/Contacts/Experiments",
                "Apps/Contacts/STATUS.md",
                "Apps/Cyberduck/Experiments",
                "Apps/Cyberduck/STATUS.md",
                "Apps/Discord/Experiments",
                "Apps/Discord/STATUS.md",
                "Apps/DiskUtility/Experiments",
                "Apps/DiskUtility/STATUS.md",
                "Apps/Dock/STATUS.md",
                "Apps/Dropbox/Experiments",
                "Apps/Dropbox/STATUS.md",
                "Apps/Edge/Experiments",
                "Apps/Edge/STATUS.md",
                "Apps/Excel/Experiments",
                "Apps/Excel/STATUS.md",
                "Apps/FaceTime/STATUS.md",
                "Apps/Finder/Experiments",
                "Apps/Finder/STATUS.md",
                "Apps/Firefox/Experiments",
                "Apps/Firefox/STATUS.md",
                "Apps/Freeform/Experiments",
                "Apps/Freeform/STATUS.md",
                "Apps/Games/README.md",
                "Apps/GarageBand/Experiments",
                "Apps/GarageBand/STATUS.md",
                "Apps/GoogleDocs/README.md",
                "Apps/Home/Experiments",
                "Apps/Home/STATUS.md",
                "Apps/IntelliJIDEA/Experiments",
                "Apps/IntelliJIDEA/STATUS.md",
                "Apps/Journal/Experiments",
                "Apps/Journal/STATUS.md",
                "Apps/KeePassXC/Experiments",
                "Apps/KeePassXC/STATUS.md",
                "Apps/Keynote/STATUS.md",
                "Apps/Kindle/STATUS.md",
                "Apps/Libation/Experiments",
                "Apps/Libation/STATUS.md",
                "Apps/LibreOffice/Experiments",
                "Apps/LibreOffice/STATUS.md",
                "Apps/LocalSend/Experiments",
                "Apps/LocalSend/STATUS.md",
                "Apps/Mail/Experiments",
                "Apps/Mail/STATUS.md",
                "Apps/Maps/STATUS.md",
                "Apps/Media/README.md",
                "Apps/Messages/Experiments",
                "Apps/Messages/STATUS.md",
                "Apps/MuseScore/Experiments",
                "Apps/MuseScore/STATUS.md",
                "Apps/Music/Experiments",
                "Apps/Music/STATUS.md",
                "Apps/Notes/Experiments",
                "Apps/Notes/STATUS.md",
                "Apps/Numbers/STATUS.md",
                "Apps/OBS/Experiments",
                "Apps/OBS/STATUS.md",
                "Apps/Obsidian/Experiments",
                "Apps/Obsidian/STATUS.md",
                "Apps/Outlook/Experiments",
                "Apps/Outlook/STATUS.md",
                "Apps/PDFsam/Experiments",
                "Apps/PDFsam/STATUS.md",
                "Apps/Pages/STATUS.md",
                "Apps/Panes/README.md",
                "Apps/Passwords/Experiments",
                "Apps/Passwords/STATUS.md",
                "Apps/Photos/STATUS.md",
                "Apps/Podcasts/Experiments",
                "Apps/Podcasts/STATUS.md",
                "Apps/Preview/Experiments",
                "Apps/Preview/STATUS.md",
                "Apps/QuickTime/Experiments",
                "Apps/QuickTime/STATUS.md",
                "Apps/README.md",
                "Apps/REAPER/Experiments",
                "Apps/REAPER/STATUS.md",
                "Apps/Reminders/Experiments",
                "Apps/Reminders/STATUS.md",
                "Apps/Safari/Experiments",
                "Apps/Safari/STATUS.md",
                "Apps/ScriptEditor/Experiments",
                "Apps/ScriptEditor/STATUS.md",
                "Apps/Shortcuts/Experiments",
                "Apps/Shortcuts/STATUS.md",
                "Apps/Slack/Experiments",
                "Apps/Slack/STATUS.md",
                "Apps/Spotify/Experiments",
                "Apps/Spotify/STATUS.md",
                "Apps/Spotlight/STATUS.md",
                "Apps/Steam/STATUS.md",
                "Apps/Stocks/Experiments",
                "Apps/Stocks/STATUS.md",
                "Apps/SystemSettings/Experiments",
                "Apps/SystemSettings/STATUS.md",
                "Apps/TV/Experiments",
                "Apps/TV/STATUS.md",
                "Apps/Terminal/Experiments",
                "Apps/Terminal/STATUS.md",
                "Apps/TextEdit/Experiments",
                "Apps/TextEdit/STATUS.md",
                "Apps/TextEdit/Tests",
                "Apps/Thunderbird/Experiments",
                "Apps/Thunderbird/STATUS.md",
                "Apps/Tips/Experiments",
                "Apps/Tips/STATUS.md",
                "Apps/TurnOverSettings/STATUS.md",
                "Apps/Ulysses/Experiments",
                "Apps/Ulysses/STATUS.md",
                "Apps/VSCode/Experiments",
                "Apps/VSCode/STATUS.md",
                "Apps/VoiceMemos/Experiments",
                "Apps/VoiceMemos/STATUS.md",
                "Apps/Weather/Experiments",
                "Apps/Weather/STATUS.md",
                "Apps/WhatsApp/Experiments",
                "Apps/WhatsApp/STATUS.md",
                "Apps/Word/Experiments",
                "Apps/Word/STATUS.md",
                "Apps/Xcode/Experiments",
                "Apps/Xcode/STATUS.md",
                "Apps/Zoom/Experiments",
                "Apps/Zoom/STATUS.md",
                "Apps/iPhoneMirroring/Experiments",
                "Apps/iPhoneMirroring/STATUS.md",
                "Apps/iTerm2/Experiments",
                "Apps/iTerm2/STATUS.md",
                // END GENERATED APP EXCLUDES
            ],
            sources: coreSources,
            swiftSettings: [.defaultIsolation(MainActor.self)] + translatable("TurnOverCore"),
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
            swiftSettings: [.defaultIsolation(MainActor.self)] + translatable("TurnOver"),
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
            swiftSettings: translatable("TurnOverSettings"),
            linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation")]
        ),
        // Command+Control+T starts and quits TurnOver: a tiny login-item helper inside TurnOver.app.
        .executableTarget(
            name: "TurnOverKey",
            dependencies: ["TurnOverControl", "TurnOverObjC"],
            path: "Sources/TurnOverKey",
            swiftSettings: [.defaultIsolation(MainActor.self)] + translatable("TurnOverKey"),
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
