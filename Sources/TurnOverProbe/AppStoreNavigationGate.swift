// SPDX-License-Identifier: GPL-3.0-or-later
// A read-only preview of the production public-navigation child selection. It does not exercise actions.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runAppStoreNavigationGate(_ args: [String]) {
    guard args.allSatisfy({ $0 == "--public-labels" }) else {
        Log.line("appstore-navigation accepts only optional --public-labels; no target or content arguments")
        return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.AppStore").first else {
        Log.line("App Store is not running; nothing was opened or activated"); return
    }
    let preview = AppStoreNavigationPreview(pid: app.processIdentifier, publicLabels: args.contains("--public-labels"))
    preview.run()
}

private final class AppStoreNavigationPreview {
    private struct NodeInfo { let role: String; let identifier: String?; let collection: Bool }
    private let pid: pid_t, publicLabels: Bool
    private let reader = AXNavigationChildren(limits: .init(durationNanoseconds: 2_000_000_000, queries: 128,
                                                           nodes: 64, children: 64, depth: 8))
    private let started = DispatchTime.now().uptimeNanoseconds, startAXMilliseconds = AXStats.ms
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var nodes: [ElementKey: NodeInfo] = [:]
    private var localStop: String?, skippedBranches = 0, unvisitedBranches = 0
    private var roles: [String: Int] = [:], readableCandidates = 0, publicTiles = 0
    private var labels: [(Int, String)] = []
    private static let knownRoles: Set<String> = ["AXWindow", "AXSplitGroup", "AXGroup", "AXScrollArea", "AXList", "AXOutline",
        "AXButton", "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXScrollBar", "AXLink", "AXHeading", "AXRow"]
    private static let terminals: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXScrollBar", "AXOutline"]

    init(pid: pid_t, publicLabels: Bool) { self.pid = pid; self.publicLabels = publicLabels }
    private var current: Bool { localStop == nil && reader.check() }
    private func safeRole(_ role: String) -> String { Self.knownRoles.contains(role) ? role : "other" }

    private func query<Value>(_ name: String, _ body: () -> AXQueryResult<Value>) -> AXQueryResult<Value>? {
        guard current else { return nil }
        let result = reader.query(body)
        if let result {
            Log.line("query=\(name) status=\(result.status.description) attempted=\(result.wasAttempted) elapsedMs=\(String(format: "%.2f", Double(result.elapsedNanoseconds) / 1e6))")
            switch result.status {
            case .returned(let error):
                if ![AXError.success, .noValue, .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented].contains(error) {
                    localStop = result.status.description
                }
            case .deferred, .invalidResponse: localStop = result.status.description
            case .batchNull: break
            default: localStop = "clientStopped:\(result.status.description)"
            }
        }
        return result
    }

    private func prepare(_ element: AXUIElement) -> Bool {
        let identity = ObjectIdentifier(element)
        if configured[identity] != nil { return current }
        let result = query("clientTimeout") {
            let before = DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementSetMessagingTimeout(element, 0.05)
            return AXQueryResult(value: error == .success, status: .returned(error),
                                 elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - before, wasAttempted: true)
        }
        // Timeout configuration is per exact object, not CFEqual identity. Retain it through the sample so its
        // address cannot be reused for an unconfigured object. No provider accessibility flag is changed.
        configured[identity] = element
        guard result?.value == true else { if localStop == nil { localStop = "timeoutConfiguration" }; return false }
        return current
    }

    private func shortString(_ result: AXQueryResult<CFTypeRef>?, limit: Int = 128) -> String? {
        guard let result, let raw = result.value else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        let string = raw as! CFString   // type checked; length is bounded before bridging provider text
        guard CFStringGetLength(string) <= limit else { return nil }
        return raw as? String
    }

