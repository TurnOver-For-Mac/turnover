// SPDX-License-Identifier: GPL-3.0-or-later
// The focus and the foreground (NVDA: api). What has the focus right now, the
// ancestors it sits in, and the window in front. Written on the main thread by
// the accessibility handler; read from any thread (the keyboard thread resolves
// scripts against it) through a locked snapshot.
import Foundation
import ApplicationServices

public enum API {
    private static let lock = NSLock()
    private static var _focus: TurnOverObject?
    private static var _ancestors: [TurnOverObject] = []
    private static var _foreground: TurnOverObject?
    private static var _interceptor: BrowseModeDocument?

    /// The focused object (NVDA: getFocusObject).
    public static var focusObject: TurnOverObject? { lock.lock(); defer { lock.unlock() }; return _focus }
    /// Its ancestors, nearest first (NVDA: getFocusAncestors).
    public static var focusAncestors: [TurnOverObject] { lock.lock(); defer { lock.unlock() }; return _ancestors }
    /// The foreground window (NVDA: getForegroundObject).
    public static var foregroundObject: TurnOverObject? { lock.lock(); defer { lock.unlock() }; return _foreground }
    /// The browse mode document the focus is inside, if any (NVDA: focus.treeInterceptor).
    public static var focusTreeInterceptor: BrowseModeDocument? { lock.lock(); defer { lock.unlock() }; return _interceptor }
    /// The object with the caret (NVDA: getCaretObject): the browse mode document in browse mode, else the focus.
    public static var caretObject: TurnOverObject? {
        if let d = focusTreeInterceptor, !d.passThrough { return d.rootObject }
        return focusObject
    }

    public static func setFocusObject(_ obj: TurnOverObject?, ancestors: [TurnOverObject], interceptor: BrowseModeDocument? = nil) {
        let pid = obj?.pid ?? 0
        if pid != focusedPid, obj?.appModule.bundleIdentifier == TurnOverSettingsAppModule.bundleID {
            KeyboardEditor.rememberContext()
        }
        lock.lock(); _focus = obj; _ancestors = ancestors; _interceptor = interceptor; lock.unlock()
        focusedPidValue.value = pid
    }
    nonisolated private static let focusedPidValue = Locked<pid_t>(0)
    /// The focused element's process, for the keyboard thread (0: none known). The Dock, a status menu or Spotlight
    /// have the focus in a process of their own while another app stays in front.
    nonisolated public static var focusedPid: pid_t { focusedPidValue.value }
    public static func setForegroundObject(_ obj: TurnOverObject?) {
        lock.lock(); _foreground = obj; lock.unlock()
    }

    /// The pid whose app module answers scripts: the focus's, else the frontmost app's.
    public static var focusPid: pid_t? { focusObject?.pid ?? foregroundObject?.pid }
}
