// SPDX-License-Identifier: GPL-3.0-or-later
// Who leads in an application: TurnOver or VoiceOver. The decision as a pure function of what is known, so it can
// be tested as a table (a code review on 16 Oct 2026: the lead watcher, the hand-over and the tap had no test at
// all). LeadWatcher.shouldLead gathers the inputs and asks here.
import Foundation

nonisolated public enum LeadPolicy {
    nonisolated public struct Inputs {
        public var gameLeads: Bool        // a game TurnOver reads (Steam, a bottle)
        public var pin: Bool?             // switched by hand for this app (the layer's T): on, off, or not touched
        public var leadMode: String       // "apps", "everywhere" or "voiceover" (the three modes)
        public var supported: Bool        // Edition.supports: the supported list, this Mac's extras, an app given to TurnOver
        public var inVoiceOverList: Bool  // given to VoiceOver under "everywhere"
        public var inLeadList: Bool       // in the Apps list
        public init(gameLeads: Bool, pin: Bool?, leadMode: String, supported: Bool, inVoiceOverList: Bool, inLeadList: Bool) {
            self.gameLeads = gameLeads; self.pin = pin; self.leadMode = leadMode
            self.supported = supported; self.inVoiceOverList = inVoiceOverList; self.inLeadList = inLeadList
        }
    }

    /// True: TurnOver leads. The rules, in order:
    /// "VoiceOver everywhere" steps back from every app. A game is TurnOver's while game speech is on.
    /// "TurnOver everywhere" takes every app but the ones given to VoiceOver. Otherwise an unsupported app is
    /// VoiceOver's unless switched on by hand; a supported one follows the hand switch, then the Apps list.
    public static func leads(_ i: Inputs) -> Bool {
        if i.leadMode == "voiceover" { return false }
        if i.gameLeads { return i.pin ?? true }
        if i.leadMode == "everywhere" { return i.pin ?? !i.inVoiceOverList }
        guard i.supported else { return i.pin ?? false }
        if let pin = i.pin { return pin }
        return i.inLeadList
    }
}
