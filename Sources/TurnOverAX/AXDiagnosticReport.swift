// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices

/// Diagnostics describe outcomes, never arbitrary provider strings. In particular, action names can contain
/// purchase wording or personal content, and an accessibility identifier is not necessarily public (issue 166).
public enum AXDiagnosticReport {
    public struct ArraySample<Value> {
        public let values: [Value]
        public let returnedCount: Int
        public let examinedCount: Int
        public let malformedCount: Int
        public let oversizedCount: Int
    }

    public static func names(in array: CFArray) -> ArraySample<String> {
        sample(array, maximum: 64) { value in
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return (nil, false) }
            // The type was checked before this CF cast. Test the provider string's stored UTF-16 length before
            // bridging it into Swift; a custom action name may contain arbitrarily long content.
            let string = value as! CFString
            guard CFStringGetLength(string) <= 128 else { return (nil, true) }
            return (value as? String, false)
        }
    }

    public static func elements(in array: CFArray, maximum: Int) -> ArraySample<AXUIElement> {
        sample(array, maximum: min(8, max(0, maximum))) { (axElement($0), false) }
    }

    private static func sample<Value>(_ array: CFArray, maximum: Int,
                                      decode: (AnyObject) -> (value: Value?, oversized: Bool)) -> ArraySample<Value> {
        let returned = CFArrayGetCount(array)
        let examined = min(maximum, returned)
        var values: [Value] = [], malformed = 0, oversized = 0
        withExtendedLifetime(array) {
            for index in 0..<examined {
                guard let pointer = CFArrayGetValueAtIndex(array, index) else { malformed += 1; continue }
                // AX returns an array of CF objects. Borrow one while withExtendedLifetime keeps its owner alive
                // through decoding. A Swift array cast would materialize the full payload before our prefix cap.
                let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                let decoded = decode(object)
                if decoded.oversized { oversized += 1 }
                else if let value = decoded.value { values.append(value) }
                else { malformed += 1 }
            }
        }
        return ArraySample(values: values, returnedCount: returned, examinedCount: examined,
                           malformedCount: malformed, oversizedCount: oversized)
    }

    public static func shouldStop(_ status: AXQueryStatus) -> Bool {
        switch status {
        case .returned(let error): return error == .cannotComplete
        case .deferred: return true
        case .batchNull, .invalidResponse: return false
        default: return true   // future client-stop statuses must never permit more diagnostic work
        }
    }

    public static func outcome<Value>(_ result: AXQueryResult<Value>) -> String {
        let milliseconds = Double(result.elapsedNanoseconds) / 1_000_000
        return "status=\(result.status.description) attempted=\(result.wasAttempted) elapsedMs=\(String(format: "%.2f", milliseconds))"
    }

    private static let roles: Set<String> = [
        "AXApplication", "AXWindow", "AXSheet", "AXDialog", "AXSplitGroup", "AXGroup", "AXScrollArea", "AXList",
        "AXOutline", "AXRow", "AXSectionList", "AXStaticText", "AXImage", "AXButton", "AXTextField", "AXTextArea",
        "AXSearchField", "AXToolbar", "AXLink", "AXHeading", "AXTable", "AXCell", "AXScrollBar", "AXUnknown",
    ]
    private static let subroles: Set<String> = [
        "AXCollectionList", "AXSearchField", "AXSecureTextField", "AXStandardWindow", "AXDialog", "AXSystemDialog",
    ]
    private static let standardActions: Set<String> = [
        "AXPress", "AXShowMenu", "AXScrollToVisible", "AXScrollUpByPage", "AXScrollDownByPage", "AXScrollLeftByPage",
        "AXScrollRightByPage", "AXIncrement", "AXDecrement", "AXCancel", "AXConfirm", "AXRaise", "AXPick",
    ]
    private static let relationships: Set<String> = [
        "AXRole", "AXSubrole", "AXChildren", "AXVisibleChildren", "AXChildrenInNavigationOrder", "AXParent",
        "AXFirstContentSibling", "AXLastContentSibling", "AXNextContentSibling", "AXPreviousContentSibling",
        "AXContentSiblingAbove", "AXContentSiblingBelow",
    ]

    public static func role(_ value: String?) -> String {
        guard let value else { return "absent" }
        return roles.contains(value) ? value : "other"
    }

    public static func subrole(_ value: String?) -> String {
        guard let value else { return "absent" }
        return subroles.contains(value) ? value : "other"
    }

    public static func actions(_ names: [String]) -> String {
        let standard = Set(names.filter { standardActions.contains($0) }).sorted()
        let custom = names.filter { $0.hasPrefix("Name:") }.count
        let other = names.filter { !standardActions.contains($0) && !$0.hasPrefix("Name:") }.count
        return "total=\(names.count) standard=[\(standard.joined(separator: ","))] customCount=\(custom) otherCount=\(other)"
    }

    public static func attributes(_ names: [String]) -> String {
        let known = Set(names.filter { relationships.contains($0) }).sorted()
        return "total=\(names.count) relationships=[\(known.joined(separator: ","))] otherCount=\(names.filter { !relationships.contains($0) }.count)"
    }

    public static func valueKind(_ value: CFTypeRef?) -> String {
        guard let value else { return "absent" }
        let type = CFGetTypeID(value)
        if type == AXUIElementGetTypeID() { return "element" }
        if type == CFArrayGetTypeID() { return "array" }
        if type == CFStringGetTypeID() { return "string" }
        if type == CFBooleanGetTypeID() { return "boolean" }
        if type == CFNumberGetTypeID() { return "number" }
        if type == AXValueGetTypeID() { return "axValue" }
        return "other"
    }

    public static func stringPresence(_ value: CFTypeRef?) -> String {
        guard let value else { return "absent" }
        guard let string = value as? String else { return "notString" }
        return string.isEmpty ? "empty" : "present"
    }
}
