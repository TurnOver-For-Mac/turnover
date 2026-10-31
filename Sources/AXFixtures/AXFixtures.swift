// SPDX-License-Identifier: GPL-3.0-or-later
// Recorded accessibility trees (8 Oct 2026, from the team review): a window's elements and their attributes,
// saved as JSON by turnover-coretest --record, and replayed by the test runner through the AXReplayShim so
// TurnOver's views can be tested against Music, WhatsApp, Safari or Word without the applications running.
//
// A recording walks the children from a root (bounded), then records the root's ancestors up to the application
// and any other element the walked ones refer to (a title element, a window's default button) as stubs: their
// attributes, with references only to elements already recorded.
import Foundation
import ApplicationServices
import AppKit

public struct AXFixture: Codable {
    public struct Node: Codable {
        public var id: Int
        public var attrs: [String: Value]
        public var params: [String]
        public var actions: [String]
        public init(id: Int, attrs: [String: Value], params: [String] = [], actions: [String] = []) { self.id = id; self.attrs = attrs; self.params = params; self.actions = actions }
    }
    /// An attribute's value, as JSON: {"s": "text"}, {"n": 3}, {"b": true}, {"e": 12}, {"es": [1, 2]},
    /// {"ss": ["a"]}, {"pt": [x, y]}, {"sz": [w, h]}, {"rg": [location, length]}, {"rc": [x, y, w, h]}, {"u": "url"}.
    public enum Value: Codable, Equatable {
        case string(String), number(Double), bool(Bool), element(Int), elements([Int]), strings([String])
        case point(Double, Double), size(Double, Double), range(Int, Int), rect(Double, Double, Double, Double), url(String)

        enum K: String, CodingKey { case s, n, b, e, es, ss, pt, sz, rg, rc, u }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            if let v = try c.decodeIfPresent(String.self, forKey: .s) { self = .string(v) }
            else if let v = try c.decodeIfPresent(Double.self, forKey: .n) { self = .number(v) }
            else if let v = try c.decodeIfPresent(Bool.self, forKey: .b) { self = .bool(v) }
            else if let v = try c.decodeIfPresent(Int.self, forKey: .e) { self = .element(v) }
            else if let v = try c.decodeIfPresent([Int].self, forKey: .es) { self = .elements(v) }
            else if let v = try c.decodeIfPresent([String].self, forKey: .ss) { self = .strings(v) }
            else if let v = try c.decodeIfPresent([Double].self, forKey: .pt), v.count == 2 { self = .point(v[0], v[1]) }
            else if let v = try c.decodeIfPresent([Double].self, forKey: .sz), v.count == 2 { self = .size(v[0], v[1]) }
            else if let v = try c.decodeIfPresent([Int].self, forKey: .rg), v.count == 2 { self = .range(v[0], v[1]) }
            else if let v = try c.decodeIfPresent([Double].self, forKey: .rc), v.count == 4 { self = .rect(v[0], v[1], v[2], v[3]) }
            else if let v = try c.decodeIfPresent(String.self, forKey: .u) { self = .url(v) }
            else { throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "unknown value")) }
        }
        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: K.self)
            switch self {
            case .string(let v): try c.encode(v, forKey: .s)
            case .number(let v): try c.encode(v, forKey: .n)
            case .bool(let v): try c.encode(v, forKey: .b)
            case .element(let v): try c.encode(v, forKey: .e)
            case .elements(let v): try c.encode(v, forKey: .es)
            case .strings(let v): try c.encode(v, forKey: .ss)
            case .point(let x, let y): try c.encode([x, y], forKey: .pt)
            case .size(let w, let h): try c.encode([w, h], forKey: .sz)
            case .range(let l, let n): try c.encode([l, n], forKey: .rg)
            case .rect(let x, let y, let w, let h): try c.encode([x, y, w, h], forKey: .rc)
            case .url(let v): try c.encode(v, forKey: .u)
            }
        }
    }

    public var app: String
    public var bundle: String
    public var recorded: String
    public var root: Int
    /// The application element's id, when it was reached (the root's ancestors are recorded up to it).
    public var application: Int?
    /// The element the application said had the focus when recorded, if it was recorded.
    public var focus: Int?
    public var nodes: [Node]

    public init(app: String, bundle: String, recorded: String, root: Int, application: Int?, focus: Int?, nodes: [Node]) {
        self.app = app; self.bundle = bundle; self.recorded = recorded; self.root = root; self.application = application; self.focus = focus; self.nodes = nodes
    }
    public func node(_ id: Int) -> Node? { nodes.first { $0.id == id } }

    public static func load(_ url: URL) throws -> AXFixture { try JSONDecoder().decode(AXFixture.self, from: Data(contentsOf: url)) }
    public func save(to url: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url)
    }
}

