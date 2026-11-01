// SPDX-License-Identifier: GPL-3.0-or-later
// Issue 212, 1 Nov 2026: compare character formatting with native menu state after a shortcut.
// Read-only diagnostics: character attributes are NOT proof of pending insertion formatting.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

func runFormatStateGate(_ args: [String]) {
    let bundles: Set<String> = ["com.ulyssesapp.mac", "com.apple.TextEdit"]
    guard args.count == 2, args[0] == "--bundle", bundles.contains(args[1]) else {
        Log.line("format-state requires --bundle com.ulyssesapp.mac or com.apple.TextEdit; rejected arguments are not logged")
        return
    }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
        Log.line("target=notRunning; nothing was opened or activated"); return
    }
    Log.line("targetBundle=\(args[1]) targetIsFrontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier) accessibilityTrusted=\(AXIsProcessTrusted())")
    Log.line("readOnly=true textLogged=false menuActions=false characterAttributesAreInsertionState=false")
    FormatStateSample(pid: app.processIdentifier).run()
}

private final class FormatStateSample {
    private let application: AXUIElement
    private var budget = CapabilitiesBudget(profile: .extended)
    // Retain each configured reference: messaging timeouts apply to object identity, not CFEqual identity.
    private var configured: [ObjectIdentifier: AXUIElement] = [:]
    private var seen = Set<ElementKey>()
    private var malformed = false
    private var toolbarNodes = 0, toolbarMatches = 0, menuNodes = 0
    private var toolbarClipped = false
    private static let rootLabels = ["Markup", "Format", "Edit", "File"]
    private static let containers: Set<String> = ["Font", "Style", "Styles", "Text", "Markup", "Format", "Convert Markup"]
    private static let itemLabels: Set<String> = ["Bold", "Italic", "Italics", "Strong", "Emphasis", "Strong Emphasis", "Underline", "New Sheet", "New", "New Document", "Make Rich Text", "Make Plain Text", "Markdown XL", "Markdown", "Minimark", "Textil'd", "Textil’d"]

    init(pid: pid_t) { application = AXUIElementCreateApplication(pid) }

