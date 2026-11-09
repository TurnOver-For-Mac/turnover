// SPDX-License-Identifier: GPL-3.0-or-later
// Help make TurnOver (9 Nov 2026, Oliver: "a panel to open talking about how you can contribute, pointing to letting
// us know what works and doesn't work, all the way through to contributing. It's a call to action to really get this
// open sourced"). One page, read with the arrows like the welcome's: the ways to help, from a sentence of feedback to
// writing code, then a button that opens TurnOver on GitHub. It opens by itself once, at the end of the welcome after
// an update and at the end of a new user's first welcome; the TurnOver menu's Help opens it again any time.
import Foundation

public enum HelpMakeTurnOver {
    public static let githubURL = URL(string: "https://github.com/TurnOver-For-Mac/turnover")!
    public static let discordAddress = "discord.gg/6AsrUXwRgV"

    /// Set once the page has opened with a welcome, so it opens by itself only once on this Mac.
    static let shownKey = "helpMakeTurnOverShown"
    public static var due: Bool { !UserDefaults.standard.bool(forKey: shownKey) }
    public static func markShown() { UserDefaults.standard.set(true, forKey: shownKey) }

    /// Opens the page by itself (the TurnOver menu's Help). Set by the app, which owns the welcome window.
    nonisolated(unsafe) public static var show: (@MainActor () -> Void)?

    public static var title: String {
        String(localized: "Help make TurnOver", comment: "The title of the page about the ways to help TurnOver (a welcome page, and an item in the TurnOver menu's Help)")
    }

    /// One point a line, as the welcome pages have them, read with Up and Down.
    public static var body: String {
        [
            String(localized: "TurnOver is free and open source. It gets better when the people who use it say what works and what doesn't.", comment: "Help make TurnOver: the first line"),
            String(localized: "Tell us how it's going, good or bad: Tools, then Send feedback, in the TurnOver menu. A sentence is enough.", comment: "Help make TurnOver: feedback"),
            String(localized: "Something wrong in one app: This app, then Help improve this app, in the TurnOver menu. A form opens, already filled in for that app.", comment: "Help make TurnOver: reporting a problem with an app"),
            String(localized: "Fix an item yourself: Fix the item I'm on, in Help improve this app, gives it a name or a key. With VoiceOver keys, VO-Slash does the same. Share your fix, and everyone who uses that app gets it.", comment: "Help make TurnOver: fixing an item"),
            String(localized: "Teach TurnOver a whole app with your own AI assistant, such as Claude Code or Codex. Help improve this app starts it for you.", comment: "Help make TurnOver: building an app's module with an AI assistant"),
            String(localized: "Translate TurnOver into your language. The Turkish and Russian translations came from people who use it.", comment: "Help make TurnOver: translating"),
            String(localized: "Write code: TurnOver is on GitHub, and CONTRIBUTING.md there is the place to start.", comment: "Help make TurnOver: contributing code"),
            String(localized: "Talk with other people who use TurnOver on its Discord, at \(discordAddress).", comment: "Help make TurnOver: the Discord server; the argument is its address"),
            String(localized: "If you've found Discord hard going, it reads better with TurnOver on the Mac.", comment: "Help make TurnOver: Discord reads better with TurnOver"),
            String(localized: "Open TurnOver on GitHub, below, to make a start. This page is in the TurnOver menu, under Help, as Help make TurnOver.", comment: "Help make TurnOver: the last line, before the buttons"),
        ].joined(separator: "\n")
    }

    public static var page: (String, String) { (title, body) }

    /// The page's own button, where the welcome's last page has Read the guide.
    public static var buttonTitle: String {
        String(localized: "Open TurnOver on GitHub", comment: "The button on the Help make TurnOver page")
    }
}
