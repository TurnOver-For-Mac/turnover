// SPDX-License-Identifier: GPL-3.0-or-later
// Reading-order search used outside documents by VO-Command-letter. Providers keep AX and fake-tree tests on
// the same traversal; the main actor only admits and publishes a current result (issue 119, 28 Oct 2026).
import TurnOverAX

nonisolated package enum WindowSearchStart<Node: Sendable>: Sendable {
    case ready(Node)
    case unavailable
    case incomplete(AXWalkStop)
}

nonisolated package enum WindowSearchPreflight {
    /// A stale explicit review cursor may fall back to the current focus. Ignore invalidUIElement only for this
    /// one validation, not later traversal failures or cannotComplete/apiDisabled. Both scopes still count queries
    /// and stop for cancellation/deadlines; caller-owned messaging timeouts remain unchanged (28 Oct 2026).
    package static func resolve<Node: Sendable>(cursor: Node?, focus: Node?, budget: AXWalkBudget,
                                               role: (Node) -> AXQueryResult<String>) -> WindowSearchStart<Node> {
        guard let start = cursor ?? focus else { return .unavailable }
        guard let cursor else { return .ready(start) }
        return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { status in
            if status != .returned(.invalidUIElement) { budget.record(status) }
        }) {
            guard let result = budget.query({ role(cursor) }) else { return .incomplete(budget.stopped ?? .cancelled) }
            if result.error == .invalidUIElement || result.value == nil || result.value == "?" {
                guard let focus else { return .unavailable }
                return .ready(focus)
            }
            return .ready(cursor)
        }
    }
}

nonisolated package enum WindowKindSearchResult<Node: Sendable>: Sendable {
    case found(Node)
    case end
    case unavailable
    case incomplete(AXWalkStop)
}

nonisolated package struct WindowKindQueries<Node: Sendable, Identity: Hashable>: Sendable {
    package let identity: @Sendable (Node) -> Identity
    package let window: @Sendable (Node) -> Node?
    package let children: @Sendable (Node) -> [Node]
    package let parent: @Sendable (Node) -> Node?
    package let descends: @Sendable (Node) -> Bool
    package let matches: @Sendable (Node) -> Bool
    package let neighbourRow: @Sendable (Node, Node, Int) -> Node?

    package init(identity: @escaping @Sendable (Node) -> Identity, window: @escaping @Sendable (Node) -> Node?,
                 children: @escaping @Sendable (Node) -> [Node], parent: @escaping @Sendable (Node) -> Node?,
                 descends: @escaping @Sendable (Node) -> Bool, matches: @escaping @Sendable (Node) -> Bool,
                 neighbourRow: @escaping @Sendable (Node, Node, Int) -> Node?) {
        self.identity = identity; self.window = window; self.children = children; self.parent = parent
        self.descends = descends; self.matches = matches; self.neighbourRow = neighbourRow
    }
}

nonisolated package struct WindowKindSearch<Node: Sendable, Identity: Hashable> {
    package let queries: WindowKindQueries<Node, Identity>
    package var budget: AXWalkBudget

    package init(queries: WindowKindQueries<Node, Identity>, budget: AXWalkBudget) {
        self.queries = queries; self.budget = budget
    }

    package mutating func find(from start: Node, forward: Bool) -> WindowKindSearchResult<Node> {
        let q = queries
        guard let reply = budget.query({ q.window(start) }), let root = reply else {
            return budget.stopped.map(WindowKindSearchResult.incomplete) ?? .unavailable
        }
        let sameRoot = q.identity(start) == q.identity(root)
        var node: Node? = start
        var first = !sameRoot
        if sameRoot { node = forward ? budget.query({ q.children(root) })?.first : nil }
        var seen = Set<Identity>()
        var depth = 0
        while let current = node, budget.visit() {
            guard seen.insert(q.identity(current)).inserted else { return .incomplete(.cycle) }
            if !first, let matches = budget.query({ q.matches(current) }), matches { return .found(current) }
            first = false
            node = forward ? next(after: current, root: root, depth: &depth) : previous(before: current, root: root, depth: &depth)
        }
        return budget.stopped.map(WindowKindSearchResult.incomplete) ?? .end
    }

    private mutating func next(after start: Node, root: Node, depth: inout Int) -> Node? {
        let q = queries
        if let descends = budget.query({ q.descends(start) }), descends,
           let children = budget.query({ q.children(start) }), let first = children.first {
            depth += 1
            return budget.depth(depth) ? first : nil
        }
        var node = start
        var hops = 0
        var seen = Set<Identity>()
        while q.identity(node) != q.identity(root), budget.check() {
            guard seen.insert(q.identity(node)).inserted else { budget.halt(.cycle); return nil }
            hops += 1
            guard budget.depth(hops), let reply = budget.query({ q.parent(node) }), let parent = reply else { return nil }
            if let reply = budget.query({ q.neighbourRow(node, parent, 1) }), let row = reply { return row }
            guard let siblings = budget.query({ q.children(parent) }) else { return nil }
            if let i = siblings.firstIndex(where: { q.identity($0) == q.identity(node) }), i + 1 < siblings.count { return siblings[i + 1] }
            node = parent
            depth = max(0, depth - 1)
        }
        return nil
    }

    private mutating func previous(before start: Node, root: Node, depth: inout Int) -> Node? {
        let q = queries
        guard q.identity(start) != q.identity(root), let reply = budget.query({ q.parent(start) }), let parent = reply else { return nil }
        var node: Node
        if let reply = budget.query({ q.neighbourRow(start, parent, -1) }), let row = reply { node = row }
        else {
            guard let siblings = budget.query({ q.children(parent) }),
                  let i = siblings.firstIndex(where: { q.identity($0) == q.identity(start) }), i > 0 else {
                depth = max(0, depth - 1)
                return q.identity(parent) == q.identity(root) ? nil : parent
            }
            node = siblings[i - 1]
        }
        var hops = 0
        var seen = Set<Identity>()
        while budget.check() {
            guard seen.insert(q.identity(node)).inserted else { budget.halt(.cycle); return nil }
            guard let descends = budget.query({ q.descends(node) }), descends,
                  let children = budget.query({ q.children(node) }), let last = children.last else { break }
            hops += 1
            depth += 1
            guard budget.depth(hops), budget.depth(depth) else { return nil }
            node = last
        }
        return node
    }
}
