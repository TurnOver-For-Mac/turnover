// SPDX-License-Identifier: GPL-3.0-or-later
// One copy of a window's accessibility tree, as plain values. Prototype, 10 Nov 2026; nothing in the reader uses it yet.
//
// Why: the page buffer, VO Left and Right, the kind search, the panes, Find and the Item Chooser each walk the live
// tree in their own way, mostly one attribute a question and often on main (the architecture review, 10 Nov 2026).
// A snapshot is taken once, off main, one question an element (or one a subtree where AXHierarchyBridge answers),
// and then read as often as wanted with no question to the app at all: ordering, searching and naming become pure
// functions over it, testable from a recording.
//
// A snapshot is a moment: an element in it may be gone by the time it is acted on. Callers act through
// `Node.element`, which fails as any stale element does, and take a new snapshot when the app says something changed.
import Foundation
import ApplicationServices

public struct AXSnapshot: Sendable {
    public enum Value: Equatable, Sendable {
        case text(String)
        case number(Double)
    }

    public struct Node: Sendable {
        public let element: AXUIElement
        /// Index of the parent in `nodes`; nil for the root.
        public let parent: Int?
        public internal(set) var children: [Int] = []
        public var role = ""
        public var subrole: String?
        public var title: String?
        /// AXDescription: what most controls without a title are named by.
        public var label: String?
        public var value: Value?
        public var identifier: String?
        /// The app's own word for the kind of thing ("button", "close button").
        public var roleDescription: String?
        /// How many children the app listed, whether or not a limit let them into the snapshot.
        public var listedChildren = 0
        public var frame: CGRect?
        public var enabled: Bool?
        public let depth: Int
        /// The attributes as the app gave them, for AXAttributeCache: an attribute asked for and absent here had no
        /// value.
        var raw = Raw()
        /// False when the app gave nothing for this element (a failed read, or a subtree a limit cut off).
        public var isFilled = false
    }

    /// The app's own answers, kept as they came.
    /// @unchecked: the values are what the accessibility API returned (CFString, CFNumber, CFBoolean, AXValue, CFURL,
    /// arrays of those and of AXUIElement), all immutable once made; the dictionary is written once, in the capture's
    /// thread, before the snapshot leaves it, and only read afterwards.
    struct Raw: @unchecked Sendable { var values: [String: AnyObject] = [:] }

    /// Why a snapshot is not the whole tree.
    public enum Stop: String, Sendable {
        case nodes, depth, deadline, clientStopped
        /// The whole-subtree read timed out: the app is still busy with it, and asking more now would only queue
        /// behind that and get the app rested. Take another snapshot later; it will use the batched read.
        case appBusy
        /// AXHealth is resting the app (it timed out or dripped): nothing more was asked.
        case appResting
    }
    /// How the elements were read: the private whole-subtree call, the public batched read, or both.
    public struct Source: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let hierarchy = Source(rawValue: 1)
        public static let batched = Source(rawValue: 2)
    }

    /// Preorder: a node comes before its descendants, and children in the app's own order. `nodes[0]` is the root.
    public internal(set) var nodes: [Node] = []
    public internal(set) var stop: Stop?
    public internal(set) var source: Source = []
    /// Questions asked of the app to build this.
    public internal(set) var questions = 0
    public internal(set) var milliseconds = 0.0
    /// The attributes every element was asked for.
    public internal(set) var names: [String] = []
    /// Rows of tables and outlines left out because they were scrolled out of sight (`onScreenRowsOnly`).
    public internal(set) var rowsLeftOut = 0
    private var indexByElement: [ElementKey: Int] = [:]

    /// Nodes the app gave nothing for.
    public var unfilledCount: Int { nodes.reduce(0) { $0 + ($1.isFilled ? 0 : 1) } }
    /// Nothing stopped it and every element answered.
    public var isComplete: Bool { stop == nil && unfilledCount == 0 }
    public func index(of element: AXUIElement) -> Int? { indexByElement[ElementKey(element)] }

    /// The node and everything under it, in order.
    public func subtree(_ index: Int) -> Range<Int> {
        guard nodes.indices.contains(index) else { return 0..<0 }
        let depth = nodes[index].depth
        var end = index + 1
        while end < nodes.count, nodes[end].depth > depth { end += 1 }
        return index..<end
    }

    /// The first node at or after `start` (in order) that matches; the building block for "next heading" and its kin.
    public func first(from start: Int = 0, where matches: (Node) -> Bool) -> Int? {
        guard start < nodes.count else { return nil }
        return nodes[max(0, start)...].firstIndex(where: matches)
    }

    mutating func append(_ node: Node) -> Int {
        let index = nodes.count
        nodes.append(node)
        indexByElement[ElementKey(node.element)] = index
        if let parent = node.parent { nodes[parent].children.append(index) }
        return index
    }
}

