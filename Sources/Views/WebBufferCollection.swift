// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Worker-owned provider reads; main interprets immutable values with the existing app and speech rules.
nonisolated package struct WebBufferCollection: Sendable {
    package let snapshot: AXSnapshot
    let documentText: String
    let focusedPart: AXUIElement?
    package let stop: AXWalkStop?
    let elapsedMs: Int
    var navigationChanged = false
    package var skippedElements = 0

    package struct Limits: Sendable {
        package var elements = 6000
        package var queries = 24_000
        package var depth = 59
        package var attributes = 128
        package var stringLength = 131_072
        package var characters = 8_000_000
        package var duration: UInt64 = 2_000_000_000
        package init() {}
    }

    package init(snapshot: AXSnapshot, documentText: String, focusedPart: AXUIElement?, stop: AXWalkStop?, elapsedMs: Int, navigationChanged: Bool = false) {
        self.snapshot = snapshot; self.documentText = documentText; self.focusedPart = focusedPart
        self.stop = stop; self.elapsedMs = elapsedMs; self.navigationChanged = navigationChanged
    }

    /// `continuing`: instead of the page from its root, these elements and everything under them, in order: where the
    /// walk over an earlier collection stopped, the rest of the page (a long chat read on, issue 227). The page's own
    /// text, focus and ancestors were collected the first time and are not asked for again.
    package static func collect(root: AXUIElement, focus: AXUIElement?, request: AXWalkRequest, limits: Limits = Limits(),
                                continuing: [AXUIElement]? = nil,
                                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> Self {
        // Submission can wait behind an obsolete, uninterruptible AX call. That wait is not this read's budget.
        let began = now()
        let budget = AXWalkBudget(request: request, duration: limits.duration, maxVisits: limits.elements,
                                  maxAXQueries: limits.queries, maxDepth: limits.depth, startedAt: began, now: now)
        var nodes: [ElementKey: AXSnapshot.Node] = [:], path: Set<ElementKey> = []
        var references: [AXUIElement] = [], referenceKeys: Set<ElementKey> = []
        var characters = 0, skipped = 0
        var text = "", part: AXUIElement?, changed = false
        var hadOmissions = false

        func capture(_ element: AXUIElement) -> Bool {
            let key = ElementKey(element)
            if nodes[key] != nil { return true }
            guard budget.visit() else { return false }
            guard let names = element.attributeNamesResult().value as? [String], names.contains(kAXRoleAttribute), budget.check() else {
                if budget.check() {
                    if element.isSame(root) { budget.halt(.providerFailure) }
                    else { skipped += 1; hadOmissions = true }
                }
                return false
            }
            // A provider-specific attribute list must not exclude the structure and labels needed to read its
            // children. Ignore surplus metadata instead of ending the entire document (review, 6 Nov 2026).
            let priority = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXValueAttribute, kAXTitleAttribute,
                            kAXDescriptionAttribute, kAXParentAttribute, kAXWindowAttribute, kAXTitleUIElementAttribute]
            let first = priority.filter { names.contains($0) }
            var wanted = first + names.filter { !first.contains($0) }.prefix(max(0, limits.attributes - first.count))
            let subrole = element.string(kAXSubroleAttribute)
            if subrole == "AXSecureTextField" {
                let safe: Set<String> = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                    kAXHelpAttribute, kAXParentAttribute, kAXWindowAttribute, kAXEnabledAttribute, kAXFocusedAttribute,
                    kAXPositionAttribute, kAXSizeAttribute, kAXIdentifierAttribute, kAXTitleUIElementAttribute, "AXRequired"]
                wanted = wanted.filter { safe.contains($0) }
            }
            let batch = element.attributesResult(wanted)
            guard budget.check() else { return false }
            let fallback = batch.query.error == .attributeUnsupported || batch.query.error == .notImplemented
            var attributes: [String: AXSnapshotValue] = [:]
            if fallback || batch.isAligned {
                for name in wanted {
                    guard budget.check() else { return false }
                    guard let value = fallback ? element.attr(name) : batch.attributes[name]?.value else { continue }
                    if let string = value as? String {
                        // One oversized value is local to its element. The aggregate retained-text cap still
                        // bounds this read, including many individually reasonable values.
                        if string.utf16.count > limits.stringLength { hadOmissions = true; continue }
                        characters += string.utf16.count
                        guard characters <= limits.characters else { budget.halt(.queries); return false }
                    }
                    if let value = AXSnapshotValue(value) { attributes[name] = value }
                }
            }
            guard attributes[kAXRoleAttribute] != nil else {
                if element.isSame(root) { budget.halt(.providerFailure) }
                else { skipped += 1; hadOmissions = true }
                return false
            }
            let actions = (element.actionNamesResult().value as? [String]) ?? []
            var settable: [String: Bool] = [:]
            if case .string("AXWebArea") = attributes[kAXRoleAttribute], let value = element.attributeSettableResult(kAXValueAttribute).value { settable[kAXValueAttribute] = value }
            if attributes["AXDisclosing"] != nil, let value = element.attributeSettableResult("AXDisclosing").value { settable["AXDisclosing"] = value }
            guard budget.check() else { return false }
            nodes[key] = AXSnapshot.Node(attributes: attributes, actions: actions, settable: settable)
            for name in [kAXTitleUIElementAttribute, kAXWindowAttribute] {
                if case .element(let element) = attributes[name], referenceKeys.insert(ElementKey(element)).inserted { references.append(element) }
            }
            return true
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard budget.depth(depth) else { return }
            let key = ElementKey(element)
            guard !path.contains(key) else { budget.halt(.cycle); return }
            guard nodes[key] == nil, capture(element) else { return }
            path.insert(key); defer { path.remove(key) }
            if case .array(let children) = nodes[key]?.attributes[kAXChildrenAttribute] {
                for child in children {
                    guard budget.check() else { break }
                    if case .element(let element) = child { visit(element, depth: depth + 1) }
                }
            }
        }
        AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { status in
            switch status {
            case .returned(let error) where [.invalidUIElement, .failure, .cannotComplete].contains(error):
                // A disappearing child must not discard its surviving siblings. AXHealth still accounts for
                // transport time and backoff; a disabled API, exhausted budget or client backoff remains global.
                hadOmissions = true
            default: budget.record(status)
            }
        }) {
            if let continuing {
                for element in continuing {
                    guard budget.check() else { break }
                    visit(element, depth: 1)
                }
                return
            }
            visit(root, depth: 0)
            let bridge = WebDocumentBridge(webArea: root)
            if let range = bridge.documentRange(), budget.check() {
                let value = bridge.string(range)
                if value.utf16.count <= limits.characters { text = value }
            }
            // Safari can omit a modal from AXChildren. Capture the focused branch under the same budget.
            if let focus, focus.pid == root.pid, !focus.isSame(root) {
                var child = focus
                for _ in 0..<60 {
                    guard budget.check(), let parent = child.element(kAXParentAttribute) else { break }
                    if parent.isSame(root) { part = child; visit(child, depth: 1); break }
                    child = parent
                }
            }
            var parent = root.element(kAXParentAttribute)
            for _ in 0..<60 {
                guard budget.check(), let element = parent else { break }
                _ = capture(element); parent = element.element(kAXParentAttribute)
            }
            var index = 0
            while index < references.count, index < 256, budget.check() { _ = capture(references[index]); index += 1 }
            if index < references.count, budget.check() { budget.halt(.visits) }
            // Isolated omissions are normal on changing pages; losing the root itself (including app exit)
            // is a failed read, never a complete empty document.
            if hadOmissions, budget.check(), root.attributeResult(kAXRoleAttribute).value == nil { budget.halt(.providerFailure) }
            if budget.check() {
                func address(_ value: CFTypeRef?) -> String { (value as? URL)?.absoluteString ?? (value as? String) ?? "" }
                changed = address(nodes[ElementKey(root)]?.attributes["AXURL"]?.value) != address(root.attr("AXURL"))
            }
        }
        var result = Self(snapshot: AXSnapshot(nodes: nodes), documentText: text, focusedPart: part, stop: budget.stopped,
                          elapsedMs: Int((now() &- began) / 1_000_000), navigationChanged: changed)
        result.skippedElements = skipped
        return result
    }
}
