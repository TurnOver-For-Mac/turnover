// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// JAWS Desktop reading commands, distinct from NVDA object/review navigation.
/// Freedom Scientific's JAWS hotkeys: Insert+8 reads the line, Insert+2 reads all, Insert+5 reads the word.
nonisolated public enum JAWSKeypad {
    static let actions: [String: String] = [
        ":numpad8": "run:jaws_sayPriorLine", ":numpad2": "run:jaws_sayNextLine",
        ":numpad4": "run:jaws_sayPriorCharacter", ":numpad6": "run:jaws_sayNextCharacter",
        ":numpad5": "run:reportCurrentCharacter",
        "turnover:numpad8": "run:reportCurrentLine", "turnover:numpad2": "run:sayAll",
        "turnover:numpad5": "run:reportCurrentWord",
        "turnover:numpad4": "run:jaws_sayPriorWord", "turnover:numpad6": "run:jaws_sayNextWord",
        "turnover:numpad7": "run:jaws_sayLineToCursor", "turnover:numpad9": "run:jaws_sayCursorToLineEnd",
        "turnover+shift:numpad2": "run:jaws_saySelection",
    ]
    /// Available equivalents when VoiceOver owns reading. Unsupported commands are not replaced by NVDA actions.
    public static func voiceOverKey(for action: String) -> String? {
        ["run:reportCurrentLine": "vo+l", "run:sayAll": "vo+a", "run:reportCurrentWord": "vo+w",
         "run:reportCurrentCharacter": "vo+c", "run:jaws_sayPriorLine": "up", "run:jaws_sayNextLine": "down",
         "run:jaws_sayPriorCharacter": "left", "run:jaws_sayNextCharacter": "right",
         "run:jaws_sayPriorWord": "option+left", "run:jaws_sayNextWord": "option+right",
         "run:jaws_saySelection": "vo+f6"][action]
    }
}
