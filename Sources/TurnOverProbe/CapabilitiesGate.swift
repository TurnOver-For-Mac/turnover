// SPDX-License-Identifier: GPL-3.0-or-later
// A small, metadata-only comparison of public AX capabilities. It never reads document strings or acts on UI.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runCapabilitiesGate(_ args: [String]) {
    guard args.count == 2, args[0] == "--bundle", args[1].utf8.count <= 128,
          args[1].contains("."), args[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
        Log.line("capabilities requires --bundle followed by one running application's bundle identifier; rejected arguments are not logged")
        return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
        Log.line("target=notRunning; nothing was opened or activated"); return
    }
    let bundle = app.bundleURL.flatMap { Bundle(url: $0) }
    func version(_ key: String) -> String {
        guard let value = bundle?.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [43, 45, 46, 95].contains($0) }) else { return "unavailable" }
        return value
    }
    Log.line("targetBundle=\(args[1]) version=\(version("CFBundleShortVersionString")) build=\(version("CFBundleVersion")) targetIsFrontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier)")
    Log.line("probeAccessibilityTrusted=\(AXIsProcessTrusted()) permissionPromptRequested=false VoiceOverProcessPresent=\(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty) readerActive=unobserved muteLease=unobserved")
    AXCapabilitiesSample(pid: app.processIdentifier).run()
}

private final class AXCapabilitiesSample {
    private let pid: pid_t
    private var budget = AXProbeBudget(maximumQueries: 128, maximumNodes: 16, maximumDepth: 6,
                                       maximumChildren: 8, durationNanoseconds: 2_000_000_000)
    // Messaging timeouts belong to the exact object, not to every CFEqual reference. Retaining the configured
    // object prevents address reuse during this one synchronous sample; no application flag is changed.
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var seen = Set<ElementKey>(), details = Set<ElementKey>()
    private var malformed = false, unvisited = 0, skipped = 0
    private var localStop: String?
    private let started = DispatchTime.now().uptimeNanoseconds, initialAXMilliseconds = AXStats.ms
    private static let leaves: Set<String> = ["AXButton", "AXTextField", "AXSearchField", "AXTextArea", "AXStaticText", "AXImage", "AXScrollBar", "AXLink"]
    private static let detailRoles: Set<String> = ["AXWebArea", "AXTextArea", "AXTable", "AXOutline", "AXList", "AXDocument"]
    private static let knownParameters: Set<String> = [
        "AXStringForRange", "AXAttributedStringForRange", "AXLineForIndex", "AXRangeForLine", "AXBoundsForRange",
        "AXTextMarkerForIndex", "AXIndexForTextMarker", "AXLineTextMarkerRangeForTextMarker", "AXStringForTextMarkerRange",
        "AXAttributedStringForTextMarkerRange", "AXUIElementsForSearchPredicate", "AXUIElementForTextMarker",
    ]
    private static let knownAttributes: Set<String> = [
        "AXChildren", "AXVisibleChildren", "AXChildrenInNavigationOrder", "AXSelectedChildren", "AXRows", "AXColumns",
        "AXNumberOfCharacters", "AXSelectedTextRange", "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXEndTextMarker",
        "AXValue", "AXEditable", "AXProtectedContent", "AXFocusedUIElement", "AXWebArea",
    ]

    init(pid: pid_t) { self.pid = pid }

    private func prepare(_ element: AXUIElement) -> Bool {
        let identity = ObjectIdentifier(element)
        if configured[identity] != nil { return budget.canContinue() }
        guard budget.beginQuery() else { return false }
        let result = AXUIElementSetMessagingTimeout(element, 0.05)
        Log.line("query=timeoutConfiguration status=returned:\(describeError(result)) requestedMs=50")
        guard result == .success else { budget.stop(.timeoutConfiguration); return false }
        configured[identity] = element
        return budget.canContinue()
    }

    private func query<Value>(_ element: AXUIElement, _ name: String, _ body: () -> AXQueryResult<Value>) -> AXQueryResult<Value>? {
        guard prepare(element), budget.beginQuery() else { return nil }
        let result = body()
        Log.line("query=\(name) \(AXDiagnosticReport.outcome(result)) hasValue=\(result.value != nil)")
        switch result.status {
        case .returned(let error):
            if error == .apiDisabled { budget.stop(.accessibilityDenied) }
            else if error == .cannotComplete { budget.stop(.providerCannotComplete) }
            else if error == .invalidUIElement { localStop = result.status.description; budget.stop(.clientStopped) }
        case .deferred: budget.stop(.clientBackoff)
        case .batchNull: break
        case .invalidResponse: malformed = true; budget.stop(.clientStopped)
        default: budget.stop(.clientStopped)
        }
        _ = budget.canContinue()
        return result
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = query(parent, name, { parent.attributeResult(name) }), let raw = result.value else { return nil }
        guard let value = axElement(raw) else { malformed = true; return nil }
        return value
    }

    private func role(_ element: AXUIElement) -> String? {
        guard let result = query(element, "AXRole", { element.attributeResult(kAXRoleAttribute) }), let raw = result.value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { malformed = true; return nil }
        let string = raw as! CFString // type checked, and capped before bridging any provider string
        guard CFStringGetLength(string) <= 128 else { malformed = true; return nil }
        return raw as? String
    }