public struct AXSnapshotLimits: Sendable {
    public var maxNodes: Int
    public var maxDepth: Int
    public var seconds: Double
    public init(maxNodes: Int = 6000, maxDepth: Int = 60, seconds: Double = 2) {
        self.maxNodes = maxNodes; self.maxDepth = maxDepth; self.seconds = seconds
    }
}

public enum AXSnapshotCapture {
    /// What a snapshot holds for each element. Children first: the batched read's answer is indexed by position.
    public static let names: [String] = [kAXChildrenAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                  kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute,
                                  kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXRoleDescriptionAttribute]

    /// Copies the tree under `root`. Synchronous and slow by design: call it off main, inside the caller's
    /// AXReadScope when it has one (every question here goes through AXHealth, so a scope's cancellation and query
    /// budget apply, and a resting app is not asked). `useHierarchy` asks for the whole subtree in one question first
    /// (AXHierarchyBridge); off unless asked for.
    ///
    /// `onScreenRowsOnly` leaves out the rows of a table or outline that are scrolled out of sight, where the app
    /// says which rows are showing. An app builds the rows on screen and makes the others up each time it is
    /// asked: in Mail's message list a row out of sight cost seven times one on screen (0.83 ms an element against
    /// 0.12), and 397 loaded rows with some 20 showing took two of the Item Chooser's two seconds (10 Nov 2026).
    public static func capture(_ root: AXUIElement, limits: AXSnapshotLimits = AXSnapshotLimits(),
                               useHierarchy: Bool = false, onScreenRowsOnly: Bool = false,
                               names: [String] = AXSnapshotCapture.names) -> AXSnapshot {
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started &+ UInt64(max(0, limits.seconds) * 1e9)
        var builder = Builder(limits: limits, deadline: deadline, useHierarchy: useHierarchy)
        builder.onScreenRowsOnly = onScreenRowsOnly
        // Children always, and first: the walk itself needs them.
        builder.names = [kAXChildrenAttribute] + names.filter { $0 != kAXChildrenAttribute }
        builder.snapshot.names = builder.names
        builder.run(root)
        builder.snapshot.milliseconds = Double(DispatchTime.now().uptimeNanoseconds &- started) / 1e6
        return builder.snapshot
    }

    /// A snapshot from attributes already in hand, with no question to any app: for the tests, and for a caller that
    /// has a hierarchy answer of its own.
    package static func assemble(root: AXUIElement, entries: [ElementKey: AXHierarchyBridge.Entry],
                                 limits: AXSnapshotLimits = AXSnapshotLimits()) -> AXSnapshot {
        var builder = Builder(limits: limits, deadline: .max, useHierarchy: false, liveReads: false)
        builder.known = entries
        builder.run(root)
        return builder.snapshot
    }

    private struct Builder {
        let limits: AXSnapshotLimits
        let deadline: UInt64
        let useHierarchy: Bool
        var liveReads = true
        var snapshot = AXSnapshot()
        /// Elements a hierarchy answer has already described.
        var known: [ElementKey: AXHierarchyBridge.Entry] = [:]
        var seen = Set<ElementKey>()
        var isRoot = true
        var names = AXSnapshotCapture.names
        var onScreenRowsOnly = false
        /// Tables and outlines (by node index) whose off-screen rows were left out: their columns are not gone into
        /// either, since a column lists every row's cell again.
        var trimmedTables = Set<Int>()

