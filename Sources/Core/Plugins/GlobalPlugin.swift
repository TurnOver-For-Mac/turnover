// SPDX-License-Identifier: GPL-3.0-or-later
// Global plugins (NVDA: globalPluginHandler): a global plugin sees every event and can bind scripts that work
// everywhere. TurnOver's own are registered at start (Core.start); plugins made by users are data, not code
// (PluginFormat.swift). An add-on loader that opened dynamic libraries from a folder was here until 20 Oct 2026,
// never reached: code from a user-writable folder has no place in a reader with this much access.
import Foundation
import ApplicationServices

open class GlobalPlugin: ScriptableObject {
    public required override init() { super.init() }
    /// NVDA: chooseNVDAObjectOverlayClasses on a global plugin.
    open func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? { nil }
    /// Every event passes here first (NVDA: event_* with nextHandler).
    open func handleEvent(_ event: Event, next: () -> Void) { next() }
    open func terminate() {}
}

public final class GlobalPluginHandler {
    public static let shared = GlobalPluginHandler()
    private let lock = NSLock()
    private var _plugins: [GlobalPlugin] = []
    public var plugins: [GlobalPlugin] { lock.lock(); defer { lock.unlock() }; return _plugins }

    public func register(_ type: GlobalPlugin.Type) {
        let p = type.init()
        lock.lock(); _plugins.append(p); lock.unlock()
        Log.info("global plugin \(String(describing: type)) running")
    }
    public func terminateAll() {
        lock.lock(); let all = _plugins; _plugins.removeAll(); lock.unlock()
        all.forEach { $0.terminate() }
    }
}
