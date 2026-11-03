// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated package enum GoogleDocsRead: Sendable {
    case announcements(editor: AXUIElement, region: AXUIElement?)
    case support
}

nonisolated package enum GoogleDocsResult: Sendable {
    case announcements(region: AXUIElement?, text: String)
    case support(Bool)
    case differentDocument
    case unavailable
}

/// Only immutable identities cross to this collector. All AX walks share a cooperative time/query budget;
/// provider errors and a cut-short search never establish that screen reader support is off.
nonisolated package enum GoogleDocsQuery {
    package static func read(_ context: DocumentContext, _ kind: GoogleDocsRead, request: AXWalkRequest) -> GoogleDocsResult {
        let support: Bool
        if case .support = kind { support = true } else { support = false }
        let budget = AXWalkBudget(request: request, duration: support ? 250_000_000 : 400_000_000,
                                  maxVisits: support ? 900 : 4500, maxQueries: 32_000, maxAXQueries: 32_000, maxDepth: 60)
        return read(context, kind, budget: budget)
    }

    package static func read(_ context: DocumentContext, _ kind: GoogleDocsRead, budget: AXWalkBudget) -> GoogleDocsResult {
        let result = AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            guard url(of: context.root) == context.url else { return GoogleDocsResult.differentDocument }
            let result: GoogleDocsResult
            switch kind {
            case .support:
                guard let found = accessibilityMenu(context.root, budget: budget) else { return .unavailable }
                result = .support(found)
            case .announcements(let editor, let cached):
                guard ["AXTextArea", "AXTextField"].contains(editor.role), editor.string(kAXSubroleAttribute) != "AXSecureTextField",
                      inside(editor, root: context.root, budget: budget) else { return .differentDocument }
                var region = cached
                if let known = region, known.string("AXDOMIdentifier") != "docs-aria-speakable" || !inside(known, root: context.root, budget: budget) { region = nil }
                if region == nil {
                    guard let search = findRegion(context.root, budget: budget) else { return .unavailable }
                    region = search.first
                }
                if let region {
                    guard let text = currentText(region, budget: budget) else { return .unavailable }
                    result = .announcements(region: region, text: text)
                } else { result = .announcements(region: nil, text: "") }
            }
            // Safari can reuse the same AX root for another address while a collection is in flight.
            return url(of: context.root) == context.url ? result : .differentDocument
        }
        return budget.check() ? result : .unavailable
    }

    private static func url(of root: AXUIElement) -> String {
        let value = root.attr("AXURL")
        return (value as? URL)?.absoluteString ?? (value as? String) ?? ""
    }

    private static func inside(_ element: AXUIElement, root: AXUIElement, budget: AXWalkBudget) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<30 {
            guard budget.visit(), let node = current else { return false }
            if node.isSame(root) { return true }
            current = node.element(kAXParentAttribute)
        }
        return false
    }

    private static func isNew(_ element: AXUIElement, seen: inout [CFHashCode: [AXUIElement]]) -> Bool {
        let hash = CFHash(element)
        if seen[hash]?.contains(where: { $0.isSame(element) }) == true { return false }
        seen[hash, default: []].append(element)
        return true
    }

    /// An empty array means a complete search found no region; nil is an incomplete search.
    private static func findRegion(_ root: AXUIElement, budget: AXWalkBudget) -> [AXUIElement]? {
        var queue: [(AXUIElement, Int)] = [(root, 0)], head = 0
        var truncated = false
        var seen: [CFHashCode: [AXUIElement]] = [:]
        while head < queue.count {
            guard head < 4000, budget.visit() else { return nil }
            let (node, depth) = queue[head]; head += 1
            guard budget.depth(depth), isNew(node, seen: &seen) else { return nil }
            if node.string("AXDOMIdentifier") == "docs-aria-speakable" { return [node] }
            let children = node.elements(kAXChildrenAttribute), room = 4000 - queue.count
            guard budget.check() else { return nil }
            if children.count > room { truncated = true }
            queue.append(contentsOf: children.prefix(room).map { ($0, depth + 1) })
        }
        return budget.check() && !truncated ? [] : nil
    }

    private static func currentText(_ root: AXUIElement, budget: AXWalkBudget) -> String? {
        var stack: [(AXUIElement, Int)] = [(root, 0)], parts: [String] = [], count = 0, length = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        while let (node, depth) = stack.popLast() {
            guard count < 200, budget.visit(), budget.depth(depth), isNew(node, seen: &seen) else { return nil }
            count += 1
            if node.role == "AXStaticText", let value = node.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                length += value.utf16.count
                guard length <= 16_384 else { return nil }
                parts.append(value)
            }
            let children = node.elements(kAXChildrenAttribute)
            guard budget.check(), children.count <= 200 - count - stack.count else { return nil }
            stack.append(contentsOf: children.reversed().map { ($0, depth + 1) })
        }
        return budget.check() ? parts.joined(separator: " ") : nil
    }

    private static func accessibilityMenu(_ root: AXUIElement, budget: AXWalkBudget) -> Bool? {
        var queue: [(AXUIElement, Int)] = [(root, 0)], head = 0
        var truncated = false
        var seen: [CFHashCode: [AXUIElement]] = [:]
        while head < queue.count {
            guard head < 800, budget.visit() else { return nil }
            let (node, depth) = queue[head]; head += 1
            guard budget.depth(depth), isNew(node, seen: &seen) else { return nil }
            let names = [node.string(kAXTitleAttribute), node.string(kAXDescriptionAttribute)].compactMap { $0 }
            if ["AXButton", "AXMenuButton", "AXMenuItem", "AXStaticText"].contains(node.role), names.contains("Accessibility") { return true }
            let children = node.elements(kAXChildrenAttribute), room = 800 - queue.count
            guard budget.check() else { return nil }
            if children.count > room { truncated = true }
            queue.append(contentsOf: children.prefix(room).map { ($0, depth + 1) })
        }
        return budget.check() && !truncated ? false : nil
    }
}