        mutating func run(_ root: AXUIElement) {
            // An explicit stack, deepest last: a deep tree must not be able to overflow the thread's own.
            var stack: [(element: AXUIElement, parent: Int?, depth: Int)] = [(root, nil, 0)]
            while let next = stack.popLast() {
                guard snapshot.nodes.count < limits.maxNodes else { snapshot.stop = .nodes; return }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { snapshot.stop = .deadline; return }
                guard AXReadScope.shouldContinue else { snapshot.stop = .clientStopped; return }
                // An app may list one element under two parents, or a parent under its own child: each element once.
                guard seen.insert(ElementKey(next.element)).inserted else { continue }
                var node = AXSnapshot.Node(element: next.element, parent: next.parent, depth: next.depth)
                let attributes = read(next.element)
                if let attributes { fill(&node, attributes) }
                let index = snapshot.append(node)
                if snapshot.stop == .appBusy || snapshot.stop == .appResting { return }
                guard let attributes, let children = attributes[kAXChildrenAttribute] as? [AnyObject], !children.isEmpty else { continue }
                guard next.depth < limits.maxDepth else { snapshot.stop = .depth; continue }
                if node.role == "AXColumn", let parent = next.parent, trimmedTables.contains(parent) { continue }
                let hidden = onScreenRowsOnly && liveReads && (node.role == "AXTable" || node.role == "AXOutline")
                    ? rowsOutOfSight(next.element) : []
                if !hidden.isEmpty { trimmedTables.insert(index); snapshot.rowsLeftOut += hidden.count }
                for child in children.reversed() {
                    if let element = axElement(child), hidden.isEmpty || !hidden.contains(ElementKey(element)) {
                        stack.append((element, index, next.depth + 1))
                    }
                }
            }
        }

        /// The table's or outline's rows that are not among the rows it says are showing. Empty when it does not say
        /// (then every row is taken, as before), or when all of them are showing.
        private mutating func rowsOutOfSight(_ table: AXUIElement) -> Set<ElementKey> {
            snapshot.questions += 1
            let visible = (table.attr("AXVisibleRows") as? [AXUIElement]) ?? []
            guard !visible.isEmpty else { return [] }
            snapshot.questions += 1
            let rows = (table.attr(kAXRowsAttribute) as? [AXUIElement]) ?? []
            guard rows.count > visible.count else { return [] }
            return Set(rows.map(ElementKey.init)).subtracting(visible.map(ElementKey.init))
        }

        /// The element's attributes: from the hierarchy answer if it covers the element, and otherwise by the public
        /// batched read. The whole-subtree question is asked once, at the root, and never again into what it left
        /// unfilled: see AXHierarchyBridge for what happened when it was.
        private mutating func read(_ element: AXUIElement) -> [String: AnyObject]? {
            let key = ElementKey(element)
            let atRoot = isRoot
            isRoot = false
            guard liveReads else { return known[key].flatMap { $0.incomplete ? nil : $0.attributes } }
            if atRoot, useHierarchy, !AXHierarchyBridge.timedOutRecently(element.pid) {
                snapshot.questions += 1
                switch AXHierarchyBridge.copy(element, names) {
                case .answer(let answer):
                    snapshot.source.insert(.hierarchy)
                    known = answer
                case .timedOut:
                    snapshot.stop = .appBusy
                    return nil
                case .unavailable: break
                }
            }
            if let entry = known[key], !entry.incomplete { return entry.attributes }
            snapshot.questions += 1
            let attributes = element.attrs(names)
            if attributes.isEmpty {
                if AXHealth.backoff(for: element.pid) != nil { snapshot.stop = .appResting }
                return nil
            }
            snapshot.source.insert(.batched)
            return attributes
        }

        private func fill(_ node: inout AXSnapshot.Node, _ a: [String: AnyObject]) {
            node.isFilled = true
            // A batched read gives a null for an attribute with no value; asked for alone, the app gives nothing.
            node.raw.values = a.filter { !($0.value is NSNull) }
            node.role = a[kAXRoleAttribute] as? String ?? ""
            node.subrole = a[kAXSubroleAttribute] as? String
            node.title = (a[kAXTitleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
            node.label = (a[kAXDescriptionAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
            node.identifier = a[kAXIdentifierAttribute] as? String
            node.roleDescription = a[kAXRoleDescriptionAttribute] as? String
            node.listedChildren = (a[kAXChildrenAttribute] as? [AnyObject])?.count ?? 0
            if let value = a[kAXValueAttribute] {
                if let text = value as? String { node.value = .text(text) }
                // A CFBoolean is an NSNumber too: a ticked box is 1, as the app reports it.
                else if let number = value as? NSNumber { node.value = .number(number.doubleValue) }
            }
            if let enabled = a[kAXEnabledAttribute] as? Bool { node.enabled = enabled }
            var origin = CGPoint.zero, size = CGSize.zero
            if axValue(a[kAXPositionAttribute], .cgPoint, &origin), axValue(a[kAXSizeAttribute], .cgSize, &size) {
                node.frame = CGRect(origin: origin, size: size)
            }
        }
    }
}