    private func info(_ element: AXUIElement) -> NodeInfo? {
        let key = ElementKey(element)
        if let known = nodes[key] { return known }
        guard nodes.count < 64 else { localStop = "nodeLimit"; return nil }
        guard prepare(element) else { return nil }
        var batch: AXAttributeBatchResult?
        _ = query("structure") {
            let result = element.attributesResult([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute])
            batch = result; return result.query
        }
        guard current, let batch, let role = shortString(batch.attributes[kAXRoleAttribute]) else {
            if current { localStop = "roleUnavailable" }; return nil
        }
        let metadata = NodeInfo(role: role, identifier: shortString(batch.attributes[kAXIdentifierAttribute]),
                                collection: role == "AXList" && shortString(batch.attributes[kAXSubroleAttribute]) == "AXCollectionList")
        nodes[key] = metadata
        return metadata
    }

    private func children(_ element: AXUIElement, phase: String) -> [AXUIElement] {
        guard prepare(element) else { return [] }
        let navigation = reader.navigationReadCount, ordinary = reader.ordinaryReadCount
        let children = reader.children(of: element)
        let selected = reader.navigationReadCount > navigation ? "navigation" : (reader.ordinaryReadCount > ordinary ? "ordinaryFallback" : "none")
        for evidence in [reader.lastNavigationRead, reader.lastOrdinaryRead].compactMap({ $0 }) {
            Log.line("phase=\(phase) representation=\(evidence.attribute) countStatus=\(evidence.countStatus.description) valueStatus=\(evidence.valueStatus?.description ?? "notRequested") method=\(evidence.method.rawValue) reportedCount=\(evidence.rawCount.map(String.init) ?? "unknown")")
        }
        Log.line("phase=\(phase) chosenSource=\(selected) children=\(children.count)")
        return children
    }

