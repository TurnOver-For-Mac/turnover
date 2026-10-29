// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated package enum SystemSettingsPart: Int, CaseIterable, Sendable {
    case sidebar, pane, search
    package var name: String { switch self { case .sidebar: "sidebar"; case .pane: "settings pane"; case .search: "search" } }
}

nonisolated package struct SystemSettingsPartRequest: Sendable {
    package let pid: pid_t
    package let window: AXUIElement
    package let part: SystemSettingsPart
    package init(pid: pid_t, window: AXUIElement, part: SystemSettingsPart) { self.pid = pid; self.window = window; self.part = part }
}

nonisolated package struct SystemSettingsPartResolution: Sendable {
    package let target: AXUIElement
    package let canFocus: Bool
    package init(target: AXUIElement, canFocus: Bool) { self.target = target; self.canFocus = canFocus }
}

nonisolated package struct SystemSettingsFocusVerification: Sendable {
    package let focused: AXUIElement
    package let inside: Bool
    package init(focused: AXUIElement, inside: Bool = true) { self.focused = focused; self.inside = inside }
}

nonisolated package protocol SystemSettingsPartResolving: Sendable {
    func resolve(_ request: SystemSettingsPartRequest, current: @escaping @Sendable () -> Bool) -> SystemSettingsPartResolution?
    func verify(_ request: SystemSettingsPartRequest, target: AXUIElement, current: @escaping @Sendable () -> Bool) -> SystemSettingsFocusVerification?
}

nonisolated package struct SystemSettingsAXParts: SystemSettingsPartResolving {
    package init() {}
    package func resolve(_ request: SystemSettingsPartRequest, current: @escaping @Sendable () -> Bool) -> SystemSettingsPartResolution? {
        let lookup = SystemSettingsPartLookup(request, current: current)
        return lookup.run { lookup.resolve() }
    }
    package func verify(_ request: SystemSettingsPartRequest, target: AXUIElement,
                        current: @escaping @Sendable () -> Bool) -> SystemSettingsFocusVerification? {
        let lookup = SystemSettingsPartLookup(request, current: current)
        return lookup.run {
            guard let fresh = lookup.resolve(), CFEqual(fresh.target, target) else { return nil }
            return lookup.verifyFocus(inside: target)
        }
    }
    /// Delivery may be held while another window/sheet takes the keyboard. A few fresh structural queries on
    /// main protect the actual effect; discovery and ancestry walks remain on the worker, never in key lookup.
    package static func eligible(_ request: SystemSettingsPartRequest, focus: AXUIElement,
                                 current: @escaping @Sendable () -> Bool) -> Bool {
        let lookup = SystemSettingsPartLookup(request, current: current,
                                              limits: .init(durationNanoseconds: 100_000_000, queries: 16, nodes: 8, children: 0))
        return lookup.run { lookup.focusIsStill(focus) } ?? false
    }
}

