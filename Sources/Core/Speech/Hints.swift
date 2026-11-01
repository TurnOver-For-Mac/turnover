// SPDX-License-Identifier: GPL-3.0-or-later
// Hints (VoiceOver's "speak hints"; 7 Oct 2026): after a pause on an item, what can be done with it. Any key
// cancels a hint not yet spoken. Preferences, Presentation, Hints turns them off.
import Foundation
import AppKit

public enum Hints {
    private static var generation = 0
    public static var delay: Double = 1.2

    /// Say the hint after the pause, unless a key comes first or hints are off.
    public static func schedule(_ text: String) {
        guard config.presentation.speakHints, !text.isEmpty else { return }
        generation += 1
        let g = generation
        let focusAt = API.focusObject?.element
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Never over reading (a say all), and only for where the focus still is: a hint for the message list was
            // said as a message window came up (7 Oct 2026).
            guard g == generation, config.presentation.speakHints, !SayAll.isRunning else { return }
            if let a = focusAt, let b = API.focusObject?.element, !CFEqual(a, b) { return }
            Speech.speakText(text)
        }
    }

    /// A web page or message in browse mode.
    public static var page: String {
        String(localized: "Up and Down read. H moves by heading, K by link, F by form field; Tab moves through links and controls.", comment: "A hint on a web page")
            + (config.general.windowsKeys ? " " + String(localized: "TurnOver Space switches to typing into the page.", comment: "A hint on a web page, Windows style") : "")
    }

    /// For a control with focus: the keys that work it, as VoiceOver's hints say them; in the apps TurnOver knows,
    /// what that place is for.
    public static func forObject(_ obj: TurnOverObject) -> String {
        if obj.states.contains(.unavailable) { return "" }
        if let b = NSRunningApplication(processIdentifier: obj.pid)?.bundleIdentifier, let h = forApp(b, obj) { return h }
        switch obj.role {
        case .button, .toggleButton: return String(localized: "Space presses it.", comment: "A hint, said after a pause on an item")
        case .switchControl: return String(localized: "Space turns it on or off.", comment: "A hint, said after a pause on an item")
        case .menuButton, .popUpButton, .dropDownList: return String(localized: "Space opens the menu; Up and Down choose, Return picks.", comment: "A hint, said after a pause on an item")
        case .checkBox: return String(localized: "Space ticks or unticks it.", comment: "A hint, said after a pause on an item")
        case .radioButton: return String(localized: "Arrow keys move between the choices.", comment: "A hint, said after a pause on an item")
        case .link: return String(localized: "Return follows the link.", comment: "A hint, said after a pause on an item")
        case .comboBox: return String(localized: "Type, or Down for the choices.", comment: "A hint, said after a pause on an item")
        case .slider, .incrementor, .spinButton: return String(localized: "Up and Down, or Left and Right, change it.", comment: "A hint, said after a pause on an item")
        case .tab: return String(localized: "Left and Right move between tabs.", comment: "A hint, said after a pause on an item")
        case .disclosureTriangle: return String(localized: "Space opens or closes it.", comment: "A hint, said after a pause on an item")
        case .list, .table, .outline, .treeView: return String(localized: "Up and Down move through the items.", comment: "A hint, said after a pause on an item")
        default: return ""
        }
    }

    /// The approved apps' own places (7 Oct 2026: "tool tips in all approved apps").
    static func forApp(_ bundle: String, _ obj: TurnOverObject) -> String? {
        let role = obj.role
        let windows = config.general.windowsKeys
        switch bundle {
        case "com.apple.mail":
            if role == .table { return String(localized: "Up and Down move through the messages. Return opens one; Tab goes to the message and the mailboxes. Delete deletes.", comment: "A hint, said after a pause on an item") }
            if role == .outline { return String(localized: "Up and Down move through the mailboxes; Tab goes to the messages.", comment: "A hint, said after a pause on an item") }
            if obj.axRole == "AXWebArea" || role == .document, obj.states.contains(.editable) { return String(localized: "Command Shift D sends the message.", comment: "A hint, said after a pause on an item") }
        case "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            if role == .searchField || role == .comboBox || (role == .editableText && obj.name.lowercased().contains("address")) { return "" }
        case "com.apple.Terminal", "com.googlecode.iterm2":
            if role == .terminal || role == .editableText { return String(localized: "New output is read as it comes. Up and Down go back through earlier commands.", comment: "A hint, said after a pause on an item") }
        case "com.microsoft.Word":
            // (Not a dialog's text box: Insert Table's column width got this hint.)
            if (role == .document || role == .editableText) && !AXHandler.modalInFront(pid: obj.pid) { return String(localized: "TurnOver Down reads from here; TurnOver H moves by heading.", comment: "A hint, said after a pause on an item") }
        case "com.apple.finder":
            if [.outline, .list, .table, .browser].contains(role) {
                return (windows ? String(localized: "Return opens the item, F2 renames it.", comment: "A hint, said after a pause on an item") : String(localized: "Command Down opens the item, Return renames it.", comment: "A hint, said after a pause on an item")) + " " + String(localized: "Space shows a preview; Command Up goes to the folder above.", comment: "A hint in Finder")
            }
            if role == .searchField { return String(localized: "Tab goes to the results.", comment: "A hint, said after a pause on an item") }
        case "com.anthropic.claudefordesktop":
            if role == .editableText || role == .searchField { return String(localized: "Shift Tab goes back to the conversation.", comment: "A hint, said after a pause on an item") }
        case "com.apple.MobileSMS", "net.whatsapp.WhatsApp":
            if ["messageBodyField", "ChatBar_ComposerTextView"].contains(obj.element.string(kAXIdentifierAttribute) ?? "") {
                return String(localized: "Tab goes to the messages, Shift Tab to the conversations. TurnOver 1 reads the newest message.", comment: "A hint, said after a pause on an item")
            }
        case "com.apple.TextEdit":
            if role == .editableText || role == .document { return "" }
        default: break
        }
        return nil
    }

    /// A key was pressed: the hint waiting is not wanted.
    public static func cancel() { DispatchQueue.main.async { generation += 1 } }
}
