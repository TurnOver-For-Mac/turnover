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
        "Up and Down read. H moves by heading, K by link, F by form field; Tab moves through links and controls." + (config.general.windowsKeys ? " TurnOver Space switches to typing into the page." : "")
    }

    /// For a control with focus: the keys that work it, as VoiceOver's hints say them; in the apps TurnOver knows,
    /// what that place is for.
    public static func forObject(_ obj: TurnOverObject) -> String {
        if obj.states.contains(.unavailable) { return "" }
        if let b = NSRunningApplication(processIdentifier: obj.pid)?.bundleIdentifier, let h = forApp(b, obj) { return h }
        switch obj.role {
        case .button, .toggleButton: return "Space presses it."
        case .switchControl: return "Space turns it on or off."
        case .menuButton, .popUpButton, .dropDownList: return "Space opens the menu; Up and Down choose, Return picks."
        case .checkBox: return "Space ticks or unticks it."
        case .radioButton: return "Arrow keys move between the choices."
        case .link: return "Return follows the link."
        case .comboBox: return "Type, or Down for the choices."
        case .slider, .incrementor, .spinButton: return "Up and Down, or Left and Right, change it."
        case .tab: return "Left and Right move between tabs."
        case .disclosureTriangle: return "Space opens or closes it."
        case .list, .table, .outline, .treeView: return "Up and Down move through the items."
        default: return ""
        }
    }

    /// The approved apps' own places (7 Oct 2026: "tool tips in all approved apps").
    static func forApp(_ bundle: String, _ obj: TurnOverObject) -> String? {
        let role = obj.role
        let windows = config.general.windowsKeys
        switch bundle {
        case "com.apple.mail":
            if role == .table { return "Up and Down move through the messages. Return opens one; Tab goes to the message and the mailboxes. Delete deletes." }
            if role == .outline { return "Up and Down move through the mailboxes; Tab goes to the messages." }
            if obj.axRole == "AXWebArea" || role == .document, obj.states.contains(.editable) { return "Command Shift D sends the message." }
        case "com.apple.Safari", "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac":
            if role == .searchField || role == .comboBox || (role == .editableText && obj.name.lowercased().contains("address")) { return "" }
        case "com.apple.Terminal", "com.googlecode.iterm2":
            if role == .terminal || role == .editableText { return "New output is read as it comes. Up and Down go back through earlier commands." }
        case "com.microsoft.Word":
            // (Not a dialog's text box: Insert Table's column width got this hint.)
            if (role == .document || role == .editableText) && !AXHandler.modalInFront(pid: obj.pid) { return "TurnOver Down reads from here; TurnOver H moves by heading." }
        case "com.apple.finder":
            if [.outline, .list, .table, .browser].contains(role) {
                return (windows ? "Return opens the item, F2 renames it." : "Command Down opens the item, Return renames it.") + " Space shows a preview; Command Up goes to the folder above."
            }
            if role == .searchField { return "Tab goes to the results." }
        case "com.anthropic.claudefordesktop":
            if role == .editableText || role == .searchField { return "Shift Tab goes back to the conversation." }
        case "com.apple.MobileSMS", "net.whatsapp.WhatsApp":
            if ["messageBodyField", "ChatBar_ComposerTextView"].contains(obj.element.string(kAXIdentifierAttribute) ?? "") {
                return "Tab goes to the messages, Shift Tab to the conversations. TurnOver 1 reads the newest message."
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
