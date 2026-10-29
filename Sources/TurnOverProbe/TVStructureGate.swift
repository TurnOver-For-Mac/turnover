// SPDX-License-Identifier: GPL-3.0-or-later
// Issue 186 (from 182): compare TV's advertised sidebar selection routes without changing the running app.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runTVStructureGate(_ args: [String]) {
    guard args.isEmpty else {
        Log.line("tv-structure accepts no arguments; rejected arguments are not logged")
        return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TV").first else {
        Log.line("target=notRunning; nothing was opened or activated")
        return
    }
    Log.line("targetBundle=com.apple.TV targetIsFrontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier) probeAccessibilityTrusted=\(AXIsProcessTrusted()) permissionPromptRequested=false")
    TVStructureSample(pid: app.processIdentifier).run()
}

private final class TVStructureSample {
    private struct Metadata { let role: String?; let sectionList: Bool }
    private struct ElementArray {
        let values: [AXUIElement]
        let complete: Bool
        let available: Bool
    }
    private let pid: pid_t
    private var budget = CapabilitiesBudget(profile: .extended)
    // Apple's timeout is per exact object, not CFEqual identity. These objects stay retained until this
    // synchronous sample ends, preventing address reuse from skipping configuration of a new reference.
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var admitted = Set<ElementKey>(), walked = Set<ElementKey>(), sidebars = Set<ElementKey>()
    private var metadata: [ElementKey: Metadata] = [:], references: [ElementKey: Int] = [:]
    private var malformed = false, oversized = 0, skipped = 0, unvisited = 0
    private var lists = 0, sectionLists = 0, homeRows = 0, searchRows = 0
    private let started = DispatchTime.now().uptimeNanoseconds
    private static let leaves: Set<String> = ["AXButton", "AXStaticText", "AXImage", "AXTextField", "AXTextArea", "AXLink", "AXScrollBar", "AXRow", "AXCell"]

    init(pid: pid_t) { self.pid = pid }

    private func reference(_ element: AXUIElement?) -> String {
        guard let element else { return "unavailable" }
        let key = ElementKey(element)
        if let number = references[key] { return "e\(number)" }
        let number = references.count + 1
        references[key] = number
        return "e\(number)"
    }

    private func admit(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth <= budget.maximumDepth else { _ = budget.beginNode(depth: depth); return false }
        let key = ElementKey(element)
        if admitted.contains(key) { return budget.canContinue() }
        guard budget.beginNode(depth: depth) else { return false }
        admitted.insert(key)
        return true
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        guard admit(element, depth: 0) else { return false }
        let identity = ObjectIdentifier(element)
        if configured[identity] != nil { return budget.canContinue() }
        guard budget.beginQuery() else { return false }
        let error = AXUIElementSetMessagingTimeout(element, 0.05)
        Log.line("reference=\(reference(element)) query=timeoutConfiguration status=returned:\(describeError(error)) requestedMs=50")
        guard error == .success else { budget.stop(.timeoutConfiguration); return false }
        configured[identity] = element
        return budget.canContinue()
    }

    /// All provider calls use the known target PID, avoiding an implicit GetPid outside this allowance.
    private func query<Value>(_ element: AXUIElement, _ name: String,
                              _ body: () -> (Value?, AXError)) -> AXQueryResult<Value>? {
        guard prepare(element), budget.beginQuery() else { return nil }
        var value: Value?
        let execution = AXHealth.query(pid: pid) { let result = body(); value = result.0; return result.1 }
        let result = AXQueryResult(value: value, status: execution.status,
                                   elapsedNanoseconds: execution.elapsedNanoseconds, wasAttempted: execution.wasAttempted)
        Log.line("reference=\(reference(element)) query=\(name) \(AXDiagnosticReport.outcome(result)) hasValue=\(result.value != nil)")
        switch result.status {
        case .returned(let error):
            if error == .cannotComplete { budget.stop(.providerCannotComplete) }
            else if error == .apiDisabled { budget.stop(.accessibilityDenied) }
            else if error == .invalidUIElement { budget.stop(.clientStopped) }
        case .deferred: budget.stop(.clientBackoff)
        case .invalidResponse: malformed = true; budget.stop(.clientStopped)
        case .batchNull: break
        default: budget.stop(.clientStopped)
        }
        _ = budget.canContinue()
        return result
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AXQueryResult<CFTypeRef>? {
        query(element, name) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (value, error)
        }
    }

