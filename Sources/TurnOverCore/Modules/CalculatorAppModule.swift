// SPDX-License-Identifier: GPL-3.0-or-later
// Calculator (18 Oct 2026, the Apple apps sweep). The keypad has the focus, and what's typed goes into a display
// (an AXStaticText described "Edit field", value "76") that posts nothing TurnOver hears. Typing "1 2 =" said
// nothing, then "12" as a typed word; the answer was never read (driver).
// What TurnOver says instead, as each key goes in:
// - digits and the point, as typed: "7", "point";
// - the operations by name: "plus", "minus", "times", "divided by", "percent";
// - Return or =: "equals", then the answer from the display;
// - Delete: what the display now shows; Escape or C: "clear".
import Foundation
import ApplicationServices

final class CalculatorAppModule: AppModule {
    static let bundleID = "com.apple.calculator"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        // Return and Escape aren't typed characters: their own keys.
        script("calculator_equals", String(localized: "Equals, then the answer", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter"], category: "Calculator") { [weak self] g in
            g.send(); self?.readDisplay(prefix: "equals")
        }
        script("calculator_clear", String(localized: "Clear", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:escape"], category: "Calculator") { g in
            g.send(); Speech.cancel(); Speech.speakMessage(String(localized: "clear", comment: "Spoken message"))
        }
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        guard event.kind == .typedCharacter, event.obj.pid == pid, let c = event.character else { next(); return }
        let words: String?
        switch c {
        case "0"..."9": words = String(c)
        case ".", ",": words = "point"
        case "+": words = "plus"
        case "-": words = "minus"
        case "*", "x", "X": words = "times"
        case "/": words = "divided by"
        case "%": words = "percent"
        case "=", "\r", "\n": readDisplay(prefix: "equals"); return
        case "\u{8}", "\u{7f}": readDisplay(prefix: nil); return
        case "\u{1b}", "c", "C": words = "clear"
        default: words = nil
        }
        guard let words else { next(); return }
        Speech.cancel()
        Speech.speakMessage(words)
    }

    /// The display's number, once Calculator has worked it out.
    private func readDisplay(prefix: String?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            let shown = self.display() ?? ""
            Speech.cancel()
            Speech.speakMessage([prefix, shown.isEmpty ? nil : shown].compactMap { $0 }.joined(separator: ", "))
        }
    }

    private func display() -> String? {
        guard let w = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) else { return nil }
        var queue = [w], seen = 0
        while !queue.isEmpty, seen < 80 {
            let e = queue.removeFirst(); seen += 1
            if e.role == "AXStaticText", e.string(kAXDescriptionAttribute) == "Edit field" { return e.string(kAXValueAttribute) }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }
}
