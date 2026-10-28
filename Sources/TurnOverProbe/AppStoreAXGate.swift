// SPDX-License-Identifier: GPL-3.0-or-later
// Issue 166: a small sample of the provider's structure, not a tree dump or a VoiceOver capability probe.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runAppStoreAXGate(_ args: [String]) {
    guard args.allSatisfy({ $0 == "--direct" }) else {
        Log.line("appstore-ax accepts only optional --direct; labels and arbitrary targets are not supported")
        return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.AppStore").first else {
        Log.line("App Store is not running; no application was opened or activated")
        return
    }
    let probe = AppStoreAXSample(pid: app.processIdentifier, direct: args.contains("--direct"))
    let bundle = app.bundleURL.flatMap { Bundle(url: $0) }
    func version(_ key: String) -> String {
        guard let value = bundle?.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0) }) else { return "unavailable" }
        return value
    }
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    let voiceOverPresent = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
    Log.line("probeAccessibilityTrusted=\(AXIsProcessTrusted()) permissionPromptRequested=false")
    Log.line("targetBundle=com.apple.AppStore version=\(version("CFBundleShortVersionString")) build=\(version("CFBundleVersion")) targetIsFrontmost=\(frontmost)")
    Log.line("VoiceOverProcessPresent=\(voiceOverPresent) readerActive=unobserved muteLease=unobserved")
    probe.run()
}

private final class AppStoreAXSample {
    private let pid: pid_t
    private let policy: AXQueryPolicy
    private let direct: Bool
    private var budget = AXProbeBudget()
    // Apple's timeout is per object, not per CFEqual identity. Retaining configured objects also prevents a
    // deallocated object's address from being reused as an apparently configured reference within the sample.
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var references: [ElementKey: Int] = [:]
    private var inspected = Set<ElementKey>()
    private var malformed = false

    init(pid: pid_t, direct: Bool) { self.pid = pid; self.direct = direct; policy = direct ? .diagnosticDirect : .respectBackoff }

    private func reference(_ element: AXUIElement) -> String {
        let key = ElementKey(element)
        if let number = references[key] { return "e\(number)" }
        let number = references.count + 1; references[key] = number
        return "e\(number)"
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        let key = ObjectIdentifier(element)
        guard configured[key] == nil else { return budget.canContinue() }
        guard budget.beginQuery() else { return false }
        // This sets this client's messaging timeout, not an app accessibility flag. It cannot interrupt a provider
        // that ignores macOS's timeout; the command's deadline is cooperative, checked again after every call.
        let error = AXUIElementSetMessagingTimeout(element, 0.05)
        configured[key] = element
        Log.line("\(reference(element)) timeoutConfiguration=\(describeError(error)) requestedMs=50")
        guard error == .success else { budget.stop(.timeoutConfiguration); return false }
        return budget.canContinue()
    }

