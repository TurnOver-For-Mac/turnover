// SPDX-License-Identifier: GPL-3.0-or-later
// The one bridge to HIServices' private whole-subtree read, `AXUIElementCopyHierarchy`. Prototype, 10 Nov 2026.
//
// Why a private call: the public way to copy a window is one AXUIElementCopyMultipleAttributeValues per element,
// which is one round trip to the app per element. This call returns every descendant with the attributes asked for
// in one round trip. Measured on macOS 27.2 (26B118), 10 Nov 2026, nine attributes an element, against that public
// batched walk: Finder 1,227 elements 127 ms against 329 ms; Notes 5,774 elements 1.4 s against 3.9 s; a Safari page
// 52 ms in three calls against 163 ms; Claude (Electron) no gain, 46 ms against 38 ms.
//
// What was observed (same Mac, same day; nothing here is documented by Apple):
// - Signature, read from the disassembly: (element, non-empty CFArray of attribute names, optional CFDictionary of
//   options, out CFTypeRef) -> AXError. It needs no entitlement: an unsigned tool with Accessibility permission got
//   answers from Finder, Safari, Mail, Notes, Ulysses, TextEdit, Voice Memos and Claude.
// - The answer is a CFDictionary keyed by AXUIElement. Each value is a dictionary of attribute name to
//   {"value": the value} (arrays also carry "count"). An element the provider could not fill, which is what a
//   remote element such as WebKit's page content looks like from its host, has the key "incmplt" and no attributes;
//   asking again with that element as the root continues there.
// - The option keys (exported CFString constants) include a maximum depth, but in Finder a maximum depth of 1, 2, 4
//   or 8 returned the same whole window: the call cannot be relied on to stop early. It is bounded only by the
//   element's messaging timeout, after which it returns cannotComplete and nothing. No options are passed here.
//
// - A timeout does not stop the app's side of the work. A Safari page of about 56,000 elements, asked for from its
//   web content element, did not answer in time; the very next ordinary question to Safari then waited behind the
//   abandoned work, timed out too, and AXHealth rested Safari (Oliver's run of `turnover-probe snapshot`, 10 Nov
//   2026). So: the snapshot asks this way once, at the root, and never into the unfilled (remote) elements, where
//   on Safari it was no faster than the batched read anyway (16,830 elements: 0.64 s against 0.66 s); and after a
//   timeout the snapshot stops, and the app is spared this call for a minute.
//
// When the symbol is missing or the app says no, the caller walks with the public batched read instead
// (AXSnapshotCapture). Not checked on macOS 14, 15 or 26.
import Foundation
import ApplicationServices

public enum AXHierarchyBridge {
    private typealias CopyHierarchy = @convention(c) (AXUIElement, CFArray, CFDictionary?, UnsafeMutablePointer<CFTypeRef?>) -> AXError
    /// Looked up once; nil where this macOS has no such symbol.
    private static let function: CopyHierarchy? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AXUIElementCopyHierarchy") else { return nil }   // RTLD_DEFAULT
        return unsafeBitCast(symbol, to: CopyHierarchy.self)
    }()
    public static var isAvailable: Bool { function != nil }

    /// The marker on an element the provider left unfilled (the value of kAXUIElementCopyHierarchyIncompleteResultKey).
    static let incompleteKey = "incmplt"
    static let valueKey = "value"

    /// One element as the call returned it: its attributes unwrapped, or `incomplete` when the provider left it empty.
    public struct Entry {
        public var attributes: [String: AnyObject]
        public var incomplete: Bool
        public init(attributes: [String: AnyObject], incomplete: Bool) { self.attributes = attributes; self.incomplete = incomplete }
    }

    public enum Outcome {
        case answer([ElementKey: Entry])
        /// No such symbol on this macOS, the app is resting, the caller's read scope stopped, or the app said no at once.
        case unavailable
        /// The app did not answer within the messaging timeout. It is very likely still working on the answer nobody
        /// will read: every question put to it now waits behind that work (see `timedOutRecently`).
        case timedOut
    }

    /// A cannot-complete that took this long is a timeout; one that comes back at once is an app that is gone.
    static let timeoutFloorNs: UInt64 = 200_000_000
    /// How long an app whose whole-subtree read timed out is spared another: its window was too big a minute ago.
    static let spareNs: UInt64 = 60_000_000_000
    private static let lock = NSLock()
    // Swift cannot express static NSLock ownership. Every read and write of `timedOut` holds `lock`.
    nonisolated(unsafe) private static var timedOut: [pid_t: UInt64] = [:]

    /// True for a minute after this app failed to answer a whole-subtree read in time: the caller keeps to the
    /// batched read, which asks little at a time and can be stopped between questions.
    public static func timedOutRecently(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let at = timedOut[pid] else { return false }
        if DispatchTime.now().uptimeNanoseconds &- at < spareNs { return true }
        timedOut[pid] = nil
        return false
    }
    package static func forget(pid: pid_t) { lock.lock(); timedOut[pid] = nil; lock.unlock() }
    package static func noteTimeout(pid: pid_t) { lock.lock(); timedOut[pid] = DispatchTime.now().uptimeNanoseconds; lock.unlock() }

    /// Every element under `root` (and `root` itself) with `names`, in one question.
    public static func copy(_ root: AXUIElement, _ names: [String]) -> Outcome {
        guard let function, !names.isEmpty else { return .unavailable }
        var out: CFTypeRef?
        let execution = AXHealth.query(root, policy: .bulkRead) { function(root, names as CFArray, nil, &out) }
        if execution.wasAttempted, execution.legacyError == .cannotComplete, execution.elapsedNanoseconds >= timeoutFloorNs {
            noteTimeout(pid: root.pid)
            return .timedOut
        }
        guard execution.legacyError == .success, let out, CFGetTypeID(out) == CFDictionaryGetTypeID() else { return .unavailable }
        return .answer(entries(from: out as! CFDictionary))   // checked: a CFDictionary
    }

    /// The raw answer as entries. Anything not shaped as observed is skipped, never trusted. Package-visible so the
    /// tests can feed it a dictionary built by hand.
    package static func entries(from raw: CFDictionary) -> [ElementKey: Entry] {
        var result: [ElementKey: Entry] = [:]
        let count = CFDictionaryGetCount(raw)
        var keys = [UnsafeRawPointer?](repeating: nil, count: count)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFDictionaryGetKeysAndValues(raw, &keys, &values)
        for (k, v) in zip(keys, values) {
            guard let k, let v else { continue }
            let key = Unmanaged<CFTypeRef>.fromOpaque(k).takeUnretainedValue()
            let value = Unmanaged<CFTypeRef>.fromOpaque(v).takeUnretainedValue()
            guard let element = axElement(key), let fields = value as? [String: AnyObject] else { continue }
            var attributes: [String: AnyObject] = [:]
            for (name, wrapped) in fields where name != incompleteKey {
                if let inner = (wrapped as? [String: AnyObject])?[valueKey] { attributes[name] = inner }
            }
            result[ElementKey(element)] = Entry(attributes: attributes, incomplete: fields[incompleteKey] != nil)
        }
        return result
    }
}
