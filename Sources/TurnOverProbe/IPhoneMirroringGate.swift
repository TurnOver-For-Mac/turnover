// SPDX-License-Identifier: GPL-3.0-or-later
// Compare public AX routes before assuming the mirrored phone has no readable content. Observed 29 Oct 2026:
// Mirroring 2.1 on macOS 27.2 exposes a focused AXUnknown outside its ordinary nine-element window tree.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runIPhoneMirroringGate(_ args: [String]) {
    guard args.isEmpty else {
        Log.line("iphone-mirroring accepts no arguments; rejected arguments are not logged")
        return
    }
    let trusted = AXIsProcessTrusted()
    Log.line("probeAccessibilityTrusted=\(trusted) permissionPromptRequested=false")
    guard trusted else { Log.line("stop=accessibilityDenied; no AX queries or permission prompts attempted"); return }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenContinuity").first else {
        Log.line("target=notRunning; nothing was opened or activated")
        return
    }
    Log.line("targetBundle=com.apple.ScreenContinuity targetIsFrontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier) VoiceOverProcessPresent=\(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty) readerActive=unobserved muteLease=unobserved")
    IPhoneMirroringSample(pid: app.processIdentifier).run()
}

private final class IPhoneMirroringSample {
    private struct Metadata { let role: String?; let subrole: String? }
    private struct Children {
        let values: [AXUIElement]
        let complete: Bool
    }
    private let pid: pid_t
    private var budget = CapabilitiesBudget(profile: .extended)
    // The timeout is per exact CF object, not CFEqual identity. Retain every configured reference through
    // this synchronous pass so address reuse cannot skip the timeout on a new provider reference.
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var admitted = Set<ElementKey>(), inspected = Set<ElementKey>(), walked = Set<ElementKey>()
    private var metadata: [ElementKey: Metadata] = [:], references: [ElementKey: Int] = [:]
    private var malformed = false, oversized = 0, unvisited = 0, hitTests = 0
    private let started = DispatchTime.now().uptimeNanoseconds
    private static let childRoutes = ["AXChildren", "AXVisibleChildren", "AXChildrenInNavigationOrder"]
    private static let knownAttributes: Set<String> = [
        "AXRole", "AXSubrole", "AXChildren", "AXVisibleChildren", "AXChildrenInNavigationOrder", "AXParent",
        "AXWindow", "AXTopLevelUIElement", "AXFocused", "AXFocusedUIElement", "AXFocusedWindow", "AXMainWindow",
        "AXPosition", "AXSize", "AXFrame", "AXEnabled", "AXNumberOfCharacters", "AXSelectedTextRange",
        "AXVisibleCharacterRange", "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXEndTextMarker",
        "AXValue", "AXEditable", "AXProtectedContent", "AXAutoInteractable", "AXEnhancedUserInterface", "AXManualAccessibility",
    ]
    private static let knownParameters: Set<String> = [
        "AXStringForRange", "AXAttributedStringForRange", "AXLineForIndex", "AXRangeForLine", "AXBoundsForRange",
        "AXTextMarkerForIndex", "AXIndexForTextMarker", "AXStringForTextMarkerRange", "AXUIElementForTextMarker",
        "AXAttributedStringForTextMarkerRange", "AXLineTextMarkerRangeForTextMarker", "AXUIElementsForSearchPredicate",
        "AXReplaceRangeWithText",
    ]

    init(pid: pid_t) { self.pid = pid }

    private func reference(_ element: AXUIElement?) -> String {
        guard let element else { return "unavailable" }
        let key = ElementKey(element)
        if let number = references[key] { return "e\(number)" }
        let number = references.count + 1
        references[key] = number
        return "e\(number)"
    }

    private func equality(_ first: AXUIElement?, _ second: AXUIElement?) -> String {
        guard let first, let second else { return "unavailable" }
        return String(CFEqual(first, second))
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

    // Known PID avoids hidden GetPid calls outside this shared query allowance. No query bypasses AXHealth.
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
        let value = raw as! CFString // checked before bounded Swift bridging
        guard CFStringGetLength(value) <= 128 else { oversized += 1; return nil }
        return raw as? String
    }

    private func info(_ element: AXUIElement) -> Metadata {
        let key = ElementKey(element)
        if let value = metadata[key] { return value }
        let value = Metadata(role: string(attribute(element, kAXRoleAttribute)),
                             subrole: string(attribute(element, kAXSubroleAttribute)))
        metadata[key] = value
        Log.line("reference=\(reference(element)) role=\(AXDiagnosticReport.role(value.role)) subrole=\(AXDiagnosticReport.subrole(value.subrole))")
        return value
    }