// MARK: - Recording

public enum AXRecorder {
    /// An element as a dictionary key: equal when the accessibility API says so.
    struct Key: Hashable {
        let e: AXUIElement
        static func == (a: Key, b: Key) -> Bool { CFEqual(a.e, b.e) }
        func hash(into h: inout Hasher) { h.combine(CFHash(e)) }
    }

    /// Record `root` and its descendants (at most `limit` of them), the root's ancestors, and stubs for anything
    /// else they refer to.
    /// The fixture with the user's content masked, for recordings of apps that hold it (Calendar, Contacts, Mail):
    /// every word in a value, title, description, help, placeholder or label becomes letters of the same length and
    /// case ("Holidays" → "Aaaaaaaa"), digits become 0. Roles, subroles, identifiers and role descriptions are kept, so the
    /// recording still has the app's shape and the names its controls are found by.
    public static func masked(_ f: AXFixture) -> AXFixture {
        let keep: Set<String> = ["AXRole", "AXSubrole", "AXIdentifier", "AXRoleDescription", "AXDOMIdentifier", "AXDOMClassList"]
        // Digits too: phone numbers and addresses are the user's (Contacts, 10 Oct 2026).
        func mask(_ s: String) -> String { String(s.map { $0.isUppercase ? "A" : $0.isLetter ? "a" : $0.isNumber ? "0" : $0 }) }
        var out = f
        out.nodes = f.nodes.map { n in
            var n = n
            for (k, v) in n.attrs where !keep.contains(k) {
                switch v {
                case .string(let s): n.attrs[k] = .string(mask(s))
                case .strings(let a): n.attrs[k] = .strings(a.map(mask))
                case .url: n.attrs[k] = .url("file:///masked")
                default: break
                }
            }
            return n
        }
        return out
    }

