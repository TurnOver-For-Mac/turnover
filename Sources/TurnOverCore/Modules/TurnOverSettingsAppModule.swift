// SPDX-License-Identifier: GPL-3.0-or-later
// TurnOver Settings, the SwiftUI app inside TurnOver.app: its controls get their labels late, and some not at all by
// the element a focus change hands over, so this module's objects look harder for a name. This used to sit in the
// generic name getter behind a bundle check; an app's quirks belong in its module (a contributor, 20 Oct 2026).
import Foundation
import ApplicationServices

final class TurnOverSettingsAppModule: AppModule {
    static let bundleID = "com.turnover.settings"
    override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? { SettingsLabelledObject.self }
}

/// A control in TurnOver Settings: when it has no name, its row is asked once (SwiftUI builds the label's link only
/// when something asks for the row's contents), then the window is searched for the same control by role and frame
/// (the element a focus change hands over can be a stand-in that never gets the label: "slider, 61 percent").
final class SettingsLabelledObject: TurnOverObject {
    private var askedRow = false
    private var waitedForLabel = false

    override var name: String {
        let base = super.name
        guard base.isEmpty else { return base }
        if !askedRow, let row = element.element(kAXParentAttribute) {
            askedRow = true
            _ = row.elements(kAXChildrenAttribute)
            if let l = swiftUILabel() { return l }
        }
        if !waitedForLabel, Thread.isMainThread, [.popUpButton, .slider, .checkBox, .comboBox, .radioButton, .spinButton, .editableText].contains(role),
           let mine = Self.frame(element), let window = element.element(kAXWindowAttribute) {
            waitedForLabel = true
            var queue = [window], seen = 0
            let wanted = element.role
            while !queue.isEmpty, seen < 600 {
                let e = queue.removeFirst(); seen += 1
                if e.role == wanted, let f = Self.frame(e), f == mine,
                   let l = e.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute)?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")), !l.isEmpty, l.count <= 60 {
                    return l
                }
                queue.append(contentsOf: e.elements(kAXChildrenAttribute))
            }
        }
        if let l = lateLabel() { return l }
        if let l = foundLabel { return l }
        return rawName
    }

    /// The label of the control standing where this nameless one stands. A switch handed over by Tab right after
    /// arrowing to a section is SwiftUI's inner button, never named; the labelled switch (an AXCheckBox) appears at
    /// the same place up to a second later (the log of 25 Oct 2026: the stand-in named only once the next control was
    /// read). Looked for among the app's own focused element and the near neighbours, a dozen elements at most.
    private var foundLabel: String?
    private func labelFromTwin() -> String? {
        guard let mine = Self.frame(element), mine.width > 0, mine.height > 0 else { return nil }
        // The likeliest first, each group only if the one before gave nothing: the app's own focused element (usually
        // the twin itself), the parent's children, then the grandparent's grandchildren. At most 24 looked at, none
        // twice; two different labels at the same place are no answer (a code review, 25 Oct 2026).
        var seen: [AXUIElement] = [element]
        var found: [String] = []
        func consider(_ c: AXUIElement) {
            guard seen.count < 24, !seen.contains(where: { $0.isSame(c) }) else { return }
            seen.append(c)
            guard ["AXCheckBox", "AXButton", "AXSwitch"].contains(c.role), let f = Self.frame(c), f.width > 0, f.height > 0 else { return }
            let close = abs(f.minX - mine.minX) <= 3 && abs(f.minY - mine.minY) <= 3 && abs(f.maxX - mine.maxX) <= 3 && abs(f.maxY - mine.maxY) <= 3
            guard close else { return }
            let words = [c.string(kAXTitleAttribute), c.string(kAXDescriptionAttribute), c.element(kAXTitleUIElementAttribute)?.string(kAXValueAttribute)]
            if let l = words.compactMap({ $0?.trimmingCharacters(in: CharacterSet(charactersIn: ": \n")) }).first(where: { !$0.isEmpty && $0.count <= 120 }), !found.contains(l) { found.append(l) }
        }
        if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) { consider(f) }
        let parent = element.element(kAXParentAttribute)
        if found.isEmpty, let p = parent { for c in p.elements(kAXChildrenAttribute) { consider(c) } }
        if found.isEmpty, let gp = parent?.element(kAXParentAttribute) {
            for c in gp.elements(kAXChildrenAttribute).prefix(8) where found.isEmpty { for g in c.elements(kAXChildrenAttribute).prefix(6) { consider(g) } }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// The label as the element has it now: SwiftUI fills a switch's description a moment after the focus change hands
    /// the switch over (Tab from the sidebar right after arrowing to a section: "switch, on", the name a second later,
    /// 25 Oct 2026). The name read at the focus is kept by the object, so it is asked for again here, live.
    private func lateLabel() -> String? {
        for attribute in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let s = element.string(attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, !Self.isClassName(s) { return s }
        }
        return swiftUILabel()
    }

    /// A control that takes the focus with no name yet: its label is waited for, and it is read with it. Up to three
    /// tenths of a second of silence; then it is read as it is, and if the label comes within two seconds after that,
    /// the label alone is said. Looked for every 40 ms, only while the control still has the focus: a Tab meanwhile
    /// reads the next control, not this one. The label arriving as a name change is left to this watch, so it is
    /// said once (a code review, 25 Oct 2026).
    private var labelWatch = 0
    private var labelWatchRunning = false
    override func event_gainFocus() {
        guard name.isEmpty, [.switchControl, .checkBox, .radioButton, .button, .toggleButton, .popUpButton, .slider, .disclosureTriangle].contains(role) else {
            super.event_gainFocus(); return
        }
        Log.io("settings: the \(element.role) has no name yet; waiting for its label")
        labelWatch += 1
        labelWatchRunning = true
        let start = Date()
        waitForLabel(labelWatch, reportBy: start.addingTimeInterval(0.3), until: start.addingTimeInterval(2.3), reported: false)
    }
    private func waitForLabel(_ watch: Int, reportBy: Date, until end: Date, reported: Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self, watch == self.labelWatch, API.focusObject?.element.isSame(self.element) == true else { self?.labelWatchRunning = false; return }
            if self.foundLabel == nil, let twin = self.labelFromTwin() { self.foundLabel = twin; Log.io("settings: the labelled control beside the \(self.element.role) has come") }
            let n = self.name
            if !n.isEmpty {
                self.labelWatchRunning = false
                if reported {
                    Log.io("settings: the label came late; said on its own")
                    TurnOverObject.lastName = (self.element, n)   // the name change that follows is the same news
                    Speech.speakMessage(n)
                } else { self.reportLateFocus() }
                return
            }
            if Date() >= end {
                self.labelWatchRunning = false
                Log.io("settings: no label came for the \(self.element.role) in 2 s")
                if !reported { self.reportLateFocus() }
                return
            }
            var reported = reported
            if !reported, Date() >= reportBy { reported = true; self.reportLateFocus() }
            self.waitForLabel(watch, reportBy: reportBy, until: end, reported: reported)
        }
    }
    private func reportLateFocus() { super.event_gainFocus() }   // (super can't be called from the closure above)
    override func event_loseFocus() { labelWatch += 1; labelWatchRunning = false; super.event_loseFocus() }
    override func event_nameChange() { if !labelWatchRunning { super.event_nameChange() } }
}