/// The mutable discovery state lives only on the module's serial worker. Metadata and references are request-
/// local: a new focus, window or command never reuses a previous pane's controls (issue 183, 29 Oct 2026).
nonisolated private final class SystemSettingsPartLookup {
    private struct Info { let role: String; let subrole: String?; let identifier: String? }
    private let request: SystemSettingsPartRequest
    private let reader: AXNavigationChildren
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var metadata: [ElementKey: Info] = [:]
    private let splitIdentifier = "Main, SidebarNavigationSplitView"
    private let sidebarIdentifier = "com.apple.settings.sidebar.collectionView"
    private let terminals: Set<String> = ["AXOutline", "AXTable", "AXList", "AXRow", "AXCell", "AXButton", "AXStaticText",
        "AXTextField", "AXTextArea", "AXComboBox", "AXImage", "AXScrollBar", "AXToolbar", "AXMenu", "AXMenuBar"]

    init(_ request: SystemSettingsPartRequest, current: @escaping @Sendable () -> Bool,
         limits: AXNavigationChildren.Limits = .init(durationNanoseconds: 500_000_000, queries: 256, nodes: 128, children: 96, depth: 12)) {
        self.request = request
        reader = AXNavigationChildren(limits: limits, current: current)
    }

    func run<T>(_ body: () -> T?) -> T? {
        AXReadScope.with(while: { self.reader.check() }) { reader.check() ? body() : nil }
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard reader.check() else { return false }
        let key = ObjectIdentifier(element)
        if configured[key] != nil { return true }
        guard let result = reader.query({
            let start = DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetMessagingTimeout(element, 0.05)
            return AXQueryResult(value: error == .success, status: .returned(error),
                                 elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- start, wasAttempted: true)
        }), result.value == true else { return false }
        // Timeouts belong to the exact handle. Retain every configured object so its address cannot be reused.
        configured[key] = element
        return reader.check()
    }

    private func string(_ result: AXQueryResult<CFTypeRef>?) -> String? {
        guard let result else { return nil }
        if case .returned(let error) = result.status, [.cannotComplete, .invalidUIElement, .apiDisabled, .failure].contains(error) {
            reader.stop(.query(result.status)); return nil
        }
        guard let raw = result.value, CFGetTypeID(raw) == CFStringGetTypeID(), CFStringGetLength(raw as! CFString) <= 128 else { return nil }
        return raw as? String
    }

    private func info(_ element: AXUIElement) -> Info? {
        guard prepare(element) else { return nil }
        if let cached = metadata[ElementKey(element)] { return cached }
        guard metadata.count < 128 else { reader.stop(.nodeLimit); return nil }
        var batch: AXAttributeBatchResult?
        _ = reader.query {
            let value = element.attributesResult([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute])
            batch = value; return value.query
        }
        guard let batch, let role = string(batch.attributes[kAXRoleAttribute]), reader.check() else { return nil }
        let value = Info(role: role, subrole: string(batch.attributes[kAXSubroleAttribute]), identifier: string(batch.attributes[kAXIdentifierAttribute]))
        guard reader.check() else { return nil }
        metadata[ElementKey(element)] = value
        return value
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        prepare(element) ? reader.children(of: element) : []
    }

    private func element(_ attribute: String, of parent: AXUIElement) -> AXUIElement? {
        guard prepare(parent), let result = reader.query({ parent.attributeResult(attribute) }) else { return nil }
        return axElement(result.value)
    }

    private func absent(_ status: AXQueryStatus) -> Bool {
        guard case .returned(let error) = status else { return false }
        return [.attributeUnsupported, .noValue, .notImplemented].contains(error)
    }

    private func currentWindow() -> AXUIElement? {
        let app = AXUIElementCreateApplication(request.pid)
        guard let window = element(kAXFocusedWindowAttribute, of: app), CFEqual(window, request.window),
              let metadata = info(window), metadata.role == "AXWindow", !["AXDialog", "AXSystemDialog"].contains(metadata.subrole ?? "") else { return nil }
        guard let modal = reader.query({ window.attributeResult(kAXModalAttribute) }) else { return nil }
        if modal.status == .returned(.success) {
            guard let raw = modal.value, CFGetTypeID(raw) == CFBooleanGetTypeID(), raw as? Bool == false else { return nil }
        } else if !absent(modal.status) { return nil }
        guard let sheets = reader.query({ window.attributeResult(kAXSheetsAttribute) }) else { return nil }
        if sheets.status == .returned(.success) {
            guard let raw = sheets.value, CFGetTypeID(raw) == CFArrayGetTypeID(), CFArrayGetCount(raw as! CFArray) == 0 else { return nil }
        } else if !absent(sheets.status) { return nil }
        return reader.check() ? window : nil
    }

    private func find(in root: AXUIElement, depth: Int, stopAtScroll: Bool = false,
                      matching: (Info) -> Bool) -> [AXUIElement] {
        struct Pending { let element: AXUIElement; let depth: Int; let ancestors: Set<ElementKey> }
        var stack = [Pending(element: root, depth: 0, ancestors: [])], seen = Set<ElementKey>(), found: [AXUIElement] = []
        while let item = stack.popLast(), reader.check() {
            let key = ElementKey(item.element)
            guard !item.ancestors.contains(key) else { reader.stop(.cycle); return [] }
            guard seen.insert(key).inserted else { continue }
            guard let value = info(item.element) else { return [] }
            if matching(value) { found.append(item.element); continue }
            if terminals.contains(value.role) || (stopAtScroll && value.role == "AXScrollArea") { continue }
            let next = children(item.element)
            guard item.depth < depth || next.isEmpty else { reader.stop(.depthLimit); return [] }
            let ancestors = item.ancestors.union([key])
            stack.append(contentsOf: next.reversed().map { Pending(element: $0, depth: item.depth + 1, ancestors: ancestors) })
        }
        return reader.check() ? found : []
    }

    func resolve() -> SystemSettingsPartResolution? {
        guard let window = currentWindow() else { return nil }
        let splits = find(in: window, depth: 4) { $0.role == "AXSplitGroup" && $0.identifier == self.splitIdentifier }
        guard reader.check(), splits.count == 1, let split = splits.first else { return nil }
        let branches = children(split)
        var sidebars: [(AXUIElement, AXUIElement)] = [], searches: [(AXUIElement, AXUIElement)] = []
        var scrolls: [(AXUIElement, AXUIElement)] = []
        for branch in branches {
            guard reader.check(), let value = info(branch) else { return nil }
            if value.role == "AXSplitter" { continue }
            // Stop at the branch's outer scroller. Searching its entire settings pane for a sidebar would turn
            // these explicit part commands into a control/content walk and could confuse a pane's own search.
            let roots = find(in: branch, depth: 4) {
                $0.role == "AXScrollArea" || ($0.role == "AXOutline" && $0.identifier == self.sidebarIdentifier)
                    || ($0.role == "AXTextField" && $0.subrole == "AXSearchField")
            }
            for root in roots {
                guard let metadata = info(root) else { return nil }
                if metadata.role == "AXOutline" { sidebars.append((branch, root)) }
                else if metadata.role == "AXTextField" { searches.append((branch, root)) }
                else {
                    let contents = children(root)
                    let outlines = contents.filter {
                        guard let value = info($0) else { return false }
                        return value.role == "AXOutline" && value.identifier == sidebarIdentifier
                    }
                    for outline in outlines { sidebars.append((branch, outline)) }
                    if outlines.isEmpty { scrolls.append((branch, root)) }
                    else {
                        for field in contents {
                            guard let value = info(field) else { return nil }
                            if value.role == "AXTextField", value.subrole == "AXSearchField" { searches.append((branch, field)) }
                        }
                    }
                }
            }
        }
        guard reader.check() else { return nil }
        let target: AXUIElement
        switch request.part {
        case .sidebar:
            guard sidebars.count == 1 else { return nil }; target = sidebars[0].1
        case .search:
            guard searches.count == 1 else { return nil }; target = searches[0].1
        case .pane:
            guard sidebars.count == 1, searches.count == 1 else { return nil }
            let panes = scrolls.filter { !CFEqual($0.0, sidebars[0].0) && !CFEqual($0.0, searches[0].0) }.map(\.1)
            guard reader.check(), panes.count == 1 else { return nil }; target = panes[0]
        }
        guard prepare(target), AXHealth.backoff(for: request.pid) == nil else { return nil }
        let focus = reader.query {
            var settable: DarwinBoolean = false
            let start = DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementIsAttributeSettable(target, kAXFocusedAttribute as CFString, &settable)
            return AXQueryResult(value: settable.boolValue, status: .returned(error),
                                 elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds &- start, wasAttempted: true)
        }
        guard let focus, focus.status == .returned(.success), reader.check(), currentWindow() != nil else { return nil }
        return .init(target: target, canFocus: focus.value == true)
    }

    func verifyFocus(inside target: AXUIElement) -> SystemSettingsFocusVerification? {
        guard currentWindow() != nil, let focused = element(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(request.pid)) else { return nil }
        var cursor: AXUIElement? = focused, seen = Set<ElementKey>()
        for _ in 0..<12 {
            guard reader.check(), let next = cursor else { return nil }
            guard seen.insert(ElementKey(next)).inserted else { return nil }
            if CFEqual(next, target) { return .init(focused: focused) }
            if CFEqual(next, request.window) { return .init(focused: focused, inside: false) }
            cursor = element(kAXParentAttribute, of: next)
        }
        return nil   // clipped ancestry is not evidence that native focus stayed outside the part
    }

    func focusIsStill(_ expected: AXUIElement) -> Bool {
        guard currentWindow() != nil,
              let focused = element(kAXFocusedUIElementAttribute, of: AXUIElementCreateApplication(request.pid)) else { return false }
        return reader.check() && CFEqual(focused, expected)
    }
}
