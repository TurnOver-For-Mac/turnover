// SPDX-License-Identifier: GPL-3.0-or-later
// App modules (NVDA: appModuleHandler.AppModule). One per running application,
// keyed by bundle identifier: it can choose object classes for the app's
// controls, redirect a misreported focus, handle the app's events before the
// objects do, and carry scripts that work anywhere in that app. An app with no
// module of its own gets the base class.
import Foundation
import AppKit
import ApplicationServices

open class AppModule: ScriptableObject {
    public let pid: pid_t
    public let bundleIdentifier: String
    public let appName: String

    public required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        self.pid = pid; self.bundleIdentifier = bundleIdentifier; self.appName = appName
        super.init()
    }

    /// NVDA: chooseNVDAObjectOverlayClasses — a class for this element, or nil for the default.
    open func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? { nil }

    /// Supplement the app's spelling marks with macOS's checker. With no marks, the checker is always a fallback.
    open var supplementsSpellingMarks: Bool { true }

    /// A grid's selection changed while the focus is in it (AXSelectedCellsChanged; `count` cells now selected). True
    /// if the module has said what is needed; false for TurnOver's own handling (one cell selected: it is the focus).
    open func gridSelectionChanged(_ table: AXUIElement, count: Int) -> Bool { false }

    /// An element the module reads as a document in browse mode though it isn't a web area (Preview's pages), or nil.
    open func browseRoot(for element: AXUIElement, ancestors: [TurnOverObject]) -> AXUIElement? { nil }

    /// The module's document in a window now, for a page that was replaced (Kindle's next sign-in step), or nil.
    open func browseRoot(inWindow window: AXUIElement) -> AXUIElement? { nil }

    /// Pages whose controls can't be given the keyboard by accessibility (Kindle's iOS web view): Tab in browse mode
    /// moves the reading position to the next control and reads it, rather than sending Tab nowhere.
    open var browseTabMovesReadingPosition: Bool { false }

    /// Say all reached the end of `obj`'s text: the module may carry on (Kindle turns the page) and call `resume` with
    /// where to read next. True when it will; say all then waits rather than saying "end of document".
    open func sayAllReachedEnd(_ obj: TurnOverObject, resume: @escaping (TextInfo) -> Void) -> Bool { false }

    /// A field whose focus can't be set by accessibility: the module may put the keyboard there itself (a click).
    /// True when it did.
    open func takeFocus(_ element: AXUIElement) -> Bool { false }

    /// Where the app misreports its focus, the element that really has it.
    open func redirectFocus(_ element: AXUIElement) -> AXUIElement? { nil }

    /// A focus event the module will ignore, asked before anything acts on it: the speech for the focus before
    /// is not dropped for it (Word's page blipping between a dialog's fields cut each field to its first letter;
    /// A tester, 16 Oct 2026).
    open func ignoresFocus(_ event: Event) -> Bool { false }

    /// Events for every object in the app pass here first (NVDA: event_* with nextHandler).
    open func handleEvent(_ event: Event, next: () -> Void) {
        switch event.kind {
        case .appModuleGainFocus: event_appModuleGainFocus()
        case .appModuleLoseFocus: event_appModuleLoseFocus()
        default: break
        }
        next()
    }
    open func event_appModuleGainFocus() {}
    open func event_appModuleLoseFocus() {}

    /// The app quit or TurnOver is stopping.
    open func terminate() {}

    /// This application's own section of the TurnOver menu (NVDA: an add-on's settings panel): empty by default.
    open func menuItems() -> [MenuItem] { [] }

    open var isAlive: Bool { NSRunningApplication(processIdentifier: pid) != nil }
}

public final class AppModuleHandler {
    public static let shared = AppModuleHandler()
    private var registry: [String: AppModule.Type] = [:]
    private var modules: [pid_t: AppModule] = [:]
    private let lock = NSLock()

    /// The module class registered for an app, if any (the plugin checker's clash check).
    public func moduleType(for bundleIdentifier: String) -> AppModule.Type? { lock.lock(); defer { lock.unlock() }; return registry[bundleIdentifier] }
    /// Register a module class for a bundle identifier (built in, or from an add-on).
    public func register(_ type: AppModule.Type, for bundleIdentifier: String) {
        lock.lock(); registry[bundleIdentifier] = type; lock.unlock()
        // A running instance of the base class is replaced on next use.
        lock.lock()
        for (pid, m) in modules where m.bundleIdentifier == bundleIdentifier && Swift.type(of: m) != type { modules.removeValue(forKey: pid) }
        lock.unlock()
    }

    public func unregister(bundleIdentifier: String) {
        lock.lock(); registry.removeValue(forKey: bundleIdentifier)
        // A running module goes too: a plugin's view removed at a reload stayed in charge until the app was quit
        // (parts request #6, Libation, 14 Oct 2026). The next use makes a plain one.
        let gone = modules.filter { $0.value.bundleIdentifier == bundleIdentifier }
        for pid in gone.keys { modules.removeValue(forKey: pid) }
        lock.unlock()
        gone.values.forEach { $0.terminate() }
    }

    /// The module for a process, created on first use (NVDA: getAppModuleFromProcessID).
    public func appModule(for pid: pid_t) -> AppModule {
        lock.lock()
        if let m = modules[pid] { lock.unlock(); return m }
        let app = NSRunningApplication(processIdentifier: pid)
        let bundle = app?.bundleIdentifier ?? "pid.\(pid)"
        let name = app?.localizedName ?? bundle
        let type = registry[bundle] ?? AppModule.self
        lock.unlock()
        // Made outside the lock: a module whose init makes an object asks for its module again, and the lock isn't
        // recursive (a code review, 14 Oct 2026; latent until a plugin module does it).
        let m = type.init(pid: pid, bundleIdentifier: bundle, appName: name)
        lock.lock()
        if let raced = modules[pid] { lock.unlock(); return raced }
        modules[pid] = m
        lock.unlock()
        Log.info("app module \(String(describing: type)) for \(name) (\(bundle), pid \(pid))")
        return m
    }

    public func remove(pid: pid_t) {
        lock.lock(); let m = modules.removeValue(forKey: pid); lock.unlock()
        m?.terminate()
    }

    public func terminateAll() {
        lock.lock(); let all = modules.values; modules.removeAll(); lock.unlock()
        all.forEach { $0.terminate() }
    }

    public var registeredBundleIdentifiers: [String] { lock.lock(); defer { lock.unlock() }; return Array(registry.keys) }
}
