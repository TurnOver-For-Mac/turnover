// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Recovery owns one press, never a replay of the gesture. A newer key, page, focus departure or timeout retires
/// it before any action. The AX worker can outlive the deadline if a provider hangs, but cannot act afterwards.
final class BrowseActivationRecovery {
    private let runner = AXWalkRunner<AXUIElement?>()
    private var generation = 0

    func start(document: BrowseModeDocument, element: AXUIElement, name: String) {
        generation += 1
        let operation = generation
        let page = document.pageGeneration
        let intent = document.bufferIntent
        let keys = ScriptHandler.keysArrivedCount
        let moved = document.positionMovedAt
        let position = document.position
        let focus = API.focusObject?.element
        let deadline = Date().addingTimeInterval(0.15)
        let root = document.webArea
        let ancestors = document.buffer.activationAncestors(of: element)
        // Repeated labels need the fresh copy's positional match. Choosing the last "Delete" on the page
        // could otherwise activate another message's control.
        let wanted = Self.nameKey(name)
        let repeatedName = document.buffer.lines.lazy.filter { line in
            Self.nameKey(document.buffer.text.substring(with: NSRange(location: line.start, length: line.end - line.start))) == wanted
        }.prefix(2).count > 1
        func current() -> Bool {
            operation == generation && document.pageGeneration == page && document.bufferIntent == intent &&
            ScriptHandler.keysArrivedCount == keys && document.positionMovedAt == moved &&
            (focus.map { API.focusObject?.element.isSame($0) == true } ?? (API.focusObject == nil)) &&
            AXHandler.shared.activePid == root.pid &&
            API.focusTreeInterceptor === document && !document.passThrough
        }
        func finish(_ reason: String) {
            guard current() else { return }
            generation += 1
            runner.cancel()
            Log.io("browse mode: nothing to activate at \"\(Log.words(name))\"; live recovery: \(reason)")
            Speech.speakMessage(String(localized: "nothing to activate", comment: "Spoken message"))
        }
        func press(_ live: AXUIElement) -> Bool {
            guard current(), Date() < deadline else { return false }
            guard !document.refreshIfNavigated() else { return false }
            guard document.press(nearestTo: live, valid: {
                Date() < deadline && ScriptHandler.keysArrivedCount == keys && document.pageGeneration == page &&
                document.bufferIntent == intent && API.focusTreeInterceptor === document &&
                AXHandler.shared.activePid == root.pid && !document.passThrough
            }) else { return false }
            generation += 1
            runner.cancel()
            Log.io("browse mode: recovered the live control for \"\(Log.words(name))\"")
            document.buffer.build()
            return true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self, weak document] in
            guard self != nil, document != nil else { return }
            finish("the 150 ms recovery deadline expired")
        }
        runner.submit(collect: { request in
            repeatedName ? nil : BrowseModeDocument.liveActionable(named: name, in: root, near: ancestors, request: request)
        }, publish: { [weak self, weak document] live in
            guard self != nil, let document, current(), Date() < deadline else { return }
            if let live, press(live) { return }
            // This is one rebuild and one retry, not recursive activate(). Match the spoken name in the new
            // publication, choosing the closest position when that name occurs more than once.
            let revision = document.buffer.revision
            document.buffer.build { [weak self, weak document] in
                guard self != nil, let document, current(), Date() < deadline else { return }
                guard document.buffer.revision != revision else { finish("no fresh copy"); return }
                let wanted = Self.nameKey(name)
                let matches = document.buffer.lines.filter { line in
                    Self.nameKey(document.buffer.text.substring(with: NSRange(location: line.start, length: line.end - line.start))) == wanted
                }.sorted { abs($0.start - position) < abs($1.start - position) }
                if let line = matches.first, let live = line.element, press(live) { return }
                finish("no matching live control in the fresh copy")
            }
        })
    }

    nonisolated static func nameKey(_ text: String) -> String {
        // Object names insert commas between separate text descendants; a rebuilt label can split the
        // same words differently. Compare those spoken words, preserving other punctuation.
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).joined(separator: " ").lowercased()
    }
}

extension BrowseModeDocument {
    /// 14 Nov 2026: a bounded reverse walk reaches rebuilt buttons after a long conversation. Cached parents
    /// give nearby controls priority, even when the dead element no longer answers AXParent. Labels can be
    /// nested groups, not just direct text children. All queries share a 60 ms / 512-node budget off main.
    nonisolated static func liveActionable(named name: String, in root: AXUIElement, near ancestors: [AXUIElement],
                                          request: AXWalkRequest) -> AXUIElement? {
        let budget = AXWalkBudget(request: request, duration: 60_000_000, maxVisits: 512, maxAXQueries: 1024)
        let wanted = BrowseActivationRecovery.nameKey(name)
        let roles: Set<String> = ["AXLink", "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton"]
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute]
        var seen: Set<ElementKey> = []
        return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: {
            // A dead ancestor is expected here. Other failures stop the whole search.
            if $0 != .returned(.invalidUIElement) { budget.record($0) }
        }) { () -> AXUIElement? in
            func innerText(_ children: [AXUIElement]) -> String? {
                var pieces: [String] = []
                var stack = children.reversed().map { ($0, 0) }
                var labelSeen: Set<ElementKey> = []
                while let (child, depth) = stack.popLast() {
                    guard labelSeen.insert(ElementKey(child)).inserted else { return nil }
                    guard depth < 12, labelSeen.count <= 64, budget.visit() else { return nil }
                    let values = child.attrs(names)
                    guard budget.check() else { return nil }
                    let role = values[kAXRoleAttribute] as? String ?? ""
                    // Do not borrow the label of another nested control.
                    if roles.contains(role) { return nil }
                    let kids = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
                    if let text = (values[kAXValueAttribute] as? String) ?? (values[kAXTitleAttribute] as? String), !text.isEmpty {
                        pieces.append(text)
                    } else if !kids.isEmpty {
                        stack.append(contentsOf: kids.reversed().map { ($0, depth + 1) })
                    }
                }
                return BrowseActivationRecovery.nameKey(pieces.joined(separator: " "))
            }
            for anchor in ancestors + [root] {
                var stack = [anchor]
                var local = 0
                let limit = anchor.isSame(root) ? 512 : 64
                while let element = stack.popLast(), local < limit, budget.check() {
                    guard seen.insert(ElementKey(element)).inserted else { continue }
                    guard budget.visit() else { return nil }
                    local += 1
                    let values = element.attrs(names)
                    guard budget.check() else { return nil }
                    let role = values[kAXRoleAttribute] as? String ?? ""
                    let children = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
                    if roles.contains(role) {
                        let own = [values[kAXTitleAttribute] as? String, values[kAXDescriptionAttribute] as? String]
                            .compactMap { $0 }.map(BrowseActivationRecovery.nameKey)
                        if own.contains(wanted) || innerText(children) == wanted { return element }
                    }
                    // Last child first: recent messages and their answer buttons are at the page's end.
                    stack.append(contentsOf: children)
                }
            }
            return nil
        }
    }
}
