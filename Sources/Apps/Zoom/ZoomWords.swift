// SPDX-License-Identifier: GPL-3.0-or-later
// Zoom: Zoom's wording and layout turned into what TurnOver says, as pure functions for the tests. What was observed, and when, is in the opening comment of ZoomAppModule.swift.
import Foundation
import ApplicationServices

/// Zoom's English words, as observed on 13 Nov 2026, turned into what TurnOver says. Pure, for the tests. Every
/// word the module matches from Zoom is here, so another language can be added in one place.
nonisolated package enum ZoomWords {
    /// The Meeting menu's audio item names the next action: "Unmute audio" means the microphone is muted now.
    package static func audio(_ menuTitle: String) -> String? {
        switch menuTitle {
        case "Unmute audio": return String(localized: "muted", comment: "Zoom: your microphone after the mute key")
        case "Mute audio": return String(localized: "unmuted", comment: "Zoom: your microphone after the mute key")
        default: return nil
        }
    }

    package static func video(_ menuTitle: String) -> String? {
        switch menuTitle {
        case "Start video": return String(localized: "video off", comment: "Zoom: your camera after the video key")
        case "Stop video": return String(localized: "video on", comment: "Zoom: your camera after the video key")
        default: return nil
        }
    }

    /// The one thing in Zoom's feedback window, by role, or nil for any other window: a button while the hand is
    /// up, an image for a reaction.
    package static func feedbackChild(windowSubrole: String?, childRoles: [String]) -> String? {
        guard !["AXStandardWindow", "AXDialog", "AXSystemDialog", "AXFloatingWindow"].contains(windowSubrole ?? ""),
              childRoles.count == 1, let only = childRoles.first, only == "AXButton" || only == "AXImage" else { return nil }
        return only
    }

    /// The name from the tile Zoom marks: "Name, Computer audio unmuted, Video on, active speaker".
    package static func activeSpeaker(in descriptions: [String]) -> String? {
        for text in descriptions where text.hasSuffix(", active speaker") {
            let name = text.components(separatedBy: ", ").first ?? ""
            if !name.isEmpty { return name }
        }
        return nil
    }
}
