// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Prefer the natural container path to content over a wide census of window controls and sidebar rows.
/// The first live structural sample spent all 12 nodes before reaching the content (macOS 27.2, 28 Oct 2026).
public enum AXProbeDiscoveryPolicy {
    private static let terminalRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXTextField", "AXTextArea", "AXSearchField", "AXStaticText", "AXImage",
        "AXScrollBar", "AXOutline", "AXCheckBox", "AXRadioButton", "AXSlider",
    ]

    public static func descends(into role: String?) -> Bool {
        guard let role else { return false }
        return !terminalRoles.contains(role)
    }
}

/// The CLI and synthetic structural test use the same depth-first ordering. Paths retain original child indices,
/// including skipped controls, so fresh-reference acquisition can ask for that one index without a full rescan.
public struct AXProbeDiscovery<Node> {
    private var stack: [(node: Node, path: [Int])]
    public init(root: Node) { stack = [(root, [])] }
    public var pendingCount: Int { stack.count }

    public mutating func next() -> (node: Node, path: [Int])? { stack.popLast() }

    public mutating func append(_ children: [Node], under path: [Int]) {
        for (index, child) in children.prefix(8).enumerated().reversed() { stack.append((child, path + [index])) }
    }
}
