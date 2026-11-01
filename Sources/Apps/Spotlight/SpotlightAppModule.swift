// SPDX-License-Identifier: GPL-3.0-or-later
// Spotlight on macOS 27, drawn by "Siri AI" (com.apple.campo). Read live with the panel open, 21 Oct 2026:
//   AXWindow (AXSystemDialog)
//     AXGroup (AXHostingView)
//       AXScrollArea
//         AXTextField (AXSearchField, identifier SpotlightSearchField), focused; inside it an AXButton "Search"
//         (the magnifying glass, won't take the focus); with text typed, the results' AXList appears here too
//       AXButton, description "Studio microphone", help "Voice Mode": takes the focus
// Spotlight's own Tab goes from the field to the window (the focus news is ignored) and back, or to the results:
// the microphone was never reached. VoiceOver reaches it with its own cursor.
import Foundation
import ApplicationServices

final class SpotlightAppModule: AppModule {
    static let bundleID = "com.apple.campo"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        // In Spotlight's panel Tab and Shift+Tab are TurnOver's: the search field, the results, the microphone, round.
        for forward in [true, false] {
            script(forward ? "spotlight_next" : "spotlight_previous",
                   forward ? "In Spotlight: the next control, the microphone included" : "In Spotlight: the previous control, the microphone included",
                   gestures: [forward ? "kb:tab" : "kb:shift+tab"], category: "Spotlight") { [weak self] g in
                self?.move(g, forward: forward)
            }.isAvailable = { [weak self] in
                guard let self, API.focusPid == self.pid, !AXHandler.shared.isMenuOpen, let f = API.focusObject?.element else { return false }
                return Self.panel(of: f) != nil
            }
        }
    }

    /// Spotlight's window, when the element is in it (Siri AI draws other windows too, where Tab is left alone).
    static func panel(of e: AXUIElement) -> AXUIElement? {
        guard let window = SettingsPanePlugin.windowOf(e) else { return nil }
        return SettingsPanePlugin.controlsInOrder(in: window).contains { $0.string(kAXIdentifierAttribute) == "SpotlightSearchField" } ? window : nil
    }

    private func move(_ g: KeyboardGesture, forward: Bool) {
        guard let f = API.focusObject?.element, let window = Self.panel(of: f) else { g.send(); return }
        let all = SettingsPanePlugin.controlsInOrder(in: window).filter {
            ($0.attr(kAXEnabledAttribute) as? Bool) != false && (TurnOverObject.frame($0).map { $0.width > 0 && $0.height > 0 } ?? false)
        }
        // Where the focus is: the control itself, or the control it is inside (a row of the results).
        var here: Int?
        var p: AXUIElement? = f; var hops = 0
        while let x = p, hops < 6, here == nil { here = all.firstIndex { $0.isSame(x) }; p = x.element(kAXParentAttribute); hops += 1 }
        guard !all.isEmpty else { g.send(); return }
        let n = here.map { (($0 + (forward ? 1 : -1)) + all.count) % all.count } ?? (forward ? 0 : all.count - 1)
        Log.io("Spotlight: \(forward ? "Tab" : "Shift+Tab") to \(all[n].role) \(n + 1) of \(all.count)")
        SettingsPanePlugin.focus(all[n])
    }
}
