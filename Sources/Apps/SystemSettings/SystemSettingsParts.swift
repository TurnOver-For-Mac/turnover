// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated package enum SystemSettingsPart: Int, CaseIterable, Sendable {
    case sidebar, pane, search
    package var name: String { switch self { case .sidebar: String(localized: "sidebar", comment: "A part of the System Settings window"); case .pane: String(localized: "settings pane", comment: "A part of the System Settings window"); case .search: String(localized: "search", comment: "A part of the System Settings window") } }
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
    /// The app's keyboard focus is already inside the part: nothing to write, only the cursor and the name.
    package let focusInside: Bool
    package init(target: AXUIElement, canFocus: Bool, focusInside: Bool = false) {
        self.target = target; self.canFocus = canFocus; self.focusInside = focusInside
    }
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
    /// Where a lookup writes how it went (the log; tests capture it).
    private let log: @Sendable (String) -> Void
    /// Tests only: an error the provider returns for an element's children, by attribute; nil asks the provider.
    private let childrenError: @Sendable (AXUIElement, String) -> AXError?
    package init(log: @escaping @Sendable (String) -> Void = { Log.info($0) },
                 childrenError: @escaping @Sendable (AXUIElement, String) -> AXError? = { _, _ in nil }) {
        self.log = log; self.childrenError = childrenError
    }
    package func resolve(_ request: SystemSettingsPartRequest, current: @escaping @Sendable () -> Bool) -> SystemSettingsPartResolution? {
        let lookup = SystemSettingsPartLookup(request, current: current, log: log, childrenError: childrenError)
        return lookup.run {
            guard let found = lookup.resolve() else { return nil }
            let inside = lookup.verifyFocus(inside: found.target)?.inside == true
            return .init(target: found.target, canFocus: found.canFocus, focusInside: inside)
        }
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
    // One reader per split-view branch: a reader that meets a provider error stays stopped, and one branch's error
    // must not end the others (issue 256: on macOS 27.2 the settings pane's branch answered -25201 and the sidebar
    // and search, already found, were lost with it, 8 Nov 2026).
    private var reader: AXNavigationChildren
    private let limits: AXNavigationChildren.Limits
    private let current: @Sendable () -> Bool
    private let childrenError: @Sendable (AXUIElement, String) -> AXError?
    private var ordinaryChildren = false
    private var phase = ""
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var metadata: [ElementKey: Info] = [:]
    private let splitIdentifier = "Main, SidebarNavigationSplitView"
    private let sidebarIdentifier = "com.apple.settings.sidebar.collectionView"
    private let terminals: Set<String> = ["AXOutline", "AXTable", "AXList", "AXRow", "AXCell", "AXButton", "AXStaticText",
        "AXTextField", "AXTextArea", "AXComboBox", "AXImage", "AXScrollBar", "AXToolbar", "AXMenu", "AXMenuBar"]
    // What the walks met, for the log when a part is not found (a found part logs one line, how its split view was found): a report of the commands failing on macOS 27.2 had
    // nothing to show the window's real tree (issue 256, 8 Nov 2026). Roles and subroles by level; identifiers
    // only of split groups and outlines, the two the lookup asks for. No names or values.
    private let log: @Sendable (String) -> Void
    private var levels: [String] = []
    private var deepSkipped = 0
    private var foundLevels: [ElementKey: Int] = [:]
    private var branchNotes: [String] = []

    init(_ request: SystemSettingsPartRequest, current: @escaping @Sendable () -> Bool,
         limits: AXNavigationChildren.Limits = .init(durationNanoseconds: 500_000_000, queries: 256, nodes: 128, children: 96, depth: 12),
         log: @escaping @Sendable (String) -> Void = { _ in },
         childrenError: @escaping @Sendable (AXUIElement, String) -> AXError? = { _, _ in nil }) {
        self.request = request
        self.log = log
        self.limits = limits; self.current = current; self.childrenError = childrenError
        reader = Self.reader(limits: limits, current: current, childrenError: childrenError)
    }

    private static func reader(limits: AXNavigationChildren.Limits, current: @escaping @Sendable () -> Bool,
                               childrenError: @escaping @Sendable (AXUIElement, String) -> AXError?) -> AXNavigationChildren {
        var source = AXNavigationChildren.Source()
        let count = source.count
        source.count = { element, attribute in
            guard let error = childrenError(element, attribute) else { return count(element, attribute) }
            return AXQueryResult(value: nil, status: .returned(error), elapsedNanoseconds: 0, wasAttempted: true)
        }
        return AXNavigationChildren(limits: limits, current: current, source: source)
    }

    func run<T>(_ body: () -> T?) -> T? {
        AXReadScope.with(while: { self.reader.check() }) { reader.check() ? body() : nil }
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard reader.check() else { return false }
        let key = ObjectIdentifier(element)
        if configured[key] != nil { return true }
        phase = "timeout setup"
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
        phase = "role"
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
        guard prepare(element) else { return [] }
        guard ordinaryChildren else { phase = "navigation-order children"; return reader.children(of: element) }
        // The other public route, for a branch whose navigation-order children failed: plain AXChildren, bounded.
        phase = "AXChildren"
        if let error = childrenError(element, kAXChildrenAttribute) { reader.stop(.query(.returned(error))); return [] }
        guard let result = reader.query({ element.attributeResult(kAXChildrenAttribute) }), result.status == .returned(.success),
              let raw = result.value, CFGetTypeID(raw) == CFArrayGetTypeID() else { return [] }
        guard CFArrayGetCount((raw as! CFArray)) <= 96 else { reader.stop(.childLimit); return [] }
        return ((raw as? [AnyObject]) ?? []).compactMap { axElement($0) }
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
        guard let sheets = reader.query({ window.attributeResult("AXSheets") }) else { return nil }
        if sheets.status == .returned(.success) {
            guard let raw = sheets.value, CFGetTypeID(raw) == CFArrayGetTypeID(), CFArrayGetCount(raw as! CFArray) == 0 else { return nil }
        } else if !absent(sheets.status) { return nil }
        return reader.check() ? window : nil
    }

    private func find(in root: AXUIElement, depth: Int, stopAtScroll: Bool = false, base: Int = 0,
                      matching: (Info) -> Bool) -> [AXUIElement] {
        struct Pending { let element: AXUIElement; let depth: Int; let ancestors: Set<ElementKey> }
        var stack = [Pending(element: root, depth: 0, ancestors: [])], seen = Set<ElementKey>(), found: [AXUIElement] = []
        while let item = stack.popLast(), reader.check() {
            let key = ElementKey(item.element)
            guard !item.ancestors.contains(key) else { reader.stop(.cycle); return [] }
            guard seen.insert(key).inserted else { continue }
            guard let value = info(item.element) else { return [] }
            record(value, level: base + item.depth)
            if matching(value) { found.append(item.element); foundLevels[key] = base + item.depth; continue }
            if terminals.contains(value.role) || (stopAtScroll && value.role == "AXScrollArea") { continue }
            // A branch deeper than the limit is skipped, not the whole search. The first branch to reach the limit
            // used to end it, so a split view elsewhere in the window was never found (issue 256).
            if item.depth >= depth { deepSkipped += 1; continue }
            let next = children(item.element)
            let ancestors = item.ancestors.union([key])
            stack.append(contentsOf: next.reversed().map { Pending(element: $0, depth: item.depth + 1, ancestors: ancestors) })
        }
        return reader.check() ? found : []
    }

    private func record(_ value: Info, level: Int) {
        guard levels.count < 64 else { return }
        let identifier = ["AXSplitGroup", "AXOutline"].contains(value.role) ? value.identifier.map { " #\($0)" } ?? " #none" : ""
        levels.append("\(level) \(value.role)\(value.subrole.map { "/\($0)" } ?? "")\(identifier)")
    }

    /// Logged once per failed lookup, unless a newer command cancelled it: that is not a failure to find.
    private func fail(_ step: String) -> SystemSettingsPartResolution? { fail(step, stop: reader.stopped) }

    /// A branch's reader is put back before its failure is logged, so the branch hands over its own stop reason:
    /// the main reader's says neither that a newer command cancelled the walk nor that the branch ran out of time.
    private func fail(_ step: String, stop: AXNavigationChildren.Stop?) -> SystemSettingsPartResolution? {
        if stop != .cancelled {
            log("System Settings: no \(request.part) (\(step)); stop \(stop.map { "\($0)" } ?? "none"), deep branches skipped \(deepSkipped)\(branchNotes.isEmpty ? "" : "; " + branchNotes.joined(separator: ", ")); levels: \(levels.joined(separator: "; "))")
        }
        return nil
    }

    private struct Found { var sidebars: [(AXUIElement, AXUIElement)] = [], searches: [(AXUIElement, AXUIElement)] = [], scrolls: [(AXUIElement, AXUIElement)] = [] }

    /// One branch's sidebar, search field and scroll areas, or nil when its reader stopped.
    private func parts(of branch: AXUIElement, level: Int) -> Found? {
        var found = Found()
        // Stop at the branch's outer scroller. Searching its entire settings pane for a sidebar would turn
        // these explicit part commands into a control/content walk and could confuse a pane's own search.
        let roots = find(in: branch, depth: 4, base: level) {
            $0.role == "AXScrollArea" || ($0.role == "AXOutline" && $0.identifier == self.sidebarIdentifier)
                || ($0.role == "AXTextField" && $0.subrole == "AXSearchField")
        }
        for root in roots {
            guard let metadata = info(root) else { return nil }
            if metadata.role == "AXOutline" { found.sidebars.append((branch, root)) }
            else if metadata.role == "AXTextField" { found.searches.append((branch, root)) }
            else {
                let contents = children(root)
                let outlines = contents.filter {
                    guard let value = info($0) else { return false }
                    return value.role == "AXOutline" && value.identifier == sidebarIdentifier
                }
                for outline in outlines { found.sidebars.append((branch, outline)) }
                if outlines.isEmpty { found.scrolls.append((branch, root)) }
                else {
                    for field in contents {
                        guard let value = info(field) else { return nil }
                        if value.role == "AXTextField", value.subrole == "AXSearchField" { found.searches.append((branch, field)) }
                    }
                }
            }
        }
        return reader.check() ? found : nil
    }

    func resolve() -> SystemSettingsPartResolution? {
        guard let window = currentWindow() else { return nil }
        // The split view by its identifier when it has one; otherwise the window's only split group, should a macOS
        // update rename it (issue 256). Two split groups and no identifier stay ambiguous: nothing is guessed.
        let splits = find(in: window, depth: 4) { $0.role == "AXSplitGroup" }
        guard reader.check() else { return fail("split view") }
        let named = splits.filter { metadata[ElementKey($0)]?.identifier == splitIdentifier }
        let byIdentifier = named.count == 1
        let asOnlySplitGroup = named.isEmpty && splits.count == 1
        let split: AXUIElement
        if byIdentifier {
            split = named[0]
        } else if asOnlySplitGroup {
            split = splits[0]
        } else {
            return fail("split view: \(splits.count) split groups, \(named.count) with its identifier")
        }
        let splitLevel = foundLevels[ElementKey(split)] ?? 0, branchLevel = splitLevel + 1
        let route = byIdentifier ? "by its identifier" : "as the only split group"
        let branches = children(split)
        var sidebars: [(AXUIElement, AXUIElement)] = [], searches: [(AXUIElement, AXUIElement)] = []
        var scrolls: [(AXUIElement, AXUIElement)] = []
        let main = reader
        for (index, branch) in branches.enumerated() {
            guard reader.check(), let value = info(branch) else { return fail("split view's branches") }
            if value.role == "AXSplitter" { continue }
            // The branch with its own reader: navigation-order children first, then plain AXChildren. A provider
            // error skips the branch, and only the branch; a cancel, deadline or limit still ends the lookup.
            var found: Found?
            for ordinary in [false, true] where found == nil {
                reader = Self.reader(limits: limits, current: current, childrenError: childrenError)
                ordinaryChildren = ordinary
                let attempt = parts(of: branch, level: branchLevel)
                let stop = reader.stopped, at = phase
                reader = main; ordinaryChildren = false
                // A provider error: noted, then the other route, or the branch is skipped.
                if case .query(let status)? = stop {
                    branchNotes.append("branch \(index + 1): \(ordinary ? "AXChildren" : "navigation-order") error \(status) at \(at)")
                    continue
                }
                // A cancel, deadline or limit ends the lookup, logged with the branch's own reason.
                let branchStopped = stop != nil
                let branchUnread = attempt == nil
                if branchStopped || branchUnread { return fail("split view's branches", stop: stop) }
                found = attempt
                if ordinary { branchNotes.append("branch \(index + 1): AXChildren worked") }
                break
            }
            guard let found else { branchNotes.append("branch \(index + 1) skipped"); continue }
            sidebars += found.sidebars; searches += found.searches; scrolls += found.scrolls
        }
        guard reader.check() else { return fail("split view's branches") }
        let target: AXUIElement
        switch request.part {
        case .sidebar:
            guard sidebars.count == 1 else { return fail("\(sidebars.count) sidebars") }; target = sidebars[0].1
        case .search:
            guard searches.count == 1 else { return fail("\(searches.count) search fields") }; target = searches[0].1
        case .pane:
            guard sidebars.count == 1, searches.count == 1 else { return fail("\(sidebars.count) sidebars, \(searches.count) search fields") }
            let panes = scrolls.filter { !CFEqual($0.0, sidebars[0].0) && !CFEqual($0.0, searches[0].0) }.map(\.1)
            guard reader.check(), panes.count == 1 else { return fail("\(panes.count) pane scroll areas") }; target = panes[0]
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
        // Which way the split view was found, so a report shows whether the identifier still holds (issue 256).
        log("System Settings: \(request.part) found; split view \(route), level \(splitLevel)\(branchNotes.isEmpty ? "" : "; " + branchNotes.joined(separator: ", "))")
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
