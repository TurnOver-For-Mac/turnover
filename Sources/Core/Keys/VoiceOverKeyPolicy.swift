// SPDX-License-Identifier: GPL-3.0-or-later
nonisolated public enum VoiceOverKeyPolicy {
    public enum Command: Equatable, Sendable { case settings, passNext }
    /// Resolve style-specific commands before the legacy NVDA special-key switch.
    public static func command(style: KeyboardStyle, code: Int64, modifiers: Modifiers) -> Command? {
        guard modifiers == .turnover else { return nil }
        if style == .jaws {
            if [120, 22, 9].contains(code) { return .settings } // F2, top-row 6, V
            if code == 20 { return .passNext } // JAWS Insert+top-row 3
        } else if code == 120 { return .passNext }
        return nil
    }
}