    private func query<Value>(_ element: AXUIElement, _ tag: String, _ body: () -> AXQueryResult<Value>) -> AXQueryResult<Value>? {
        let identity = ObjectIdentifier(element)
        if configured[identity] == nil {
            guard budget.beginQuery() else { return nil }
            let error = AXUIElementSetMessagingTimeout(element, 0.05)
            guard error == .success else {
                Log.line("timeoutConfiguration=\(describeError(error))"); budget.stop(.timeoutConfiguration); return nil
            }
            configured[identity] = element
        }
        guard budget.beginQuery() else { return nil }
        let result = body()
        Log.line("query=\(tag) \(AXDiagnosticReport.outcome(result)) hasValue=\(result.value != nil)")
        switch result.status {
        case .returned(let error):
            if error == .apiDisabled { budget.stop(.accessibilityDenied) }
            else if error == .cannotComplete { budget.stop(.providerCannotComplete) }
            else if error == .invalidUIElement { budget.stop(.clientStopped) }
        case .deferred: budget.stop(.clientBackoff)
        case .batchNull: break
        case .invalidResponse: malformed = true; budget.stop(.clientStopped)
        default: budget.stop(.clientStopped)
        }
        _ = budget.canContinue()
        return result
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        query(element, name) { element.attributeResult(name) }?.value
    }
    private func string(_ raw: CFTypeRef?) -> String? {
        guard let raw, CFGetTypeID(raw) == CFStringGetTypeID(), CFStringGetLength((raw as! CFString)) <= 128 else { return nil }
        return raw as? String
    }
    private func number(_ raw: CFTypeRef?) -> NSNumber? {
        guard let raw, CFGetTypeID(raw) == CFNumberGetTypeID() || CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
        return raw as? NSNumber
    }
    private func scalar(_ raw: CFTypeRef?) -> String {
        guard let raw else { return "absent" }
        guard let value = number(raw), value.doubleValue.isFinite else { return "otherType" }
        return value.stringValue
    }
    private func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let count = query(element, "AXChildren.count", { element.attributeValueCountResult(kAXChildrenAttribute) })?.value, count >= 0 else { return [] }
        var values: [AXUIElement] = []
        // Menu children need more than the common eight-item prefix. Four bounded pages still share
        // the same 512-query/64-node/two-second budget; no unbounded array materialization is used.
        for start in stride(from: 0, to: min(count, 32), by: 8) {
            guard let raw = query(element, "AXChildren.prefix", { element.attributeValuesResult(kAXChildrenAttribute, index: start, maxValues: min(8, count - start)) })?.value else { break }
            let sample = AXDiagnosticReport.elements(in: raw, maximum: 8)
            if sample.malformedCount > 0 || sample.returnedCount > 8 { malformed = true }
            values.append(contentsOf: sample.values)
        }
        budget.noteArray(total: count, received: values.count)
        return values
    }
    private func sampleCharacter(_ focus: AXUIElement, offset: Int, label: String) {
        guard let result = query(focus, "AXAttributedStringForRange.\(label)", {
            focus.parameterizedResult(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(offset, 1))
        }), let raw = result.value else { return }
        guard CFGetTypeID(raw) == CFAttributedStringGetTypeID(), CFAttributedStringGetLength((raw as! CFAttributedString)) == 1 else {
            malformed = true; Log.line("character=\(label) malformedAttributedString=true"); return
        }
        let attributed = raw as! CFAttributedString
        func value(_ name: String) -> CFTypeRef? { CFAttributedStringGetAttribute(attributed, 0, name as CFString, nil) }
        var fontName: String?, fontSize: CFTypeRef?
        if let rawFont = value("AXFont"), CFGetTypeID(rawFont) == CFDictionaryGetTypeID(), CFDictionaryGetCount((rawFont as! CFDictionary)) <= 16,
           let font = rawFont as? [String: Any] {
            fontName = string(font["AXFontName"] as CFTypeRef?)?.lowercased()
            fontSize = font["AXFontSize"] as CFTypeRef?
        }
        // Only known fields and font-name classifications leave the process; never the character or font name.
        Log.line("character=\(label) offset=\(offset) AXFontBold=\(scalar(value("AXFontBold"))) AXFontItalic=\(scalar(value("AXFontItalic"))) AXUnderline=\(scalar(value("AXUnderline"))) AXFontSize=\(scalar(fontSize)) fontNamePresent=\(fontName != nil) fontNameContainsBold=\(fontName?.contains("bold") ?? false) fontNameContainsItalic=\(fontName?.contains("italic") ?? false) fontNameContainsOblique=\(fontName?.contains("oblique") ?? false)")
    }
    private func publicSample(_ focus: AXUIElement, count: Int) {
        // A fixed public sentinel lets the operator verify a disposable editor without logging its content.
        // Check the provider count before requesting AXValue, and check returned length before matching.
        guard count <= 64 else { Log.line("publicSample=unrecognized valueRead=false"); return }
        guard let raw = attribute(focus, kAXValueAttribute), let value = string(raw), value.utf16.count == count else {
            Log.line("publicSample=unrecognized valueRead=true"); return
        }
        let delimiters = CharacterSet(charactersIn: "*_~")
        let stripped = value.trimmingCharacters(in: delimiters)
        let markerNames: [UInt16: String] = [42: "*", 95: "_", 126: "~"]
        let markers = value.utf16.enumerated().compactMap { offset, unit in
            markerNames[unit].map { "\(offset):\($0)" }
        }
        let unmarked = value.filter { $0 != "*" && $0 != "_" && $0 != "~" }
        // Marker positions are emitted only after the entire remaining string matches the fixed sentinel.
        // UTF-16 offsets use the same coordinate system as the separately reported original AX selection.
        let markerReport = "markersUTF16=[" + markers.joined(separator: ",") + "]"
        if value.isEmpty { Log.line("publicSample=empty delimiterOnly=false") }
        else if stripped.isEmpty, count <= 8 { Log.line("publicSample=empty delimiterOnly=true") }
        else if value == "TurnOver formatting sample" { Log.line("publicSample=sample prefix=empty suffix=empty \(markerReport)") }
        else if stripped == "TurnOver formatting sample", count - stripped.utf16.count <= 8,
                let sampleRange = value.range(of: "TurnOver formatting sample") {
            let prefix = String(value[..<sampleRange.lowerBound]), suffix = String(value[sampleRange.upperBound...])
            Log.line("publicSample=markedSample prefix=\(prefix.isEmpty ? "empty" : prefix) suffix=\(suffix.isEmpty ? "empty" : suffix) \(markerReport)")
        }
        else if unmarked == "TurnOver formatting sample", markers.count <= 12 {
            Log.line("publicSample=internalMarkedSample \(markerReport)")
        }
        else { Log.line("publicSample=unrecognized valueRead=true") }
    }
    private func sampleFocus() {
        guard let raw = attribute(application, kAXFocusedUIElementAttribute), let focus = axElement(raw) else { Log.line("focus=unavailable"); return }
        let role = string(attribute(focus, kAXRoleAttribute))
        let subrole = string(attribute(focus, kAXSubroleAttribute))
        Log.line("focusedRole=\(AXDiagnosticReport.role(role)) focusedSubrole=\(AXDiagnosticReport.subrole(subrole))")
        guard ["AXTextArea", "AXTextField"].contains(role ?? ""), subrole != "AXSecureTextField" else { Log.line("textSample=notEligible"); return }
        guard let count = number(attribute(focus, kAXNumberOfCharactersAttribute))?.intValue,
              count >= 0, count <= 1_000_000_000 else { Log.line("textSample=countUnavailable"); return }
        publicSample(focus, count: count)
        guard let range = cfRange(attribute(focus, kAXSelectedTextRangeAttribute)),
              range.location >= 0, range.location <= count, range.length >= 0, range.length <= count - range.location else {
            Log.line("textSample=rangeOrCountUnavailable"); return
        }
        Log.line("characterCount=\(count) selectedRange=\(range.location)+\(range.length) collapsed=\(range.length == 0)")
        if range.location < count { sampleCharacter(focus, offset: range.location, label: "atSelection") }
        else { Log.line("character=atSelection notRead=endOfText") }
        if range.location > 0 { sampleCharacter(focus, offset: range.location - 1, label: "beforeSelection") }
        else { Log.line("character=beforeSelection notRead=startOfText") }
    }
    private func mark(_ raw: CFTypeRef?) -> String {
        guard let raw else { return "absent" }
        guard let value = string(raw) else { return "otherTypeOrOversized" }
        if value.isEmpty { return "emptyString" }
        let marks: [String: String] = ["✓": "U+2713", "✔": "U+2714", "•": "U+2022", "-": "U+002D", "–": "U+2013", "*": "U+002A"]
        return marks[value] ?? "otherString"
    }
    private func menuItem(_ item: AXUIElement, label: String, path: String) {
        let enabled = scalar(attribute(item, kAXEnabledAttribute))
        let cmd = string(attribute(item, "AXMenuItemCmdChar"))?.lowercased()
        let safeCmd = ["b", "i", "u", "n", "t"].contains(cmd ?? "") ? cmd! : (cmd == "" ? "empty" : "otherOrAbsent")
        let modifiers = scalar(attribute(item, "AXMenuItemCmdModifiers"))
        let markResult = query(item, "AXMenuItemMarkChar") { item.attributeResult("AXMenuItemMarkChar") }
        Log.line("menuPath=\(path)/\(label) enabled=\(enabled) shortcutChar=\(safeCmd) shortcutModifiers=\(modifiers) markStatus=\(markResult?.status.description ?? "notAdmitted") markValue=\(mark(markResult?.value))")
    }
    private func beginMenuNode(depth: Int) -> Bool {
        // Focus/toolbars and menus share the fixed query/time budget. The native Edit menu lies
        // beyond the original 64-node sample; allow at most 128 nodes across both namespaces.
        guard budget.canContinue() else { return false }
        guard depth <= budget.maximumDepth else { budget.stop(.clientStopped); return false }
        guard budget.nodes + menuNodes < 128 else { budget.stop(.nodeLimit); return false }
        menuNodes += 1
        return true
    }
    private func walkMenu(_ element: AXUIElement, depth: Int, path: String) {
        guard beginMenuNode(depth: depth), seen.insert(ElementKey(element)).inserted else { return }
        let role = string(attribute(element, kAXRoleAttribute))
        if role == "AXMenu" {
            for child in children(element) { walkMenu(child, depth: depth + 1, path: path) }
        } else if role == "AXMenuItem" {
            guard let label = string(attribute(element, kAXTitleAttribute)) else { return }
            if Self.itemLabels.contains(label) { menuItem(element, label: label, path: path) }
            if Self.containers.contains(label) {
                for child in children(element) { walkMenu(child, depth: depth + 1, path: path + "/" + label) }
            }
        }
    }
    private func walkToolbar(_ element: AXUIElement, depth: Int) {
        guard toolbarNodes < 32, depth <= 4 else { toolbarClipped = true; return }
        guard budget.beginNode(depth: depth), seen.insert(ElementKey(element)).inserted else { return }
        toolbarNodes += 1
        let role = string(attribute(element, kAXRoleAttribute))
        if role == "AXToolbar" || role == "AXGroup" {
            for child in children(element) { walkToolbar(child, depth: depth + 1) }
            return
        }
        let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton"]
        guard controlRoles.contains(role ?? "") else { return }
        let labels: Set<String> = ["Strong", "Emphasis", "Bold", "Italic", "Italics"]
        var matchedLabel: String?
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let value = string(attribute(element, name)), labels.contains(value) { matchedLabel = value; break }
        }
        guard let label = matchedLabel else { return }
        toolbarMatches += 1
        let enabled = query(element, "AXEnabled") { element.attributeResult(kAXEnabledAttribute) }
        let value = query(element, "AXValue") { element.attributeResult(kAXValueAttribute) }
        let selected = query(element, "AXSelected") { element.attributeResult(kAXSelectedAttribute) }
        Log.line("toolbarControl=\(label) role=\(role!) enabledStatus=\(enabled?.status.description ?? "notAdmitted") enabled=\(scalar(enabled?.value)) valueStatus=\(value?.status.description ?? "notAdmitted") numericValue=\(scalar(value?.value)) selectedStatus=\(selected?.status.description ?? "notAdmitted") selected=\(scalar(selected?.value))")
    }
    private func sampleToolbars() {
        guard let raw = attribute(application, kAXFocusedWindowAttribute), let window = axElement(raw) else {
            Log.line("toolbarSample=focusedWindowUnavailable"); return
        }
        var toolbars = 0
        // Ulysses' retained native fixture has AXToolbar directly below AXWindow. Inspect that narrow
        // relationship only; never recurse into its sheet list, split groups, document or text areas.
        for child in children(window) {
            guard budget.beginNode(depth: 0) else { break }
            if string(attribute(child, kAXRoleAttribute)) == "AXToolbar" {
                toolbars += 1; walkToolbar(child, depth: 1)
            }
        }
        Log.line("toolbarSample=directWindowToolbars found=\(toolbars) nodes=\(toolbarNodes) matchingControls=\(toolbarMatches) localClipped=\(toolbarClipped)")
    }
    private func sampleMenus() {
        guard let raw = attribute(application, kAXMenuBarAttribute), let bar = axElement(raw) else { Log.line("menus=unavailable"); return }
        var roots: [String: AXUIElement] = [:]
        for item in children(bar) {
            guard beginMenuNode(depth: 0) else { break }
            guard let label = string(attribute(item, kAXTitleAttribute)), Self.rootLabels.contains(label) else { continue }
            roots[label] = item
        }
        for label in Self.rootLabels {
            guard let item = roots[label] else { continue }
            for child in children(item) { walkMenu(child, depth: 1, path: label) }
        }
    }
    func run() {
        sampleFocus()
        sampleToolbars()
        sampleMenus()
        Log.line("summary queries=\(budget.queries) nodes=\(budget.nodes + menuNodes) menuNodes=\(menuNodes) stop=\(budget.stopped?.rawValue ?? "none") arraysClipped=\(budget.arraysClipped) depthClipped=\(budget.depthClipped) malformed=\(malformed) menuStateFreshness=unverified")
    }
}