    public static func record(root: AXUIElement, app: NSRunningApplication?, limit: Int = 4000) -> AXFixture {
        var ids: [Key: Int] = [:]
        var nodes: [AXFixture.Node] = []
        var order: [AXUIElement] = []
        func id(for e: AXUIElement) -> Int {
            if let i = ids[Key(e: e)] { return i }
            let i = order.count; ids[Key(e: e)] = i; order.append(e); return i
        }
        // 1. The subtree, breadth first.
        var walked = Set<Int>()
        var queue = [root]
        _ = id(for: root)
        while !queue.isEmpty, walked.count < limit {
            let e = queue.removeFirst()
            let i = id(for: e)
            guard !walked.contains(i) else { continue }
            walked.insert(i)
            for c in e.axElements(kAXChildrenAttribute) { _ = id(for: c); queue.append(c) }
        }
        // 2. The ancestors, up to the application.
        var ancestors: [AXUIElement] = []
        var p = root.axElement(kAXParentAttribute); var hops = 0
        while let x = p, hops < 30 { ancestors.append(x); _ = id(for: x); p = x.axElement(kAXParentAttribute); hops += 1 }
        let recordedFully = walked.union(ancestors.map { id(for: $0) })
        // 3. Attributes for everything known so far; references to unknown elements become stubs (one level).
        var stubs: [AXUIElement] = []
        func convert(_ v: CFTypeRef, allowNew: Bool) -> AXFixture.Value? {
            let t = CFGetTypeID(v)
            if t == CFStringGetTypeID() { return .string(v as! String) }
            if t == CFAttributedStringGetTypeID() { return .string((v as! NSAttributedString).string) }
            if t == CFBooleanGetTypeID() { return .bool(CFBooleanGetValue((v as! CFBoolean))) }
            if t == CFNumberGetTypeID() { return .number((v as! NSNumber).doubleValue) }
            if t == CFURLGetTypeID() { return .url((v as! URL).absoluteString) }
            if t == AXUIElementGetTypeID() {
                let e = v as! AXUIElement
                if ids[Key(e: e)] == nil { guard allowNew else { return nil }; stubs.append(e) }
                return .element(id(for: e))
            }
            if t == AXValueGetTypeID() {
                let a = v as! AXValue
                switch AXValueGetType(a) {
                case .cgPoint: var pt = CGPoint(); AXValueGetValue(a, .cgPoint, &pt); return .point(pt.x, pt.y)
                case .cgSize: var sz = CGSize(); AXValueGetValue(a, .cgSize, &sz); return .size(sz.width, sz.height)
                case .cfRange: var r = CFRange(); AXValueGetValue(a, .cfRange, &r); return .range(r.location, r.length)
                case .cgRect: var r = CGRect(); AXValueGetValue(a, .cgRect, &r); return .rect(r.origin.x, r.origin.y, r.width, r.height)
                default: return nil
                }
            }
            if t == CFArrayGetTypeID() {
                let arr = v as! [AnyObject]
                if arr.isEmpty { return .elements([]) }
                if arr.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) {
                    var out: [Int] = []
                    for x in arr { let e = x as! AXUIElement; if ids[Key(e: e)] == nil { guard allowNew else { continue }; stubs.append(e) }; out.append(id(for: e)) }
                    return .elements(out)
                }
                if arr.allSatisfy({ $0 is String }) { return .strings(arr as! [String]) }
                return nil
            }
            return nil
        }
        func attributes(of e: AXUIElement, allowNew: Bool) -> AXFixture.Node {
            var attrs: [String: AXFixture.Value] = [:]
            var names: CFArray?
            AXUIElementCopyAttributeNames(e, &names)
            for n in (names as? [String]) ?? [] {
                // Children are the walk's business; an element's own children list is kept to what was walked.
                var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success, let v else { continue }
                if let c = convert(v, allowNew: allowNew && n != kAXChildrenAttribute) { attrs[n] = c }
            }
            var pnames: CFArray?; AXUIElementCopyParameterizedAttributeNames(e, &pnames)
            var anames: CFArray?; AXUIElementCopyActionNames(e, &anames)
            return AXFixture.Node(id: id(for: e), attrs: attrs, params: (pnames as? [String]) ?? [], actions: (anames as? [String]) ?? [])
        }
        var done = Set<Int>()
        for i in 0..<order.count where recordedFully.contains(i) {
            nodes.append(attributes(of: order[i], allowNew: true)); done.insert(i)
        }
        // Stubs: attributes only, references only to what is known.
        var si = 0
        while si < stubs.count {
            let e = stubs[si]; si += 1
            let i = id(for: e)
            guard !done.contains(i) else { continue }
            done.insert(i)
            nodes.append(attributes(of: e, allowNew: false))
        }
        // Anything referred to but never described (over the limit): an empty node, so ids stay valid.
        for i in 0..<order.count where !done.contains(i) { nodes.append(AXFixture.Node(id: i, attrs: [:], params: [], actions: [])) }
        nodes.sort { $0.id < $1.id }
        let appEl = ancestors.last.flatMap { $0.axRole == "AXApplication" ? ids[Key(e: $0)] : nil }
        var focus: Int?
        if let a = ancestors.last, a.axRole == "AXApplication", let f = a.axElement(kAXFocusedUIElementAttribute) { focus = ids[Key(e: f)] }
        let f = ISO8601DateFormatter()
        return AXFixture(app: app?.localizedName ?? "", bundle: app?.bundleIdentifier ?? "", recorded: f.string(from: Date()),
                         root: 0, application: appEl, focus: focus, nodes: nodes)
    }
}

extension AXUIElement {
    var axRole: String {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(self, kAXRoleAttribute as CFString, &v) == .success ? (v as? String ?? "") : ""
    }
    func axElement(_ name: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func axElements(_ name: String) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success else { return [] }
        return (v as? [AXUIElement]) ?? []
    }
}

// MARK: - Replay

/// A recording served through the shim. One recording at a time; its elements are application elements with
/// pids from `floor` up, one per node, so CFEqual and CFHash work on them as on the real thing.
public enum AXReplay {
    public static let floor: pid_t = 900_000
    nonisolated(unsafe) private static var fixture: AXFixture?
    nonisolated(unsafe) private static var byId: [Int: AXFixture.Node] = [:]
    /// Actions performed and attributes set during the test, in order.
    nonisolated(unsafe) public private(set) static var actions: [(id: Int, action: String)] = []
    nonisolated(unsafe) public private(set) static var sets: [(id: Int, attribute: String, value: AXFixture.Value?)] = []
    /// Attributes read, in order, while a test keeps this list (nil, the default, records nothing): for checking that
    /// something is left unread.
    nonisolated(unsafe) public static var reads: [(id: Int, attribute: String)]?

