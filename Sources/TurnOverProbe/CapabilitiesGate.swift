// SPDX-License-Identifier: GPL-3.0-or-later
// A small, metadata-only comparison of public AX capabilities. It never reads document strings or acts on UI.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runCapabilitiesGate(_ args: [String]) {
    let settingsShape = args.count == 3 && args.last == "--system-settings"
    let extended = args.count == 3 && args.last == "--extended"
    guard (args.count == 2 || settingsShape || extended), args[0] == "--bundle", args[1].utf8.count <= 128,
          !settingsShape || args[1] == "com.apple.systempreferences",
          args[1].contains("."), args[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
        Log.line("capabilities requires --bundle id with at most one of --extended or --system-settings; Settings mode requires com.apple.systempreferences; rejected arguments are not logged")
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
    let profile: CapabilitiesProfile = settingsShape ? .systemSettings : (extended ? .extended : .standard)
    AXCapabilitiesSample(pid: app.processIdentifier, profile: profile).run()
}

private final class AXCapabilitiesSample {
    private let pid: pid_t
    private let profile: CapabilitiesProfile
    private var settingsShape: Bool { profile == .systemSettings }
    private var extended: Bool { profile == .extended }
    private var shapeTags: [ElementKey: String] = [:]
    private var budget: CapabilitiesBudget
    // Messaging timeouts belong to the exact object, not to every CFEqual reference. Retaining the configured
    // object prevents address reuse during this one synchronous sample; no application flag is changed.
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var seen = Set<ElementKey>(), details = Set<ElementKey>(), completedDetails = Set<ElementKey>(), settableSamples = Set<ElementKey>()
    private var webAreas = Set<ElementKey>(), textAreas = Set<ElementKey>()
    private var malformed = false, unvisited = 0, skipped = 0, oversizedMetadata = 0
    private var localStop: String?
    private var prunedToolbars = 0, prunedRows = 0, ancestorClipped = false
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
        "AXSharedTextUIElements", "AXSharedCharacterRange", "AXVisibleCharacterRange",
    ]

    init(pid: pid_t, profile: CapabilitiesProfile) {
        self.pid = pid; self.profile = profile
        budget = CapabilitiesBudget(profile: profile)
    }

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
        record(result.status)
        _ = budget.canContinue()
        return result
    }

    private func record(_ status: AXQueryStatus) {
        switch status {
        case .returned(let error):
            if error == .apiDisabled { budget.stop(.accessibilityDenied) }
            else if error == .cannotComplete { budget.stop(.providerCannotComplete) }
            else if error == .invalidUIElement { localStop = status.description; budget.stop(.clientStopped) }
        case .deferred: budget.stop(.clientBackoff)
        case .batchNull: break
        case .invalidResponse: malformed = true; budget.stop(.clientStopped)
        default: budget.stop(.clientStopped)
        }
    }

    private func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = query(parent, name, { parent.attributeResult(name) }), let raw = result.value else { return nil }
        guard let value = axElement(raw) else { malformed = true; return nil }
        return value
    }

    private func boundedString(_ raw: CFTypeRef?) -> String? {
        guard let raw else { return nil }
        guard CFGetTypeID(raw) == CFStringGetTypeID() else { malformed = true; return nil }
        let string = raw as! CFString // type checked, and capped before bridging any provider string
        guard CFStringGetLength(string) <= 128 else { oversizedMetadata += 1; return nil }
        return raw as? String
    }

    private func noteContentRole(_ role: String?, of element: AXUIElement) -> String? {
        if role == "AXWebArea" { webAreas.insert(ElementKey(element)) }
        if role == "AXTextArea" { textAreas.insert(ElementKey(element)) }
        return role
    }

    private func role(_ element: AXUIElement) -> String? {
        guard settingsShape else {
            return noteContentRole(boundedString(query(element, "AXRole", { element.attributeResult(kAXRoleAttribute) })?.value), of: element)
        }
        shapeTags[ElementKey(element)] = nil
        var batch: AXAttributeBatchResult?
        _ = query(element, "systemSettingsShapeMetadata") {
            let result = element.attributesResult([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute])
            batch = result; return result.query
        }
        guard let batch, batch.query.status == .returned(.success) else { return nil }
        for value in batch.attributes.values { record(value.status) }
        guard batch.isAligned else { malformed = true; budget.stop(.clientStopped); return nil }
        let role = boundedString(batch.attributes[kAXRoleAttribute]?.value)
        let identifier = boundedString(batch.attributes[kAXIdentifierAttribute]?.value)
        let subrole = boundedString(batch.attributes[kAXSubroleAttribute]?.value)
        // These exact structural constants come from the public System Settings sample, 29 Oct 2026 (#177).
        // Unknown identifiers and all provider labels remain unreported; matching the string alone is insufficient.
        if role == "AXSplitGroup", identifier == "Main, SidebarNavigationSplitView" { shapeTags[ElementKey(element)] = "settingsSplit" }
        if role == "AXOutline", identifier == "com.apple.settings.sidebar.collectionView" { shapeTags[ElementKey(element)] = "settingsSidebar" }
        if role == "AXTextField", subrole == "AXSearchField" { shapeTags[ElementKey(element)] = "settingsSearch" }
        let publicGeneralIDs: Set<String> = ["com.apple.systempreferences.general.about", "com.apple.systempreferences.general.softwareUpdate",
            "com.apple.systempreferences.general.storage", "com.apple.systempreferences.general.appleCareAndWarranty"]
        if role == "AXButton", let identifier, publicGeneralIDs.contains(identifier) {
            shapeTags[ElementKey(element)] = "settingsGeneralButton"
            generalLabelMetadata(element)
            focusedSettable(element)
        }
        return noteContentRole(role, of: element)
    }

    private func generalLabelMetadata(_ element: AXUIElement) {
        let result = query(element, "knownPublicGeneralAttributedDescription") { element.attributeResult("AXAttributedDescription") }
        var kind = "absent", length: Int?
        if let value = result?.value {
            if CFGetTypeID(value) == CFAttributedStringGetTypeID() {
                // The type is checked and only the stored length is inspected. No attributed description text,
                // runs, attributes or derived Swift String can enter the metadata log.
                kind = "attributedString"; length = CFAttributedStringGetLength(value as! CFAttributedString)
            } else if CFGetTypeID(value) == CFStringGetTypeID() {
                kind = "string"; length = CFStringGetLength(value as! CFString)
            } else { kind = AXDiagnosticReport.valueKind(value) }
        }
        Log.line("knownPublicGeneralButton=true attributedDescriptionStatus=\(result?.status.description ?? "notAdmitted") kind=\(kind) length=\(length.map(String.init) ?? "unavailable") labelTextLogged=false")
    }

    private func focusedSettable(_ element: AXUIElement) {
        guard settableSamples.insert(ElementKey(element)).inserted else { return }
        let result = query(element, "AXFocused.settable") {
            var settable: DarwinBoolean = false
            let execution = AXHealth.query(pid: element.pid) {
                AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable)
            }
            return AXQueryResult(value: settable.boolValue, status: execution.status,
                                 elapsedNanoseconds: execution.elapsedNanoseconds, wasAttempted: execution.wasAttempted)
        }
        Log.line("capability=AXFocused.settable value=\(result?.value.map(String.init) ?? "unavailable"); setterNotAttempted=true")
    }

    private func children(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        let count = query(element, "\(name).count", { element.attributeValueCountResult(name) })?.value
        if let count, count < 0 { malformed = true; return [] }
        if count == 0 { Log.line("array=\(name) reportedCount=0 received=0"); return [] }
        let maximum = min(budget.maximumChildren, count ?? budget.maximumChildren)
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
        focusedSettable(target)
        names(target, kind: "attributes"); names(target, kind: "parameters"); names(target, kind: "actions")
        let names = [kAXNumberOfCharactersAttribute, kAXSelectedTextRangeAttribute, "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXEndTextMarker"]
            + (extended ? ["AXSharedCharacterRange", "AXVisibleCharacterRange"] : [])
        var batch: AXAttributeBatchResult?
        _ = query(target, "textMetadata") { let result = target.attributesResult(names); batch = result; return result.query }
        if let batch, batch.query.status == .returned(.success) {
            for name in names {
                guard let result = batch.attributes[name] else { malformed = true; continue }
                Log.line("textMetadata=\(name) status=\(result.status.description) kind=\(AXDiagnosticReport.valueKind(result.value))")
                record(result.status)
            }
            if !batch.isAligned { malformed = true }
        }
        _ = children(target, "AXVisibleChildren")
        _ = children(target, "AXChildrenInNavigationOrder")
        if budget.canContinue() { completedDetails.insert(ElementKey(target)) }
    }

    /// A focused DOM leaf may sit outside the window's first child prefix. Inspect its enclosing web area
    /// without widening any child array or touching another window. These admissions share the sample budget.
    private func focusedWebAncestor(_ focus: AXUIElement, role initialRole: String?) {
        var candidate = focus, candidateRole = initialRole
        var ancestry: Set<ElementKey> = [ElementKey(focus)]
        for hop in 0...8 {
            guard budget.canContinue() else { return }
            if candidateRole == "AXWebArea" {
                inspect(candidate, kind: "focusedAncestorWebArea")
                Log.line("focusedAncestorWebArea=found hops=\(hop)")
                return
            }
            if candidateRole == "AXWindow" || candidateRole == "AXApplication" {
                Log.line("focusedAncestorWebArea=notOnSampledAncestorPath hops=\(hop)"); return
            }
            guard hop < 8 else { ancestorClipped = true; break }
            guard let parent = element(candidate, kAXParentAttribute) else {
                Log.line("focusedAncestorWebArea=parentNotAcquired hops=\(hop)"); return
            }
            guard ancestry.insert(ElementKey(parent)).inserted else {
                malformed = true; Log.line("focusedAncestorWebArea=ancestorCycle"); return
            }
            guard budget.beginNode(depth: hop + 1) else { return }
            candidate = parent; candidateRole = role(parent)
            Log.line("sample=focusAncestor hops=\(hop + 1) role=\(AXDiagnosticReport.role(candidateRole)) isWebArea=\(candidateRole == "AXWebArea")")
        }
        Log.line("focusedAncestorWebArea=notFoundWithinEightHops ancestorPathClipped=true")
    }

    func run() {
        Log.line("method=boundedPublicAXCapabilities healthScope=probeProcess policy=respectBackoff")
        Log.line("bounds queriesAndTimeoutSetups=\(budget.maximumQueries) nodes=\(budget.maximumNodes) childrenPerRead=\(budget.maximumChildren) depth=\(budget.maximumDepth) cooperativeDeadlineMs=2000 timeoutPerExactReferenceMs=50")
        Log.line("labels=false identifierValuesLogged=false textValues=false customActionStrings=false actionsAttempted=0 activationAttempted=false flagsWritten=0 fullControlValidated=false")
        Log.line("profile=\(profile.rawValue) systemSettingsShapeMode=\(settingsShape) knownStructuralTagsOnly=true outlineAndTableRowsPruned=\(settingsShape || extended) toolbarsPruned=\(extended)")
        Log.line("focusedTargetInspectedIndependently=true focusedAncestorHopLimit=\(extended ? 8 : 0) sharedTextUIElementsArrayRead=false sharedRangeValuesLogged=false")
        Log.line("nameEnumeration=oneNonpaginatedProviderCallWithBoundedClientDecoding; caller must impose an external process deadline")
        defer {
            Log.line("summary queries=\(budget.queries) nodes=\(budget.nodes) capabilitySamples=\(details.count) completedCapabilitySamples=\(completedDetails.count) stop=\(localStop ?? budget.stopped?.rawValue ?? "sampleFinished") depthClipped=\(budget.depthClipped) arraysClipped=\(budget.arraysClipped) skippedBranches=\(skipped) unvisitedBranches=\(unvisited) malformed=\(malformed) oversizedMetadata=\(oversizedMetadata) prunedToolbars=\(prunedToolbars) prunedRowContainers=\(prunedRows) ancestorClipped=\(ancestorClipped) providerTreeComplete=false")
            Log.line("contentCoverage webAreasObserved=\(webAreas.count) webAreaCapabilitySamples=\(webAreas.intersection(completedDetails).count) textAreasObserved=\(textAreas.count) textAreaCapabilitySamples=\(textAreas.intersection(completedDetails).count); capability sample means all planned metadata reads admitted, not successful content or action support")
            Log.line("AXQueryTimeMs=\(String(format: "%.2f", AXStats.ms - initialAXMilliseconds)) wallMs=\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000); advertised capabilities and sampled reads do not prove action success or complete document support")
        }
        let app = AXUIElementCreateApplication(pid)
        if let focus = element(app, kAXFocusedUIElementAttribute), budget.beginNode(depth: 0) {
            // Focus inspection may be the window itself. It uses the detail cache, not traversal's seen set,
            // so the later bounded window walk can still discover that window's children (overnight #177).
            let rawRole = role(focus)
            Log.line("sample=focus role=\(AXDiagnosticReport.role(rawRole)) isWebArea=\(rawRole == "AXWebArea") knownStructure=\(shapeTags[ElementKey(focus)] ?? "unmatched")")
            inspect(focus, kind: "focus")
            if extended { focusedWebAncestor(focus, role: rawRole) }
        }
        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            Log.line("window=notAcquired; no empty-provider conclusion"); return
        }
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while budget.canContinue(), let (target, depth) = stack.popLast() {
            guard seen.insert(ElementKey(target)).inserted else { continue }
            guard budget.beginNode(depth: depth) else { unvisited += 1; continue }
            let rawRole = role(target)
            let tag = shapeTags[ElementKey(target)]
            Log.line("sample=window node=\(budget.nodes) depth=\(depth) role=\(AXDiagnosticReport.role(rawRole)) isWebArea=\(rawRole == "AXWebArea") knownStructure=\(tag ?? "unmatched")")
            let detailRoles: Set<String> = extended ? ["AXWebArea", "AXTextArea", "AXDocument"] : Self.detailRoles
            if details.count < (extended ? 8 : 4), tag != nil || rawRole.map({ detailRoles.contains($0) }) == true {
                inspect(target, kind: tag ?? (rawRole == "AXWebArea" ? "webArea" : "content"))
            }
            if extended, rawRole == "AXToolbar" { prunedToolbars += 1; skipped += 1; continue }
            if settingsShape || extended, rawRole == "AXOutline" || rawRole == "AXTable" {
                prunedRows += 1; skipped += 1; continue
            }
            guard let rawRole, !Self.leaves.contains(rawRole) else { skipped += 1; continue }
            guard depth < budget.maximumDepth else { _ = budget.beginNode(depth: depth + 1); unvisited += 1; continue }
            let found = children(target, kAXChildrenAttribute)
            stack.append(contentsOf: found.reversed().map { ($0, depth + 1) })
        }
        unvisited += stack.count
    }
}
