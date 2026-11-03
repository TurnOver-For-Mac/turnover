// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// Provider work has no reader objects, speech, mutable settings or callbacks into main. Interpretation uses
/// the captured attributes on main so existing app overlays and presentation rules keep their ownership.
nonisolated package struct WebBufferCollection: Sendable {
    package let snapshot: AXSnapshot
    let documentText: String
    let focusedPart: AXUIElement?
    package let stop: AXWalkStop?
    let elapsedMs: Int
    var navigationChanged = false

    package init(snapshot: AXSnapshot, documentText: String, focusedPart: AXUIElement?, stop: AXWalkStop?, elapsedMs: Int, navigationChanged: Bool = false) {
        self.snapshot = snapshot; self.documentText = documentText; self.focusedPart = focusedPart
        self.stop = stop; self.elapsedMs = elapsedMs; self.navigationChanged = navigationChanged
    }

    package static func collect(root: AXUIElement, focus: AXUIElement?, request: AXWalkRequest) -> Self {
        let budget = AXWalkBudget(request: request, maxVisits: 6000, maxAXQueries: 24_000, maxDepth: 59)
        var nodes: [ElementKey: AXSnapshot.Node] = [:]
        var path: Set<ElementKey> = []
        var references: [AXUIElement] = []
        var referenceKeys: Set<ElementKey> = []
        var characters = 0
        var text = ""
        var part: AXUIElement?
        var changed = false

        func capture(_ element: AXUIElement) -> Bool {
            let key = ElementKey(element)
            if nodes[key] != nil { return true }
            guard budget.visit() else { return false }
            // Attribute names include provider-specific labels used by app overlays. The batch is bounded;
            // unsupported values (text markers, opaque provider objects) never leave this worker.
            guard let names = element.attributeNamesResult().value as? [String], names.contains(kAXRoleAttribute), budget.check() else {
                if budget.check() { budget.halt(.providerFailure) }
                return false
            }
            if names.count > 128 { budget.halt(.queries); return false }
            // Read the subrole before values: do not copy a password into the page's snapshot.
            let subrole = element.string(kAXSubroleAttribute)
            let secureAttributes: Set<String> = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXParentAttribute, kAXWindowAttribute, kAXEnabledAttribute, kAXFocusedAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXIdentifierAttribute, kAXTitleUIElementAttribute, "AXRequired"]
            let wanted = subrole == "AXSecureTextField" ? names.filter { secureAttributes.contains($0) } : names
            let batch = element.attributesResult(wanted)
            guard budget.check() else { return false }
            let fallback = batch.query.error == .attributeUnsupported || batch.query.error == .notImplemented
            guard fallback || batch.isAligned else { budget.halt(.providerFailure); return false }
            var attributes: [String: AXSnapshotValue] = [:]
            for name in wanted {
                guard budget.check() else { return false }
                guard let value = fallback ? element.attr(name) : batch.attributes[name]?.value else { continue }
                if let string = value as? String {
                    characters += string.utf16.count
                    guard characters <= 8_000_000, string.utf16.count <= 131_072 else { budget.halt(.queries); return false }
                }
                if let v = AXSnapshotValue(value) { attributes[name] = v }
            }
            guard attributes[kAXRoleAttribute] != nil else { budget.halt(.providerFailure); return false }
            let actions = (element.actionNamesResult().value as? [String]) ?? []
            guard budget.check() else { return false }
            var settable: [String: Bool] = [:]
            if case .string("AXWebArea") = attributes[kAXRoleAttribute], let value = element.attributeSettableResult(kAXValueAttribute).value { settable[kAXValueAttribute] = value }
            if attributes["AXDisclosing"] != nil, let value = element.attributeSettableResult("AXDisclosing").value { settable["AXDisclosing"] = value }
            guard budget.check() else { return false }
            nodes[key] = AXSnapshot.Node(attributes: attributes, actions: actions, settable: settable)
            for name in [kAXTitleUIElementAttribute, kAXWindowAttribute] {
                if case .element(let e) = attributes[name], referenceKeys.insert(ElementKey(e)).inserted { references.append(e) }
            }
            return true
        }

        func visit(_ element: AXUIElement, depth: Int) {
            guard budget.depth(depth) else { return }
            let key = ElementKey(element)
            guard !path.contains(key) else { budget.halt(.cycle); return }
            guard nodes[key] == nil, capture(element) else { return }
            path.insert(key)
            defer { path.remove(key) }
            if case .array(let children) = nodes[key]?.attributes[kAXChildrenAttribute] {
                for child in children {
                    guard budget.check() else { break }
                    if case .element(let e) = child { visit(e, depth: depth + 1) }
                }
            }
        }

        AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            visit(root, depth: 0)
            let bridge = WebDocumentBridge(webArea: root)
            if let range = bridge.documentRange(), budget.check() { text = bridge.string(range) }
            // A web modal can be omitted from AXChildren. Capture its branch too, as the old synchronous
            // buffer did, but the focus and parent walk now share the same cancellation and query budget.
            if let focus, focus.pid == root.pid, !focus.isSame(root) {
                var child = focus
                for _ in 0..<60 {
                    guard budget.check(), let parent = child.element(kAXParentAttribute) else { break }
                    if parent.isSame(root) { part = child; visit(child, depth: 1); break }
                    child = parent
                }
            }
            // Labels and window/ancestor rules must resolve locally during interpretation. These are stubs:
            // no walk into sibling windows or the rest of the application.
            var parent = root.element(kAXParentAttribute)
            for _ in 0..<60 {
                guard budget.check(), let e = parent else { break }
                _ = capture(e)
                parent = e.element(kAXParentAttribute)
            }
            var index = 0
            while index < references.count, index < 256, budget.check() {
                _ = capture(references[index]); index += 1
            }
            if index < references.count, budget.check() { budget.halt(.visits) }
            if budget.check() {
                let old = nodes[ElementKey(root)]?.attributes["AXURL"]?.value
                let new = root.attr("AXURL")
                func address(_ value: CFTypeRef?) -> String { (value as? URL)?.absoluteString ?? (value as? String) ?? "" }
                changed = address(old) != address(new)
            }
        }
        return Self(snapshot: AXSnapshot(nodes: nodes), documentText: text, focusedPart: part,
                    stop: budget.stopped, elapsedMs: Int((DispatchTime.now().uptimeNanoseconds - request.startedAt) / 1_000_000), navigationChanged: changed)
    }
}
