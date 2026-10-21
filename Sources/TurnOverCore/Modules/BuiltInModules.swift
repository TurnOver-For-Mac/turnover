// SPDX-License-Identifier: GPL-3.0-or-later
// The app modules TurnOver ships, registered in one place (8 Oct 2026: moved into TurnOverCore from the app, so
// turnover-coretest and the tests see the same modules as TurnOver does).
import Foundation

public enum BuiltInModules {
    public static func register() {
        let h = AppModuleHandler.shared
        h.register(WordAppModule.self, for: WordAppModule.bundleID)
        h.register(DockAppModule.self, for: "com.apple.dock")
        h.register(SpotlightAppModule.self, for: SpotlightAppModule.bundleID)
        h.register(TurnOverSettingsAppModule.self, for: TurnOverSettingsAppModule.bundleID)
        h.register(TerminalAppModule.self, for: TerminalAppModule.bundleID)
        // iTerm2's text is Terminal's shape (a text area described "shell", the same line queries): new output wasn't
        // read and Up said nothing (parts sweep, 14 Oct 2026).
        h.register(TerminalAppModule.self, for: "com.googlecode.iterm2")
        h.register(MailAppModule.self, for: MailAppModule.bundleID)
        h.register(SafariAppModule.self, for: SafariAppModule.bundleID)
        // Previews, off until turned on in the TurnOver menu (Applications).
        h.register(FinderAppModule.self, for: FinderAppModule.bundleID)
        h.register(ClaudeAppModule.self, for: ClaudeTranscript.bundleID)
        h.register(AppStoreAppModule.self, for: AppStoreAppModule.bundleID)
        h.register(ExcelAppModule.self, for: ExcelAppModule.bundleID)
        h.register(PreviewAppModule.self, for: PreviewAppModule.bundleID)
        h.register(KindleAppModule.self, for: KindleAppModule.bundleID)
        h.register(CalendarAppModule.self, for: CalendarAppModule.bundleID)
        h.register(PagesAppModule.self, for: PagesAppModule.bundleID)
        h.register(NumbersAppModule.self, for: NumbersAppModule.bundleID)
        h.register(KeynoteAppModule.self, for: KeynoteAppModule.bundleID)
        h.register(RemindersAppModule.self, for: RemindersAppModule.bundleID)
        h.register(ContactsAppModule.self, for: ContactsAppModule.bundleID)
        h.register(BooksAppModule.self, for: BooksAppModule.bundleID)
        h.register(CalculatorAppModule.self, for: CalculatorAppModule.bundleID)
        h.register(MapsAppModule.self, for: MapsAppModule.bundleID)
        h.register(FaceTimeAppModule.self, for: FaceTimeAppModule.bundleID)
        h.register(FreeformAppModule.self, for: FreeformAppModule.bundleID)
        h.register(ShortcutsAppModule.self, for: ShortcutsAppModule.bundleID)
        h.register(PhotosAppModule.self, for: PhotosAppModule.bundleID)
        registerRecipeApps()
    }

    /// The apps described by recipes (chat, media): again whenever the recipes load.
    /// The bundles registered from recipes last time: one gone (a plugin's view removed at a reload) is unregistered,
    /// or its next launch made a ChatAppModule with no recipe and trapped (code review, 16 Oct 2026).
    private static var fromRecipes: Set<String> = []
    public static func registerRecipeApps() {
        let h = AppModuleHandler.shared
        var now: Set<String> = []
        for b in Recipes.bundles(kind: "media") { h.register(MediaAppModule.self, for: b); now.insert(b) }
        for b in Recipes.bundles(kind: "chat") { h.register(ChatAppModule.self, for: b); now.insert(b) }
        for b in Recipes.bundles(kind: "panes") { h.register(PanesAppModule.self, for: b); now.insert(b) }
        for b in fromRecipes.subtracting(now) { h.unregister(bundleIdentifier: b); Log.info("recipes: \(b) has no recipe now; its module unregistered") }
        fromRecipes = now
    }
}