    private func window() -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard prepare(app) else { return nil }
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let result = query(name, { app.attributeResult(name) }), let element = axElement(result.value) { return element }
        }
        return nil
    }

    private func collection(in window: AXUIElement) -> (element: AXUIElement, path: [Int])? {
        var stack: [(AXUIElement, [Int])] = [(window, [])], seen = Set<ElementKey>()
        while current, let (element, path) = stack.popLast() {
            guard seen.insert(ElementKey(element)).inserted else { continue }
            guard let metadata = info(element) else { break }
            if metadata.collection { unvisitedBranches += stack.count; return (element, path) }
            guard !Self.terminals.contains(metadata.role), path.count < 8 else { skippedBranches += 1; continue }
            let found = children(element, phase: "discovery")
            stack.append(contentsOf: found.enumerated().reversed().map { ($0.element, path + [$0.offset]) })
        }
        unvisitedBranches += stack.count
        return nil
    }

    private func publicTile(_ identifier: String?) -> Bool { identifier?.hasPrefix("AppStore.shelfItem.") == true }
    private func name(_ element: AXUIElement, metadata: NodeInfo, number: Int, allowLabel: Bool) {
        let candidate = publicTile(metadata.identifier) || ["AXButton", "AXStaticText", "AXLink", "AXHeading"].contains(metadata.role)
        guard candidate, prepare(element) else { return }
        var batch: AXAttributeBatchResult?
        _ = query("namePresence") {
            let result = element.attributesResult([kAXTitleAttribute, kAXDescriptionAttribute])
            batch = result; return result.query
        }
        guard current, let batch else { return }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            guard let raw = batch.attributes[attribute]?.value, CFGetTypeID(raw) == CFStringGetTypeID() else { continue }
            let string = raw as! CFString   // checked; metadata mode never bridges the label into Swift
            guard CFStringGetLength(string) > 0 else { continue }
            readableCandidates += 1
            if allowLabel, publicTile(metadata.identifier), CFStringGetLength(string) <= 160, let value = raw as? String { labels.append((number, value)) }
            return
        }
    }

    private func preview(_ target: AXUIElement, depth: Int, allowLabels: Bool) {
        var stack: [(AXUIElement, Int)] = [(target, depth)], seen = Set<ElementKey>()
        while current, let (element, depth) = stack.popLast() {
            // Public labels are buffered, with the remaining allowance reserved for fresh path validation.
            if allowLabels, reader.queryCount >= 104 { unvisitedBranches += 1; break }
            guard seen.insert(ElementKey(element)).inserted, let metadata = info(element) else { continue }
            let role = safeRole(metadata.role); roles[role, default: 0] += 1
            if publicTile(metadata.identifier) { publicTiles += 1 }
            Log.line("item=\(seen.count) depth=\(depth) role=\(role) publicTile=\(publicTile(metadata.identifier))")
            name(element, metadata: metadata, number: seen.count, allowLabel: allowLabels)
            guard !Self.terminals.contains(metadata.role), depth < 8 else { skippedBranches += 1; continue }
            stack.append(contentsOf: children(element, phase: "preview").reversed().map { ($0, depth + 1) })
        }
        unvisitedBranches += stack.count
    }

    private func validatePublicPath(_ path: [Int], original: AXUIElement) -> Bool {
        guard let root = window() else { return false }
        var element = root
        for index in path {
            let next = children(element, phase: "labelValidation")
            guard current, next.indices.contains(index) else { return false }
            element = next[index]
        }
        // Read the actual current identifier, rather than reusing discovery metadata cached for an equal object.
        guard CFEqual(element, original), prepare(element),
              let result = query("publicSurfaceValidation", { element.attributeResult(kAXIdentifierAttribute) }) else { return false }
        return shortString(result) == "AppStore.discover"
    }

    func run() {
        let enabled = NSWorkspace.shared.isVoiceOverEnabled
        let present = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
        Log.line("method=productionAXNavigationChildren healthScope=probeProcess probeAccessibilityTrusted=\(AXIsProcessTrusted())")
        Log.line("VoiceOverEnabledFlag=\(enabled) VoiceOverProcessPresent=\(present) targetIsFrontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid) readerActive=unobserved muteLease=unobserved")
        Log.line("bounds queriesAndTimeoutSetups=128 nodes=64 childrenPerRead=64 depth=8 cooperativeDeadlineMs=2000 timeoutPerExactReferenceMs=50")
        Log.line("actionsAttempted=0 activationAttempted=false fullControlValidated=false; caller must impose an external process deadline")
        defer {
            let endEnabled = NSWorkspace.shared.isVoiceOverEnabled
            let endPresent = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
            Log.line("summary queries=\(reader.queryCount) inspectedNodes=\(nodes.count) navigationSelections=\(reader.navigationReadCount) ordinaryFallbackSelections=\(reader.ordinaryReadCount) readableCandidates=\(readableCandidates) publicTiles=\(publicTiles) skippedBranches=\(skippedBranches) unvisitedBranches=\(unvisitedBranches) stop=\(localStop ?? reader.stopped.map { String(describing: $0) } ?? "sampleFinished")")
            Log.line("roles=\(roles.keys.sorted().map { "\($0):\(roles[$0]!)" }.joined(separator: ",")) AXQueryTimeMs=\(String(format: "%.2f", AXStats.ms - startAXMilliseconds)) wallMs=\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) providerTreeComplete=false")
            Log.line("VoiceOverEnabledFlagEnd=\(endEnabled) VoiceOverProcessPresentEnd=\(endPresent) readerStateChanged=\(enabled != endEnabled || present != endPresent)")
            Log.line("readableCandidates means nonempty title/description on sampled item/control roles; action success and complete content are untested")
        }
        guard let root = window(), let target = collection(in: root), let metadata = nodes[ElementKey(target.element)] else {
            Log.line("collection=notFoundWithinSample; no empty-provider conclusion"); return
        }
        let allowLabels = publicLabels && metadata.identifier == "AppStore.discover"
        Log.line("collection=found publicDiscover=\(metadata.identifier == "AppStore.discover") publicLabelsRequested=\(publicLabels)")
        preview(target.element, depth: target.path.count, allowLabels: allowLabels)
        if allowLabels, current, validatePublicPath(target.path, original: target.element) {
            for (number, label) in labels {
                if let data = try? JSONEncoder().encode(label), let escaped = String(data: data, encoding: .utf8) { Log.line("publicItem=\(number) label=\(escaped)") }
            }
            Log.line("publicLabelsEmitted=\(labels.count) surfaceRevalidated=true")
        } else if publicLabels { Log.line("publicLabelsEmitted=0 surfaceRevalidated=false; labels suppressed") }
    }
}