    private func children(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        let count = query(element, "\(name).count", { element.attributeValueCountResult(name) })?.value
        if let count, count < 0 { malformed = true; return [] }
        if count == 0 { Log.line("array=\(name) reportedCount=0 received=0"); return [] }
        let maximum = min(8, count ?? 8)
        guard let result = query(element, "\(name).prefix", { element.attributeValuesResult(name, index: 0, maxValues: maximum) }), let array = result.value else { return [] }
        let sample = AXDiagnosticReport.elements(in: array, maximum: maximum)
        if sample.malformedCount > 0 || sample.returnedCount > maximum { malformed = true }
        budget.noteArray(total: count, received: sample.values.count)
        // Without a count, a full prefix may hide more children even when the API returned exactly our cap.
        if count == nil, sample.values.count == maximum { budget.noteArray(total: maximum + 1, received: maximum) }
        Log.line("array=\(name) reportedCount=\(count.map(String.init) ?? "unknown") returnedCount=\(sample.returnedCount) received=\(sample.values.count) malformedMembers=\(sample.malformedCount)")
        return sample.values
    }

    private func names(_ element: AXUIElement, kind: String) {
        let result = query(element, kind) {
            if kind == "actions" { return element.actionNamesResult() }
            if kind == "parameters" { return element.parameterizedAttributeNamesResult() }
            return element.attributeNamesResult()
        }
        guard let array = result?.value else { return }
        let sample = AXDiagnosticReport.names(in: array)
        let known = kind == "parameters" ? Self.knownParameters : Self.knownAttributes
        let summary = kind == "actions" ? AXDiagnosticReport.actions(sample.values) : "known=[\(Set(sample.values.filter { known.contains($0) }).sorted().joined(separator: ","))]"
        malformed = malformed || sample.malformedCount > 0
        Log.line("names=\(kind) returnedCount=\(sample.returnedCount) examinedCount=\(sample.examinedCount) \(summary) malformedMembers=\(sample.malformedCount) oversizedNames=\(sample.oversizedCount) clipped=\(sample.returnedCount > sample.examinedCount)")
    }

    private func inspect(_ target: AXUIElement, kind: String) {
        guard details.insert(ElementKey(target)).inserted else { return }
        Log.line("capabilitySample=\(kind)")
        names(target, kind: "attributes"); names(target, kind: "parameters"); names(target, kind: "actions")
        let names = [kAXNumberOfCharactersAttribute, kAXSelectedTextRangeAttribute, "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXEndTextMarker"]
        var batch: AXAttributeBatchResult?
        _ = query(target, "textMetadata") { let result = target.attributesResult(names); batch = result; return result.query }
        if let batch {
            for name in names {
                guard let result = batch.attributes[name] else { malformed = true; continue }
                Log.line("textMetadata=\(name) status=\(result.status.description) kind=\(AXDiagnosticReport.valueKind(result.value))")
                if result.error == .apiDisabled { budget.stop(.accessibilityDenied) }
                else if result.error == .cannotComplete { budget.stop(.providerCannotComplete) }
                else if result.error == .invalidUIElement || result.status == .invalidResponse { localStop = result.status.description; budget.stop(.clientStopped) }
            }
            if !batch.isAligned { malformed = true }
        }
        _ = children(target, "AXVisibleChildren")
        _ = children(target, "AXChildrenInNavigationOrder")
    }

    func run() {
        Log.line("method=boundedPublicAXCapabilities healthScope=probeProcess policy=respectBackoff")
        Log.line("bounds queriesAndTimeoutSetups=128 nodes=16 childrenPerRead=8 depth=6 cooperativeDeadlineMs=2000 timeoutPerExactReferenceMs=50")
        Log.line("labels=false identifiers=false textValues=false customActionStrings=false actionsAttempted=0 activationAttempted=false flagsWritten=0 fullControlValidated=false")
        Log.line("nameEnumeration=oneNonpaginatedProviderCallWithBoundedClientDecoding; caller must impose an external process deadline")
        defer {
            Log.line("summary queries=\(budget.queries) nodes=\(budget.nodes) capabilitySamples=\(details.count) stop=\(localStop ?? budget.stopped?.rawValue ?? "sampleFinished") depthClipped=\(budget.depthClipped) arraysClipped=\(budget.arraysClipped) skippedBranches=\(skipped) unvisitedBranches=\(unvisited) malformed=\(malformed) providerTreeComplete=false")
            Log.line("AXQueryTimeMs=\(String(format: "%.2f", AXStats.ms - initialAXMilliseconds)) wallMs=\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000); advertised capabilities and sampled reads do not prove action success or complete document support")
        }
        let app = AXUIElementCreateApplication(pid)
        if let focus = element(app, kAXFocusedUIElementAttribute), budget.beginNode(depth: 0) {
            seen.insert(ElementKey(focus))
            let rawRole = role(focus)
            Log.line("sample=focus role=\(AXDiagnosticReport.role(rawRole)) isWebArea=\(rawRole == "AXWebArea")")
            inspect(focus, kind: "focus")
        }
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            Log.line("window=notAcquired; no empty-provider conclusion"); return
        }
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while budget.canContinue(), let (target, depth) = stack.popLast() {
            guard seen.insert(ElementKey(target)).inserted else { continue }
            guard budget.beginNode(depth: depth) else { unvisited += 1; continue }
            let rawRole = role(target)
            Log.line("sample=window node=\(budget.nodes) depth=\(depth) role=\(AXDiagnosticReport.role(rawRole)) isWebArea=\(rawRole == "AXWebArea")")
            if details.count < 4, let rawRole, Self.detailRoles.contains(rawRole) { inspect(target, kind: rawRole == "AXWebArea" ? "webArea" : "content") }
            guard let rawRole, !Self.leaves.contains(rawRole) else { skipped += 1; continue }
            guard depth < budget.maximumDepth else { _ = budget.beginNode(depth: depth + 1); unvisited += 1; continue }
            let found = children(target, kAXChildrenAttribute)
            stack.append(contentsOf: found.reversed().map { ($0, depth + 1) })
        }
        unvisited += stack.count
    }
}
