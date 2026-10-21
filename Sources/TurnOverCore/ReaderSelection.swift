// SPDX-License-Identifier: GPL-3.0-or-later
// Startup chooses a reader once. Automatic hand-over controls subsequent application changes.

nonisolated public struct ReaderSelection {
    public private(set) var needsInitialSelection = true

    public init() {}

    /// An explicit hand-over supersedes any startup check still waiting for an eligible application.
    public mutating func readerChosen() { needsInitialSelection = false }

    /// Called after the front application and permissions are ready. Nil means keep the current reader;
    /// otherwise true selects TurnOver and false selects VoiceOver.
    public mutating func select(shouldLead: Bool, automaticHandOver: Bool, coexist: Bool,
                                voiceOverEnabled: Bool, turnOverActive: Bool) -> Bool? {
        guard needsInitialSelection || automaticHandOver else { return nil }
        needsInitialSelection = false
        let reading = coexist ? turnOverActive : !voiceOverEnabled
        // CoExist can start with both readers inactive. Selecting VoiceOver must start it, too.
        if !shouldLead, !voiceOverEnabled { return false }
        return shouldLead == reading ? nil : shouldLead
    }
}
