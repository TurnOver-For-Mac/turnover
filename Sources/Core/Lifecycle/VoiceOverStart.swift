// SPDX-License-Identifier: GPL-3.0-or-later
// How VoiceOver is started when TurnOver wants it on outside a hand-over between apps: for the welcome's pages, as
// TurnOver quits, after an uninstall. The choice alone, apart from every system call, so a test can drive it.
//
// Its own shortcut first, when VoiceOver is wholly off: macOS starts it through its own service and the flag flips in
// about a tenth of a second (57 hand-overs measured from 10 to 20 Nov 2026: 89 ms in the middle, none failed).
// VoiceOver.app opened instead takes about ten seconds on macOS 27: VoiceOver sits that long before it logs that it
// "was not launched by UA daemon as expected" and gets going. The hand-over between apps went to the shortcut for
// that on 27 Oct 2026 (LeadWatcher). The welcome and the quit still opened the app first until 20 Nov 2026, when
// build 25's welcome sat unread for ten seconds on the maintainer's Mac and each quit left ten seconds with no reader.
//
// VoiceOver.app is still what starts it when the flag is on with no VoiceOver (quit by script, or crashed: the
// shortcut would turn the flag off), and when the shortcut did not bring it (it stopped reaching macOS on the
// maintainer's Mac on 23 Oct 2026). A VoiceOver that is coming or going (its process there, its flag off) is waited
// for, never added to: opened again in those seconds, it came no sooner.
import Foundation

nonisolated public enum VoiceOverStart {
    public enum Step: Equatable {
        /// Reading already: nothing to do.
        case nothing
        /// Wholly off: its shortcut.
        case shortcut
        /// Its flag on and no VoiceOver: VoiceOver.app, since the shortcut would turn the flag off.
        case open
        /// Its process there and its flag off: starting or stopping. Waited for.
        case wait
    }

    /// What to do for VoiceOver as it stands: `flagOn` is macOS's flag, `running` its process.
    public static func step(flagOn: Bool, running: Bool) -> Step {
        switch (flagOn, running) {
        case (true, true): return .nothing
        case (false, false): return .shortcut
        case (true, false): return .open
        case (false, true): return .wait
        }
    }

    /// How long the shortcut is given to bring VoiceOver before VoiceOver.app is opened: the hand-over between apps
    /// gives it the same (LeadWatcher).
    public static let shortcutWait: TimeInterval = 1.2

    /// After the shortcut and its wait: whether VoiceOver.app is opened as well. Only with VoiceOver still wholly off.
    /// With its flag on or its process there it is coming, and the app opened on top would add the slow start to the
    /// quick one.
    public static func openAfterShortcut(flagOn: Bool, running: Bool) -> Bool { !flagOn && !running }
}