    // The shim (Sources/AXReplayShim) must be a library dyld loaded at launch for its interposing to count, so
    // the test runner inserts libAXReplayShim.dylib (DYLD_INSERT_LIBRARIES) and this finds its install function
    // by name; a copy linked into the executable would be the wrong one.
    public typealias AttrFn = @convention(c) (AXUIElement?, CFString?, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> AXError
    public typealias NamesFn = @convention(c) (AXUIElement?, UnsafeMutablePointer<Unmanaged<CFArray>?>?) -> AXError
    public typealias ParamFn = @convention(c) (AXUIElement?, CFString?, CFTypeRef?, UnsafeMutablePointer<Unmanaged<CFTypeRef>?>?) -> AXError
    public typealias ActionFn = @convention(c) (AXUIElement?, CFString?) -> AXError
    public typealias SetFn = @convention(c) (AXUIElement?, CFString?, CFTypeRef?) -> AXError
    private typealias InstallFn = @convention(c) (pid_t, AttrFn?, NamesFn?, NamesFn?, NamesFn?, ParamFn?, ActionFn?, SetFn?) -> Void
    private static let installFn: InstallFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "axreplay_install") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(sym, to: InstallFn.self)
    }()
    /// Whether the shim is loaded (the test runner re-launches itself with it when not).
    public static var isAvailable: Bool { installFn != nil }
    /// The shim beside an executable, for DYLD_INSERT_LIBRARIES.
    public static func shimPath(besides executable: String) -> String {
        URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent("libAXReplayShim.dylib").path
    }

    public static func load(_ f: AXFixture) {
        fixture = f
        byId = Dictionary(uniqueKeysWithValues: f.nodes.map { ($0.id, $0) })
        actions = []; sets = []
        installFn?(floor, attrFn, attrNamesFn, paramNamesFn, actionNamesFn, paramFn, actionFn, setFn)
    }
    public static func unload() { fixture = nil; byId = [:]; installFn?(0, nil, nil, nil, nil, nil, nil, nil) }

    /// The element for a node.
    public static func element(_ id: Int) -> AXUIElement { AXUIElementCreateApplication(floor + pid_t(id)) }
    public static func id(of e: AXUIElement?) -> Int? {
        guard let e else { return nil }
        var p: pid_t = 0; AXUIElementGetPid(e, &p)
        return p >= floor ? Int(p - floor) : nil
    }
    public static var root: AXUIElement? { fixture.map { element($0.root) } }
    public static var focus: AXUIElement? { fixture?.focus.map { element($0) } }
    public static var application: AXUIElement? { fixture?.application.map { element($0) } }

    static let applicationAttributes: Set<String> = [kAXFocusedWindowAttribute, kAXFocusedUIElementAttribute, kAXMainWindowAttribute, kAXWindowsAttribute, kAXMenuBarAttribute, kAXFrontmostAttribute, kAXHiddenAttribute]

    static func cf(_ v: AXFixture.Value) -> CFTypeRef {
        switch v {
        case .string(let s): return s as CFString
        case .number(let n): return (n == n.rounded() && abs(n) < 1e15 ? NSNumber(value: Int(n)) : NSNumber(value: n)) as CFNumber
        case .bool(let b): return b ? kCFBooleanTrue : kCFBooleanFalse
        case .element(let i): return element(i)
        case .elements(let ids): return ids.map { element($0) } as CFArray
        case .strings(let ss): return ss as CFArray
        case .point(let x, let y): var p = CGPoint(x: x, y: y); return AXValueCreate(.cgPoint, &p)!
        case .size(let w, let h): var s = CGSize(width: w, height: h); return AXValueCreate(.cgSize, &s)!
        case .range(let l, let n): var r = CFRange(location: l, length: n); return AXValueCreate(.cfRange, &r)!
        case .rect(let x, let y, let w, let h): var r = CGRect(x: x, y: y, width: w, height: h); return AXValueCreate(.cgRect, &r)!
        case .url(let u): return (URL(string: u) ?? URL(fileURLWithPath: "/")) as CFURL
        }
    }

    private static let attrFn: AttrFn = { e, a, out in
        guard let i = id(of: e), var n = byId[i], let a else { return .invalidUIElement }
        let name = a as String
        reads?.append((i, name))
        // Every replayed element has a pid of its own, so "the application of this pid" is the element itself:
        // the application's questions (its focused window, its focus) are answered by the recorded application.
        if n.attrs[name] == nil, Self.applicationAttributes.contains(name), let app = fixture?.application, let an = byId[app] { n = an }
        guard let v = n.attrs[name] else { return n.attrs.isEmpty ? .invalidUIElement : .noValue }
        out?.pointee = Unmanaged.passRetained(cf(v))
        return .success
    }
    private static let attrNamesFn: NamesFn = { e, out in
        guard let i = id(of: e), let n = byId[i] else { return .invalidUIElement }
        out?.pointee = Unmanaged.passRetained(n.attrs.keys.sorted() as CFArray)
        return .success
    }
    private static let paramNamesFn: NamesFn = { e, out in
        guard let i = id(of: e), let n = byId[i] else { return .invalidUIElement }
        out?.pointee = Unmanaged.passRetained(n.params as CFArray)
        return .success
    }
    private static let actionNamesFn: NamesFn = { e, out in
        guard let i = id(of: e), let n = byId[i] else { return .invalidUIElement }
        out?.pointee = Unmanaged.passRetained(n.actions as CFArray)
        return .success
    }
    /// Text questions answered from the recorded value: a string for a range, the line of an index, a line's range.
    private static let paramFn: ParamFn = { e, a, p, out in
        guard let i = id(of: e), let n = byId[i], let a, let p else { return .invalidUIElement }
        guard case .string(let text)? = n.attrs[kAXValueAttribute] else { return .parameterizedAttributeUnsupported }
        let chars = Array(text.utf16)
        func range() -> CFRange? { var r = CFRange(); guard CFGetTypeID(p) == AXValueGetTypeID(), AXValueGetValue((p as! AXValue), .cfRange, &r) else { return nil }; return r }
        func give(_ v: CFTypeRef) -> AXError { out?.pointee = Unmanaged.passRetained(v); return .success }
        // Lines as the text's own breaks make them.
        var lines: [CFRange] = []; var start = 0
        for (k, c) in chars.enumerated() where c == 10 { lines.append(CFRange(location: start, length: k + 1 - start)); start = k + 1 }
        lines.append(CFRange(location: start, length: chars.count - start))
        switch a as String {
        case kAXStringForRangeParameterizedAttribute, kAXAttributedStringForRangeParameterizedAttribute:
            guard let r = range(), r.location >= 0, r.location + r.length <= chars.count else { return .illegalArgument }
            let s = String(utf16CodeUnits: Array(chars[r.location..<r.location + r.length]), count: r.length)
            return give(a as String == kAXStringForRangeParameterizedAttribute ? s as CFString : NSAttributedString(string: s))
        case kAXLineForIndexParameterizedAttribute:
            guard let idx = (p as? NSNumber)?.intValue else { return .illegalArgument }
            let line = lines.firstIndex { idx >= $0.location && idx < $0.location + $0.length } ?? (lines.count - 1)
            return give(NSNumber(value: line))
        case kAXRangeForLineParameterizedAttribute:
            guard let l = (p as? NSNumber)?.intValue, lines.indices.contains(l) else { return .illegalArgument }
            var r = lines[l]; return give(AXValueCreate(.cfRange, &r)!)
        case kAXRangeForIndexParameterizedAttribute:
            guard let idx = (p as? NSNumber)?.intValue, idx >= 0, idx < chars.count else { return .illegalArgument }
            var r = CFRange(location: idx, length: 1); return give(AXValueCreate(.cfRange, &r)!)
        default: return .parameterizedAttributeUnsupported
        }
    }
    private static let actionFn: ActionFn = { e, a in
        guard let i = id(of: e), let a else { return .invalidUIElement }
        actions.append((i, a as String)); return .success
    }
    private static let setFn: SetFn = { e, a, v in
        guard let i = id(of: e), var n = byId[i], let v, let a else { return .invalidUIElement }
        let t = CFGetTypeID(v)
        var value: AXFixture.Value?
        if t == CFStringGetTypeID() { value = .string(v as! String) }
        else if t == CFBooleanGetTypeID() { value = .bool(CFBooleanGetValue((v as! CFBoolean))) }
        else if t == CFNumberGetTypeID() { value = .number((v as! NSNumber).doubleValue) }
        else if t == CFArrayGetTypeID() {
            let array = v as! CFArray
            let count = CFArrayGetCount(array)
            guard count <= 128 else { return .illegalArgument }
            var ids: [Int] = []
            withExtendedLifetime(array) {
                for index in 0..<count {
                    guard let pointer = CFArrayGetValueAtIndex(array, index) else { continue }
                    let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                    guard CFGetTypeID(object) == AXUIElementGetTypeID(), let elementID = id(of: object as! AXUIElement), byId[elementID] != nil else { continue }
                    ids.append(elementID)
                }
            }
            guard ids.count == count else { return .illegalArgument }
            // Replayed selection writes must read back like the provider, rather than returning success while
            // silently dropping arrays. Only bounded arrays of elements in this synthetic fixture are accepted.
            value = .elements(ids)
        }
        else if t == AXValueGetTypeID(), AXValueGetType((v as! AXValue)) == .cfRange { var r = CFRange(); AXValueGetValue((v as! AXValue), .cfRange, &r); value = .range(r.location, r.length) }
        sets.append((i, a as String, value))
        if let value { n.attrs[a as String] = value; byId[i] = n }
        return .success
    }
}