    private func element(_ target: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(target, name)?.value else { return nil }
        guard let found = axElement(raw) else { malformed = true; return nil }
        Log.line("reference=\(reference(target)) relationship=\(name) target=\(reference(found))")
        return found
    }

    private func string(_ result: AXQueryResult<CFTypeRef>?) -> String? {
        guard let raw = result?.value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { malformed = true; return nil }
        let string = raw as! CFString // type checked, capped before bridging any provider string
        guard CFStringGetLength(string) <= 128 else { oversized += 1; return nil }
        return raw as? String
    }

    private func info(_ element: AXUIElement) -> Metadata {
        let key = ElementKey(element)
        if let result = metadata[key] { return result }
        let role = string(attribute(element, kAXRoleAttribute))
        let subrole = role == "AXList" ? string(attribute(element, kAXSubroleAttribute)) : nil
        let result = Metadata(role: role, sectionList: role == "AXList" && subrole == "AXSectionList")
        metadata[key] = result
        return result
    }

    private func array(_ element: AXUIElement, _ name: String) -> ElementArray {
        let count = query(element, "\(name).count") {
            var value: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &value)
            return (value, error)
        }?.value
        if let count, count < 0 { malformed = true; return .init(values: [], complete: false, available: false) }
        if count == 0 {
            Log.line("reference=\(reference(element)) array=\(name) reportedCount=0 sampledCount=0 complete=true")
            return .init(values: [], complete: true, available: true)
        }
        let maximum = min(budget.maximumChildren, count ?? budget.maximumChildren)
        let result = query(element, "\(name).prefix") {
            var value: CFArray?
            let error = AXUIElementCopyAttributeValues(element, name as CFString, 0, maximum, &value)
            return (value, error)
        }
        guard let raw = result?.value else { return .init(values: [], complete: false, available: false) }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { malformed = true; return .init(values: [], complete: false, available: false) }
        let sample = AXDiagnosticReport.elements(in: raw, maximum: maximum)
        if sample.malformedCount > 0 || sample.returnedCount > maximum { malformed = true }
        budget.noteArray(total: count, received: sample.values.count)
        if count == nil, sample.values.count == maximum { budget.noteArray(total: maximum + 1, received: maximum) }
        let complete = count == sample.values.count && sample.malformedCount == 0 && sample.returnedCount <= maximum
        Log.line("reference=\(reference(element)) array=\(name) reportedCount=\(count.map(String.init) ?? "unknown") returnedCount=\(sample.returnedCount) sampledCount=\(sample.values.count) complete=\(complete) malformedMembers=\(sample.malformedCount)")
        return .init(values: sample.values, complete: complete, available: true)
    }

    private func selected(_ element: AXUIElement) -> String {
        guard let raw = attribute(element, kAXSelectedAttribute)?.value else { return "unavailable" }
        guard CFGetTypeID(raw) == CFBooleanGetTypeID() else { malformed = true; return "invalidType" }
        return CFBooleanGetValue(raw as! CFBoolean) ? "true" : "false" // checked CFBoolean
    }

    private func settable(_ element: AXUIElement, _ name: String) {
        let result = query(element, "\(name).settable") {
            var value: DarwinBoolean = false
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &value)
            return (value.boolValue, error)
        }
        Log.line("reference=\(reference(element)) capability=\(name).settable value=\(result?.value.map(String.init) ?? "unavailable") setterAttempted=false")
    }

    private func actions(_ element: AXUIElement) {
        let result = query(element, "actionNames") {
            var value: CFArray?
            let error = AXUIElementCopyActionNames(element, &value)
            return (value, error)
        }
        guard let array = result?.value else { return }
        guard CFGetTypeID(array) == CFArrayGetTypeID() else { malformed = true; return }
        let count = CFArrayGetCount(array), examined = min(budget.maximumChildren, CFArrayGetCount(array))
        var names: [String] = [], malformedMembers = 0, oversizedNames = 0
        withExtendedLifetime(array) {
            for index in 0..<examined {
                guard let pointer = CFArrayGetValueAtIndex(array, index) else { malformedMembers += 1; continue }
                let raw = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                guard CFGetTypeID(raw) == CFStringGetTypeID() else { malformedMembers += 1; continue }
                let value = raw as! CFString // type checked before length inspection and bounded bridge
                guard CFStringGetLength(value) <= 128 else { oversizedNames += 1; continue }
                if let name = raw as? String { names.append(name) } else { malformedMembers += 1 }
            }
        }
        malformed = malformed || malformedMembers > 0
        budget.noteArray(total: count, received: examined)
        // The shared report emits only fixed public action names and aggregate custom/unknown counts.
        Log.line("reference=\(reference(element)) actions returnedCount=\(count) examinedCount=\(examined) \(AXDiagnosticReport.actions(names)) malformedMembers=\(malformedMembers) oversizedNames=\(oversizedNames) clipped=\(count > examined)")
    }

    /// Labels are compared only with these public navigation constants. Neither unknown text nor identifiers
    /// enter a log, hash or reference name. No title/description is requested from the detail content tree.
    private func publicName(_ element: AXUIElement) -> String? {
        for attributeName in [kAXDescriptionAttribute, kAXTitleAttribute] {
            if let name = string(attribute(element, attributeName)), name == "Home" || name == "Search" { return name }
        }
        return nil
    }

    private func membership(_ row: AXUIElement, in selection: ElementArray) -> String {
        if selection.values.contains(where: { CFEqual($0, row) }) { return "member" }
        if !selection.available { return "unavailable" }
        return selection.complete ? "notMember" : "notInSampledPrefix"
    }

    private func sidebar(_ outline: AXUIElement, depth: Int) {
        guard sidebars.insert(ElementKey(outline)).inserted else { return }
        Log.line("knownPublic=Sidebar reference=\(reference(outline)) role=\(AXDiagnosticReport.role(info(outline).role)) selected=\(selected(outline))")
        actions(outline)
        settable(outline, kAXFocusedAttribute)
        settable(outline, kAXSelectedRowsAttribute)
        let selection = array(outline, kAXSelectedRowsAttribute)
        let rows = array(outline, kAXRowsAttribute)
        var unmatched = 0
        for row in rows.values {
            guard admit(row, depth: depth + 1) else { unvisited += 1; break }
            let first = array(row, kAXChildrenAttribute).values.first
            if let first, !admit(first, depth: depth + 2) { unvisited += 1; break }
            guard let name = first.flatMap(publicName) ?? publicName(row) else { unmatched += 1; continue }
            if name == "Home" { homeRows += 1 } else { searchRows += 1 }
            Log.line("knownPublic=\(name) target=row reference=\(reference(row)) role=\(AXDiagnosticReport.role(info(row).role)) AXSelectedRows=\(membership(row, in: selection)) selected=\(selected(row))")
            actions(row)
            settable(row, kAXFocusedAttribute)
            settable(row, kAXSelectedAttribute)
            if let first {
                Log.line("knownPublic=\(name) target=firstCell reference=\(reference(first)) role=\(AXDiagnosticReport.role(info(first).role)) AXSelectedRows=\(membership(first, in: selection)) selected=\(selected(first))")
                actions(first)
                settable(first, kAXFocusedAttribute)
            } else { Log.line("knownPublic=\(name) target=firstCell acquired=false") }
        }
        Log.line("knownPublic=Sidebar sampledRows=\(rows.values.count) unmatchedRows=\(unmatched) rowsComplete=\(rows.complete) selectedRowsComplete=\(selection.complete)")
    }

    private func equality(_ first: AXUIElement?, _ second: AXUIElement?) -> String {
        guard let first, let second else { return "unavailable" }
        return String(CFEqual(first, second))
    }

    private func focusWindow(_ focus: AXUIElement) -> AXUIElement? {
        if info(focus).role == "AXWindow" { Log.line("focusWindowSource=focusedElement"); return focus }
        if let window = element(focus, kAXWindowAttribute) { Log.line("focusWindowSource=AXWindow"); return window }
        var candidate = focus, seen: Set<ElementKey> = [ElementKey(focus)]
        for hop in 1...budget.maximumDepth {
            guard let parent = element(candidate, kAXParentAttribute), admit(parent, depth: hop) else { return nil }
            guard seen.insert(ElementKey(parent)).inserted else { malformed = true; return nil }
            let role = info(parent).role
            if role == "AXWindow" { Log.line("focusWindowSource=AXParent hops=\(hop)"); return parent }
            if role == "AXApplication" { return nil }
            candidate = parent
        }
        Log.line("focusWindowSource=notAcquired ancestorPathClipped=true")
        return nil
    }

    private func walk(_ roots: [AXUIElement]) {
        var stack = roots.reversed().map { ($0, 0) }
        while budget.canContinue(), let (target, depth) = stack.popLast() {
            guard walked.insert(ElementKey(target)).inserted else { continue }
            guard admit(target, depth: depth) else { unvisited += 1; continue }
            let data = info(target)
            if data.role == "AXList" { lists += 1 }
            if data.sectionList { sectionLists += 1 }
            Log.line("sample=structure reference=\(reference(target)) depth=\(depth) role=\(AXDiagnosticReport.role(data.role)) sectionList=\(data.sectionList)")
            if data.role == "AXOutline" {
                if string(attribute(target, kAXDescriptionAttribute)) == "Sidebar" { sidebar(target, depth: depth) }
                else { skipped += 1 }
                continue
            }
            guard let role = data.role, !Self.leaves.contains(role), role != "AXToolbar", role != "AXTable" else { skipped += 1; continue }
            guard depth < budget.maximumDepth else { _ = budget.beginNode(depth: depth + 1); unvisited += 1; continue }
            let ordinary = array(target, kAXChildrenAttribute)
            let navigation = array(target, "AXChildrenInNavigationOrder")
            let ordinaryKeys = Set(ordinary.values.map(ElementKey.init)), navigationKeys = Set(navigation.values.map(ElementKey.init))
            Log.line("reference=\(reference(target)) childrenComparison ordinarySampled=\(ordinary.values.count) navigationSampled=\(navigation.values.count) sharedSampled=\(ordinaryKeys.intersection(navigationKeys).count) ordinaryComplete=\(ordinary.complete) navigationComplete=\(navigation.complete)")
            var combined = ordinary.values
            combined.append(contentsOf: navigation.values.filter { !ordinaryKeys.contains(ElementKey($0)) })
            stack.append(contentsOf: combined.reversed().map { ($0, depth + 1) })
        }
        unvisited += stack.count
    }

    func run() {
        Log.line("method=boundedTVStructure healthScope=probeProcess policy=respectBackoff")
        Log.line("bounds queriesAndTimeoutSetups=512 nodes=64 depth=12 arrayPrefix=8 cooperativeDeadlineMs=2000 timeoutPerExactReferenceMs=50")
        Log.line("knownPublicNames=[Home,Search,Sidebar] arbitraryLabelsLogged=false identifiersRead=false textValuesRead=false customActionStringsLogged=false actionsAttempted=0 selectionWrites=0 focusWrites=0 flagsWritten=0 activationAttempted=false")
        Log.line("actionNames=oneNonpaginatedProviderCallWithEightNameClientDecoding; caller must impose an external process deadline")
        defer {
            Log.line("summary queries=\(budget.queries) nodes=\(budget.nodes) structuralNodes=\(walked.count) sidebars=\(sidebars.count) HomeRows=\(homeRows) SearchRows=\(searchRows) AXLists=\(lists) AXSectionLists=\(sectionLists) stop=\(budget.stopped?.rawValue ?? "sampleFinished") depthClipped=\(budget.depthClipped) arraysClipped=\(budget.arraysClipped) skippedBranches=\(skipped) unvisitedBranches=\(unvisited) malformed=\(malformed) oversizedMetadata=\(oversized) wallMs=\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) providerTreeComplete=false")
            Log.line("selectionMembership=sampledReferencesOnly structuralCounts=sampledOnly; eight-child prefixes cannot establish absence elsewhere; advertised actions and settable attributes do not establish selection or action success")
        }
        let app = AXUIElementCreateApplication(pid)
        let focused = element(app, kAXFocusedWindowAttribute)
        let main = element(app, kAXMainWindowAttribute)
        let focus = element(app, kAXFocusedUIElementAttribute)
        let owner = focus.flatMap(focusWindow)
        Log.line("windowRelationship focused=\(reference(focused)) main=\(reference(main)) same=\(equality(focused, main)) focusedElement=\(reference(focus)) focusWindow=\(reference(owner)) focusWindowIsFocused=\(equality(owner, focused)) focusWindowIsMain=\(equality(owner, main))")
        if let focus { Log.line("sample=actualFocus role=\(AXDiagnosticReport.role(info(focus).role))") }
        let roots = [focused, main].compactMap { $0 }
        guard !roots.isEmpty else { Log.line("window=notAcquired; no empty-provider conclusion"); return }
        walk(roots)
    }
}