    private func children(_ element: AXUIElement, _ name: String) -> Children {
        let count = query(element, "\(name).count") {
            var value: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &value)
            return (value, error)
        }?.value
        if let count, count < 0 { malformed = true; return .init(values: [], complete: false) }
        if count == 0 {
            Log.line("reference=\(reference(element)) array=\(name) reportedCount=0 sampledCount=0 complete=true")
            return .init(values: [], complete: true)
        }
        let maximum = min(budget.maximumChildren, count ?? budget.maximumChildren)
        let result = query(element, "\(name).prefix") {
            var value: CFArray?
            let error = AXUIElementCopyAttributeValues(element, name as CFString, 0, maximum, &value)
            return (value, error)
        }
        guard let raw = result?.value else { return .init(values: [], complete: false) }
        guard CFGetTypeID(raw) == CFArrayGetTypeID() else { malformed = true; return .init(values: [], complete: false) }
        let sample = AXDiagnosticReport.elements(in: raw, maximum: maximum)
        malformed = malformed || sample.malformedCount > 0 || sample.returnedCount > maximum
        budget.noteArray(total: count, received: sample.values.count)
        if count == nil, sample.values.count == maximum { budget.noteArray(total: maximum + 1, received: maximum) }
        let complete = count == sample.values.count && sample.malformedCount == 0 && sample.returnedCount <= maximum
        Log.line("reference=\(reference(element)) array=\(name) reportedCount=\(count.map(String.init) ?? "unknown") sampledCount=\(sample.values.count) complete=\(complete) malformedMembers=\(sample.malformedCount)")
        return .init(values: sample.values, complete: complete)
    }

    private func names(_ element: AXUIElement, kind: String) {
        let result = query(element, kind) {
            var value: CFArray?
            let error: AXError
            if kind == "actions" { error = AXUIElementCopyActionNames(element, &value) }
            else if kind == "parameters" { error = AXUIElementCopyParameterizedAttributeNames(element, &value) }
            else { error = AXUIElementCopyAttributeNames(element, &value) }
            return (value, error)
        }
        guard let array = result?.value else { return }
        guard CFGetTypeID(array) == CFArrayGetTypeID() else { malformed = true; return }
        let sample = AXDiagnosticReport.names(in: array)
        malformed = malformed || sample.malformedCount > 0
        oversized += sample.oversizedCount
        let known = kind == "parameters" ? Self.knownParameters : Self.knownAttributes
        let summary = kind == "actions" ? AXDiagnosticReport.actions(sample.values)
            : "known=[\(Set(sample.values.filter { known.contains($0) }).sorted().joined(separator: ","))]"
        Log.line("reference=\(reference(element)) names=\(kind) returnedCount=\(sample.returnedCount) examinedCount=\(sample.examinedCount) \(summary) malformedMembers=\(sample.malformedCount) oversizedNames=\(sample.oversizedCount) clipped=\(sample.returnedCount > sample.examinedCount)")
    }

    private func settable(_ element: AXUIElement, _ name: String) {
        let result = query(element, "\(name).settable") {
            var value: DarwinBoolean = false
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &value)
            return (value.boolValue, error)
        }
        Log.line("reference=\(reference(element)) capability=\(name).settable value=\(result?.value.map(String.init) ?? "unavailable") setterAttempted=false")
    }

    private func inspect(_ element: AXUIElement, kind: String) {
        guard inspected.insert(ElementKey(element)).inserted else { return }
        Log.line("sample=\(kind) reference=\(reference(element))")
        _ = info(element)
        names(element, kind: "attributes"); names(element, kind: "parameters"); names(element, kind: "actions")
        settable(element, kAXFocusedAttribute)
        for name in ["AXNumberOfCharacters", "AXSelectedTextRange", "AXVisibleCharacterRange", "AXSelectedTextMarkerRange", "AXStartTextMarker", "AXEndTextMarker", "AXProtectedContent"] {
            let result = attribute(element, name)
            Log.line("reference=\(reference(element)) textMetadata=\(name) kind=\(AXDiagnosticReport.valueKind(result?.value)) valueLogged=false")
        }
    }

    private func focusedTextParameters(_ focus: AXUIElement) {
        // The focused remote object advertised these public parameters despite omitting character counts and
        // selections (Mirroring 2.1, macOS 27.2, 29 Oct 2026). Test a single UTF-16 unit at zero; retain no text.
        // An unsupported protection attribute is unknown, not a finding that the content is unprotected.
        let protection = attribute(focus, "AXProtectedContent")
        if let raw = protection?.value, CFGetTypeID(raw) == CFBooleanGetTypeID(),
           CFBooleanGetValue((raw as! CFBoolean)) {
            Log.line("focusedTextParameters=skippedProtectedContent textContentLogged=false")
            return
        }
        if info(focus).subrole == "AXSecureTextField" {
            Log.line("focusedTextParameters=skippedSecureTextField textContentLogged=false")
            return
        }
        Log.line("focusedTextParameters=singleUnitAtZero protectionNotConfirmed=true textContentMayBeReturned=true textContentLogged=false")
        let oneCharacter = axRangeValue(0, 1)
        for name in ["AXStringForRange", "AXAttributedStringForRange", "AXLineForIndex", "AXRangeForLine", "AXBoundsForRange"] {
            guard budget.canContinue() else { return }
            let parameter: CFTypeRef = name == "AXLineForIndex" || name == "AXRangeForLine" ? (0 as CFNumber) : oneCharacter
            let result = query(focus, "parameter.\(name)") {
                var value: CFTypeRef?
                let error = AXUIElementCopyParameterizedAttributeValue(focus, name as CFString, parameter, &value)
                return (value, error)
            }
            guard let raw = result?.value else {
                Log.line("reference=\(reference(focus)) parameterMetadata=\(name) kind=absent contentLogged=false")
                continue
            }
            var summary = "kind=\(AXDiagnosticReport.valueKind(raw))"
            if CFGetTypeID(raw) == CFStringGetTypeID() {
                summary = "kind=string length=\(CFStringGetLength((raw as! CFString)))"
            } else if CFGetTypeID(raw) == CFAttributedStringGetTypeID() {
                summary = "kind=attributedString length=\(CFAttributedStringGetLength((raw as! CFAttributedString)))"
            } else if let range = cfRange(raw) {
                let nonnegative = range.location >= 0 && range.length >= 0
                let wellFormed = nonnegative && !range.location.addingReportingOverflow(range.length).overflow
                summary = "kind=range wellFormedNonnegative=\(wellFormed)"
            } else if CFGetTypeID(raw) == CFNumberGetTypeID() {
                var number: Int64 = 0
                let decoded = CFNumberGetValue((raw as! CFNumber), .sInt64Type, &number)
                summary = "kind=number integerDecoded=\(decoded) nonnegative=\(decoded && number >= 0)"
            } else {
                var bounds = CGRect.zero
                if axValue(raw, .cgRect, &bounds) {
                    let finite = bounds.origin.x.isFinite && bounds.origin.y.isFinite && bounds.width.isFinite && bounds.height.isFinite
                    summary = "kind=rect finiteGeometry=\(finite) nonempty=\(finite && bounds.width > 0 && bounds.height > 0)"
                }
            }
            Log.line("reference=\(reference(focus)) parameterMetadata=\(name) \(summary) contentLogged=false coordinatesLogged=false")
        }
    }

    private func readFlag(_ app: AXUIElement, _ name: String) {
        let result = attribute(app, name)
        let value: String
        if let raw = result?.value, CFGetTypeID(raw) == CFBooleanGetTypeID() {
            value = String(CFBooleanGetValue((raw as! CFBoolean))) // type checked
        } else { value = result?.value == nil ? "unavailable" : "invalidType" }
        Log.line("appFlag=\(name) value=\(value) setterAttempted=false")
    }

    private func frame(_ element: AXUIElement) -> CGRect? {
        var point = CGPoint.zero, size = CGSize.zero
        let position = attribute(element, kAXPositionAttribute), dimensions = attribute(element, kAXSizeAttribute)
        guard axValue(position?.value, .cgPoint, &point), axValue(dimensions?.value, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              abs(point.x) < 1_000_000, abs(point.y) < 1_000_000, size.width < 1_000_000, size.height < 1_000_000 else {
            Log.line("reference=\(reference(element)) frame=unavailableOrInvalid coordinatesLogged=false")
            return nil
        }
        Log.line("reference=\(reference(element)) frame=finiteNonempty coordinatesLogged=false")
        return CGRect(origin: point, size: size)
    }

    private func hitTest(_ app: AXUIElement, frame: CGRect, source: String, focus: AXUIElement?, window: AXUIElement?) {
        // Fixed interior points distinguish native chrome from a remote focused object without reading pixels
        // or issuing input. Only identity comparisons and allowlisted roles enter the log, never geometry.
        for (index, fraction) in [(0.5, 0.5), (0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)].enumerated() {
            guard budget.canContinue() else { return }
            let x = Float(frame.minX + frame.width * fraction.0), y = Float(frame.minY + frame.height * fraction.1)
            let result = query(app, "hitTest.\(source).\(index)") {
                var value: AXUIElement?
                let error = AXUIElementCopyElementAtPosition(app, x, y, &value)
                return (value, error)
            }
            hitTests += result?.wasAttempted == true ? 1 : 0
            guard let hit = result?.value else { continue }
            Log.line("hitSource=\(source) pointIndex=\(index) reference=\(reference(hit)) sameAsFocus=\(equality(hit, focus)) sameAsWindow=\(equality(hit, window))")
            guard admit(hit, depth: 0) else { return }
            inspect(hit, kind: "hitTest")
        }
    }

    private func ancestry(_ focus: AXUIElement, focused: AXUIElement?, main: AXUIElement?) {
        let owner = element(focus, kAXWindowAttribute)
        let top = element(focus, kAXTopLevelUIElementAttribute)
        Log.line("focusRelationship owner=\(reference(owner)) ownerIsFocused=\(equality(owner, focused)) ownerIsMain=\(equality(owner, main)) top=\(reference(top)) topIsFocused=\(equality(top, focused)) topIsMain=\(equality(top, main))")
        var candidate = focus, seen: Set<ElementKey> = [ElementKey(focus)]
        for hop in 1...8 {
            guard let parent = element(candidate, kAXParentAttribute), admit(parent, depth: hop) else { return }
            guard seen.insert(ElementKey(parent)).inserted else { malformed = true; Log.line("focusAncestor=cycle"); return }
            let data = info(parent)
            Log.line("sample=focusAncestor hop=\(hop) reference=\(reference(parent)) isFocusedWindow=\(equality(parent, focused)) isMainWindow=\(equality(parent, main))")
            if data.role == "AXWindow" || data.role == "AXApplication" { return }
            candidate = parent
        }
        Log.line("focusAncestor=hopLimit pathComplete=false")
    }

    private func walk(_ roots: [AXUIElement]) {
        var stack = roots.reversed().map { ($0, 0) }
        while budget.canContinue(), let (target, depth) = stack.popLast() {
            guard walked.insert(ElementKey(target)).inserted else { continue }
            guard admit(target, depth: depth) else { unvisited += 1; continue }
            Log.line("sample=structure reference=\(reference(target)) depth=\(depth)")
            _ = info(target)
            var combined: [AXUIElement] = [], combinedKeys = Set<ElementKey>()
            for route in Self.childRoutes {
                let result = children(target, route)
                for child in result.values where combinedKeys.insert(ElementKey(child)).inserted { combined.append(child) }
            }
            if depth >= budget.maximumDepth {
                if !combined.isEmpty { _ = budget.beginNode(depth: depth + 1); unvisited += combined.count }
                continue
            }
            stack.append(contentsOf: combined.reversed().map { ($0, depth + 1) })
        }
        unvisited += stack.count
    }

    func run() {
        Log.line("method=boundedIPhoneMirroringPublicAX policy=respectBackoff healthScope=probeProcess")
        Log.line("bounds queriesAndTimeoutSetups=512 nodes=64 depth=12 arrayPrefix=8 focusAncestorHops=8 hitPointsPerFrame=5 cooperativeDeadlineMs=2000 timeoutPerExactReferenceMs=50")
        Log.line("labelsRead=false identifiersRead=false textContentQueries=focusOnlyRange0Plus1 textContentMayBeReturned=true textContentLogged=false imagesRead=false coordinatesLogged=false actionsAttempted=0 flagsWritten=0 focusWrites=0 activationAttempted=false")
        Log.line("nameEnumeration=oneNonpaginatedProviderCallWithBoundedClientDecoding externalProcessDeadlineRequired=true")
        defer {
            Log.line("summary queries=\(budget.queries) nodes=\(budget.nodes) structuralNodes=\(walked.count) inspectedNodes=\(inspected.count) hitTestsAttempted=\(hitTests) stop=\(budget.stopped?.rawValue ?? "sampleFinished") depthClipped=\(budget.depthClipped) arraysClipped=\(budget.arraysClipped) unvisitedBranches=\(unvisited) malformed=\(malformed) oversizedMetadata=\(oversized) wallMs=\((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000) providerTreeComplete=false")
            Log.line("interpretation=sampledRoutesOnly; empty clipped unavailable and denied routes are distinct; advertised operations do not prove readable phone content or successful control")
        }
        let app = AXUIElementCreateApplication(pid)
        readFlag(app, "AXEnhancedUserInterface"); readFlag(app, "AXManualAccessibility")
        let focused = element(app, kAXFocusedWindowAttribute)
        let main = element(app, kAXMainWindowAttribute)
        let focus = element(app, kAXFocusedUIElementAttribute)
        Log.line("windowRelationship focused=\(reference(focused)) main=\(reference(main)) same=\(equality(focused, main)) focusedElement=\(reference(focus))")
        if let focus {
            inspect(focus, kind: "actualFocus")
            focusedTextParameters(focus)
            ancestry(focus, focused: focused, main: main)
        }
        // Focus is an independent root: a remote object need not appear below the Mac window's AXChildren.
        walk([focus, focused, main].compactMap { $0 })
        if let focus, let bounds = frame(focus) { hitTest(app, frame: bounds, source: "focus", focus: focus, window: focused) }
        if let window = focused ?? main, let bounds = frame(window) { hitTest(app, frame: bounds, source: "window", focus: focus, window: window) }
    }
}
