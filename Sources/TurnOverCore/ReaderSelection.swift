// SPDX-License-Identifier: GPL-3.0-or-later
// Startup chooses a reader once. Automatic hand-over controls subsequent application changes.
// CoExist's temporary fallback leaves that choice pending until VoiceOver returns, unless the user chooses first.

nonisolated public struct ReaderSelection {
    public private(set) var needsInitialSelection = true

    public init() {}

    /// An explicit hand-over supersedes any startup check still waiting for an eligible application.
    public mutating func readerChosen() { needsInitialSelection = false }

    /// Called after the front application and permissions are ready. Nil means keep the current reader;
    /// otherwise true selects TurnOver and false selects VoiceOver. CoExist's temporary startup fallback
    /// keeps the initial choice pending until VoiceOver returns, unless the user chooses a reader first.
    public mutating func select(shouldLead: Bool, automaticHandOver: Bool, coexist: Bool,
                                voiceOverEnabled: Bool, voiceOverRunning: Bool, turnOverActive: Bool) -> Bool? {
        guard needsInitialSelection || automaticHandOver else { return nil }
        let atStartup = needsInitialSelection
        needsInitialSelection = atStartup && coexist && shouldLead && !(voiceOverEnabled && voiceOverRunning)
        let reading = coexist ? turnOverActive : !voiceOverEnabled
        // CoExist can start with both readers inactive. Selecting VoiceOver must start it, too.
        // After startup, both readers being off can be the user's deliberate choice; preserve it.
        if atStartup, !shouldLead, !voiceOverEnabled { return false }
        return shouldLead == reading ? nil : shouldLead
    }
}
