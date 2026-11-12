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
    var omittedElements: Set<ElementKey> = []
    package var skippedElements: Int { omittedElements.count }
    /// Elements read with the short list alone.
    package var plainElements = 0
    private static let plainMetadataNames = AXSnapshot.plainNames.filter { $0 != kAXValueAttribute }

    package struct Limits: Sendable {
        package var elements = 6000
        package var queries = 24_000
        package var depth = 59
        package var attributes = 128
        package var stringLength = 131_072
        package var characters = 8_000_000
        package var duration: UInt64 = 2_000_000_000
        /// A web page's plain texts and plain groups are read with the short list alone (AXSnapshot.plainNames). Off
        /// for an app with plugin profiles (their rules may ask anything of any element), and in the tests that
        /// compare the two.
        package var plainElementsShort = true
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
                                continuing: [AXUIElement]? = nil, expectedURL: AXSnapshotValue? = nil,
                                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) -> Self {
        // Submission can wait behind an obsolete, uninterruptible AX call. That wait is not this read's budget.
        let began = now()
        let budget = AXWalkBudget(request: request, duration: limits.duration, maxVisits: limits.elements,
                                  maxAXQueries: limits.queries, maxDepth: limits.depth, startedAt: began, now: now)
        var nodes: [ElementKey: AXSnapshot.Node] = [:], path: Set<ElementKey> = []
        var references: [AXUIElement] = [], referenceKeys: Set<ElementKey> = []
        var characters = 0
        var omissions: Set<ElementKey> = []
        var text = "", part: AXUIElement?, changed = false
        var hadOmissions = false
        // Only on a web page: an iOS app's screen or a window (looked through for its page) is read in full.
        var short = false
        var plain = 0

        func capture(_ element: AXUIElement) -> Bool {
            let key = ElementKey(element)
            if nodes[key] != nil { return true }
            guard budget.visit() else { return false }
            var knownSubrole: String??
            if short {
                // The role is unknown until the batch returns. Keep password values out of this first request.
                let batch = element.attributesResult(plainMetadataNames)
                guard budget.check() else { return false }
                if batch.isAligned, let role = batch.attributes[kAXRoleAttribute]?.value as? String {
                    let subrole = batch.attributes[kAXSubroleAttribute]?.value as? String
                    knownSubrole = .some(subrole)
                    if subrole != "AXSecureTextField", AXSnapshot.isPlain(role: role, subrole: subrole) {
                        let plainValue = element.attr(kAXValueAttribute)
                        guard budget.check() else { return false }
                        var attributes: [String: AXSnapshotValue] = [:]
                        for name in AXSnapshot.plainNames {
                            guard let value = name == kAXValueAttribute ? plainValue : batch.attributes[name]?.value else { continue }
                            if let string = value as? String {
                                if string.utf16.count > limits.stringLength { hadOmissions = true; continue }
                                characters += string.utf16.count
                                guard characters <= limits.characters else { budget.halt(.queries); return false }
                            }
                            if let value = AXSnapshotValue(value) { attributes[name] = value }
                        }
                        nodes[key] = AXSnapshot.Node(attributes: attributes, isPlain: true)
                        plain += 1
                        for name in [kAXTitleUIElementAttribute, kAXWindowAttribute] {
                            if case .element(let element) = attributes[name], referenceKeys.insert(ElementKey(element)).inserted { references.append(element) }
                        }
                        return true
                    }
                }
                // Other elements, or a short read that did not answer, use the full path below.
            }
            guard let names = element.attributeNamesResult().value as? [String], names.contains(kAXRoleAttribute), budget.check() else {
                if budget.check() {
                    if element.isSame(root) { budget.halt(.providerFailure) }
                    else { omissions.insert(key); hadOmissions = true }
                }
                return false
            }
            // A provider-specific attribute list must not exclude the structure and labels needed to read its
            // children. Ignore surplus metadata instead of ending the entire document (review, 6 Nov 2026).
            let priority = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute, kAXValueAttribute, kAXTitleAttribute,
                            kAXDescriptionAttribute, kAXParentAttribute, kAXWindowAttribute, kAXTitleUIElementAttribute]
            let first = priority.filter { names.contains($0) }
            var wanted = first + names.filter { !first.contains($0) }.prefix(max(0, limits.attributes - first.count))
            let subrole = knownSubrole ?? element.string(kAXSubroleAttribute)
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
                else { omissions.insert(key); hadOmissions = true }
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
        func address(_ value: CFTypeRef?) -> String { (value as? URL)?.absoluteString ?? (value as? String) ?? "" }
        /// The root's address now, or nil when no answer came: a page that stops answering during a read has not
        /// changed its address, and its copy is not thrown away for it (11 Nov 2026).
        func addressNow() -> String? {
            let read = root.attributeResult("AXURL")
            return read.isNoAnswer ? nil : address(read.value)
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
            short = limits.plainElementsShort && root.string(kAXRoleAttribute) == "AXWebArea"
            if let continuing {
                // Reused web areas can change pages without a new root. Check on the same worker as the walk.
                guard root.attributeResult(kAXRoleAttribute).value != nil else { budget.halt(.providerFailure); return }
                guard let start = addressNow() else { budget.halt(.providerFailure); return }
                if budget.check(), let expectedURL, address(expectedURL.value) != start { changed = true; return }
                for element in continuing {
                    guard budget.check() else { break }
                    visit(element, depth: 1)
                }
                if hadOmissions, budget.check(), root.attributeResult(kAXRoleAttribute).value == nil { budget.halt(.providerFailure) }
                if budget.check(), let end = addressNow() { changed = start != end }
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
            if budget.check(), let end = addressNow() {
                changed = address(nodes[ElementKey(root)]?.attributes["AXURL"]?.value) != end
            }
        }
        var result = Self(snapshot: AXSnapshot(nodes: nodes), documentText: text, focusedPart: part, stop: budget.stopped,
                          elapsedMs: Int((now() &- began) / 1_000_000), navigationChanged: changed)
        result.omittedElements = omissions
        result.plainElements = plain
        return result
    }
}