    private func query<Value>(_ element: AXUIElement, _ name: String,
                              _ body: () -> AXQueryResult<Value>) -> AXQueryResult<Value>? {
        guard prepare(element), budget.beginQuery() else { return nil }
        let result = body()
        Log.line("\(reference(element)) \(name) \(AXDiagnosticReport.outcome(result)) hasValue=\(result.value != nil)")
        switch result.status {
        case .returned(let error):
            if error == .cannotComplete { budget.stop(.providerCannotComplete) }
            else if error == .apiDisabled { budget.stop(.accessibilityDenied) }
        case .deferred: budget.stop(.clientBackoff)
        case .batchNull: break
        case .invalidResponse: malformed = true
        default: budget.stop(.clientStopped)   // a client stop is distinct from AXHealth backoff
        }
        _ = budget.canContinue()
        return result
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AXQueryResult<CFTypeRef>? {
        query(element, name) { element.attributeResult(name, policy: policy) }
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = attribute(parent, name), let value = result.value else { return nil }
        guard let found = axElement(value) else {
            malformed = true
            Log.line("\(reference(parent)) \(name) decoded=invalidType kind=\(AXDiagnosticReport.valueKind(value))")
            return nil
        }
        Log.line("\(reference(parent)) \(name) reference=\(reference(found))")
        return found
    }

    private func text(_ element: AXUIElement, _ name: String) -> String? {
        guard let result = attribute(element, name), let value = result.value else { return nil }
        guard let text = value as? String else {
            malformed = true
            Log.line("\(reference(element)) \(name) decoded=invalidType kind=\(AXDiagnosticReport.valueKind(value))")
            return nil
        }
        return text
    }

    private func names(_ element: AXUIElement, actions: Bool) {
        let result = query(element, actions ? "actionNames" : "attributeNames") {
            actions ? element.actionNamesResult(policy: policy) : element.attributeNamesResult(policy: policy)
        }
        guard let raw = result?.value else { return }
        let sample = AXDiagnosticReport.names(in: raw)
        if sample.malformedCount > 0 { malformed = true }
        let summary = actions ? AXDiagnosticReport.actions(sample.values) : AXDiagnosticReport.attributes(sample.values)
        Log.line("\(reference(element)) \(actions ? "actions" : "attributes") returnedCount=\(sample.returnedCount) sampledNames=\(sample.examinedCount) \(summary) malformedSampleMembers=\(sample.malformedCount) oversizedSampleNames=\(sample.oversizedCount)")
    }

    private func children(_ element: AXUIElement, _ name: String = kAXChildrenAttribute,
                          index: Int = 0, limit: Int? = nil) -> [AXUIElement] {
        let countResult = query(element, "\(name).count") { element.attributeValueCountResult(name, policy: policy) }
        let count = countResult?.value
        if let count, count < 0 { malformed = true; return [] }
        if let count, count <= index {
            Log.line("\(reference(element)) \(name) reportedCount=\(count) requestedIndex=\(index) received=0")
            return []
        }
        let maximum = min(budget.maximumChildren, limit ?? budget.maximumChildren, count.map { $0 - index } ?? budget.maximumChildren)
        guard maximum > 0 else { return [] }
        let result = query(element, "\(name).prefix(index=\(index),max=\(maximum))") {
            element.attributeValuesResult(name, index: index, maxValues: maximum, policy: policy)
        }
        guard let raw = result?.value else { return [] }
        let sample = AXDiagnosticReport.elements(in: raw, maximum: maximum)
        let bounded = sample.values
        if sample.malformedCount > 0 || sample.returnedCount > maximum { malformed = true }
        budget.noteArray(total: count, received: index + bounded.count)
        Log.line("\(reference(element)) \(name) reportedCount=\(count.map(String.init) ?? "unknown") returnedCount=\(sample.returnedCount) sampledElements=\(bounded.count) malformedSampleMembers=\(sample.malformedCount) references=[\(bounded.map(reference).joined(separator: ","))]")
        return bounded
    }

    private func window() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        return element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) ?? children(app, kAXWindowsAttribute, limit: 1).first
    }

    private func admit(_ element: AXUIElement, depth: Int) -> Bool {
        guard depth <= budget.maximumDepth else { _ = budget.beginNode(depth: depth); return false }
        let key = ElementKey(element)
        if inspected.contains(key) { return budget.canContinue() }
        guard budget.beginNode(depth: depth) else { return false }
        inspected.insert(key)
        return true
    }

    /// Only the first collection found within the bounded sample. An index path is a way to reacquire a reference,
    /// never proof of item identity: App Store can reuse the same cell or move another item into the same path.
    private func collection(in window: AXUIElement) -> (AXUIElement, [Int])? {
        var queue: [(AXUIElement, [Int])] = [(window, [])]
        var next = 0
        var seen = Set<ElementKey>()
        while next < queue.count, budget.canContinue() {
            let (candidate, path) = queue[next]; next += 1
            guard seen.insert(ElementKey(candidate)).inserted, admit(candidate, depth: path.count) else { continue }
            let role = text(candidate, kAXRoleAttribute)
            Log.line("\(reference(candidate)) role=\(AXDiagnosticReport.role(role)) depth=\(path.count)")
            if role == "AXList" {
                let subrole = text(candidate, kAXSubroleAttribute)
                Log.line("\(reference(candidate)) subrole=\(AXDiagnosticReport.subrole(subrole))")
                if subrole == "AXCollectionList" { return (candidate, path) }
            }
            guard path.count < budget.maximumDepth else { _ = budget.beginNode(depth: path.count + 1); continue }
            for (index, child) in children(candidate).enumerated() { queue.append((child, path + [index])) }
        }
        return nil
    }

    @discardableResult
    private func inspect(_ target: AXUIElement, label: String, depth: Int) -> AXUIElement? {
        Log.line("sample=\(label) reference=\(reference(target))")
        names(target, actions: false); names(target, actions: true)
        let first = children(target).first
        _ = children(target, "AXVisibleChildren")
        _ = children(target, "AXChildrenInNavigationOrder")
        for name in ["AXFirstContentSibling", "AXNextContentSibling", "AXPreviousContentSibling"] { _ = element(target, name) }
        if let first, admit(first, depth: depth + 1) {
            Log.line("\(reference(first)) sampledChildRole=\(AXDiagnosticReport.role(text(first, kAXRoleAttribute)))")
        }
        return first
    }

    private func fresh(at path: [Int], from window: AXUIElement) -> AXUIElement? {
        var current = window
        for (depth, index) in path.enumerated() {
            guard admit(current, depth: depth), let child = children(current, index: index, limit: 1).first else { return nil }
            current = child
        }
        return admit(current, depth: path.count) ? current : nil
    }

    func run() {
        Log.line("healthScope=probeProcess clientPID=\(getpid()) targetPID=\(pid) policy=\(direct ? "diagnosticDirect" : "respectBackoff")")
        Log.line("limits queries=96 nodes=12 depth=4 arrayPrefix=8 overallMs=1500; local timeout requests are cooperative")
        Log.line("scope=boundedStructuralSample labels=false identifiers=false values=false; does not establish running-reader AXHealth or VoiceOver privileges")
        defer {
            Log.line("summary queries=\(budget.queries) nodesInspected=\(budget.nodes) stop=\(budget.stopped?.rawValue ?? "sampleFinished") depthClipped=\(budget.depthClipped) arraysClipped=\(budget.arraysClipped) malformed=\(malformed) providerTreeComplete=false")
        }
        guard let retainedWindow = window() else { Log.line("window=notAcquired; no empty-tree conclusion"); return }
        let selected = collection(in: retainedWindow)
        let retained = selected?.0 ?? retainedWindow
        let path = selected?.1 ?? []
        Log.line("selection=\(selected == nil ? "windowFallback" : "firstCollectionInSample") pathDepth=\(path.count); unvisited collections may exist")
        let retainedChild = inspect(retained, label: "initial", depth: path.count)
        guard budget.canContinue() else { return }
        // One bounded gap allows references to age without driving the UI. No observer, repeated polling or
        // navigation is started, and both samples spend the same allowance.
        Thread.sleep(forTimeInterval: 0.25)
        guard budget.canContinue(), NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.AppStore" else {
            Log.line("resample=notAcquired; deadline or target process changed"); return
        }
        _ = inspect(retained, label: "retained", depth: path.count)
        guard let freshWindow = window(), let freshTarget = fresh(at: path, from: freshWindow) else {
            Log.line("freshReference=notAcquired; no stale-handle conclusion"); return
        }
        Log.line("comparison windowSameReference=\(CFEqual(retainedWindow, freshWindow)) targetSameReference=\(CFEqual(retained, freshTarget)); equality does not establish stable item identity")
        let freshChild = inspect(freshTarget, label: "fresh", depth: path.count)
        if let retainedChild, let freshChild { Log.line("comparison firstChildSameReference=\(CFEqual(retainedChild, freshChild))") }
    }
}
