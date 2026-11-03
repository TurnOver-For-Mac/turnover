// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// A website is selected by its document, independently of the browser's native app module.
nonisolated package struct DocumentContext: Sendable {
    package let root: AXUIElement
    package let url: String
    package let ownerPid: pid_t
    package init(root: AXUIElement, url: String, ownerPid: pid_t) {
        self.root = root; self.url = url; self.ownerPid = ownerPid
    }
}

nonisolated package struct DocumentFocus: Sendable {
    package let element: AXUIElement
    package let role: String
    package var isSecure = false
    package init(element: AXUIElement, role: String, isSecure: Bool = false) {
        self.element = element; self.role = role; self.isSecure = isSecure
    }
}

package protocol DocumentAdapter: AnyObject {
    var usesNativeTextFeedback: Bool { get }
    func activate(isCurrent: @escaping @MainActor () -> Bool)
    func focusChanged(_ focus: DocumentFocus)
    func deactivate()
}

/// Owns bounded, in-memory document sessions. API publishes focus snapshots here; no key path walks AX parents.
package final class DocumentAdapters {
    package static var shared = DocumentAdapters()
    package typealias Factory = (DocumentContext) -> any DocumentAdapter
    private struct Registration {
        let id: String
        let matches: (String) -> Bool
        let make: Factory
    }
    private final class Entry {
        let context: DocumentContext
        let adapter: any DocumentAdapter
        init(_ context: DocumentContext, _ adapter: any DocumentAdapter) { self.context = context; self.adapter = adapter }
    }
    private var registrations: [Registration] = []
    private var entries: [Entry] = []
    private var current: Entry?
    private var focus: DocumentFocus?
    private var root: AXUIElement?
    private var ownerPid: pid_t = 0
    private var enabled = true
    private let allowed: () -> Bool

    package init(allowed: @escaping () -> Bool = {
        guard Core.active, let obj = API.focusObject, obj.role != .passwordEdit, InputManager.directPid != obj.pid,
              !InputManager.isAsleep(obj.pid), !AXHandler.anyMenuOpen.value, !TurnOverMenu.shared.isOpen,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == AXHandler.shared.activePid else { return false }
        if let window = API.focusAncestors.last(where: { $0.axRole == "AXWindow" }),
           let foreground = API.foregroundObject, foreground.axRole == "AXWindow" {
            return window.isSameElement(as: foreground)
        }
        return true
    }) { self.allowed = allowed }

    package func register(_ id: String, matches: @escaping (String) -> Bool, make: @escaping Factory) {
        registrations.removeAll { $0.id == id }
        registrations.append(Registration(id: id, matches: matches, make: make))
    }

    package func focusChanged(_ obj: TurnOverObject?, ancestors: [TurnOverObject], document: BrowseModeDocument?) {
        guard enabled, allowed(), let obj,
              let web = ([obj] + ancestors).last(where: { $0.axRole == "AXWebArea" }) else { leave(); return }
        focus = DocumentFocus(element: obj.element, role: obj.axRole, isSecure: obj.role == .passwordEdit)
        root = web.element
        ownerPid = ancestors.last(where: { $0.axRole == "AXWindow" })?.pid ?? obj.pid
        // Browse mode already captured the URL when it built/refreshed this document. Where there is no
        // interceptor, one root attribute supplies the address; recognition never walks a tree on main.
        let url: String
        if let document, document.webArea.isSame(web.element), !document.lastURL.isEmpty { url = document.lastURL }
        else {
            let value = web.element.attr("AXURL")
            url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
        }
        select(DocumentContext(root: web.element, url: url, ownerPid: ownerPid))
    }

    package func pageChanged(root: AXUIElement, url: String) {
        guard self.root?.isSame(root) == true else { return }
        if let current, current.context.url == url { return }
        select(DocumentContext(root: root, url: url, ownerPid: ownerPid))
    }

    private func select(_ context: DocumentContext) {
        guard enabled, allowed(), let focus else { leave(); return }
        if let current, current.context.root.isSame(context.root), current.context.url == context.url {
            current.adapter.activate(isCurrent: eligibility(for: current))
            current.adapter.focusChanged(focus)
            return
        }
        current?.adapter.deactivate()
        current = nil
        guard let registration = registrations.first(where: { $0.matches(context.url) }) else { return }
        let entry: Entry
        if let known = entries.first(where: { $0.context.root.isSame(context.root) && $0.context.url == context.url }) { entry = known }
        else {
            entry = Entry(context, registration.make(context))
            entries.append(entry)
            if entries.count > 40 { entries.removeFirst().adapter.deactivate() }
        }
        current = entry
        entry.adapter.activate(isCurrent: eligibility(for: entry))
        entry.adapter.focusChanged(focus)
    }

    private func eligibility(for entry: Entry) -> @MainActor () -> Bool {
        { [weak self, weak entry] in
            guard let self, let entry else { return false }
            return self.enabled && self.current === entry && self.allowed()
        }
    }

    package func observe(_ event: Event) {
        // A caret event also resumes an editor already focused when the reader was activated.
        guard [.gainFocus, .caret].contains(event.kind), let obj = API.focusObject,
              obj.isSameElement(as: event.obj) else { return }
        focusChanged(obj, ancestors: API.focusAncestors, document: API.focusTreeInterceptor)
    }

    package func usesNativeTextFeedback(for element: AXUIElement) -> Bool {
        guard enabled, let current, focus?.element.isSame(element) == true else { return false }
        return allowed() && current.adapter.usesNativeTextFeedback
    }

    package func leave() {
        current?.adapter.deactivate()
        current = nil; root = nil; focus = nil; ownerPid = 0
    }
    package func suspend() { enabled = false; leave() }
    package func resume() { enabled = true }   // wait for a fresh focus/caret event, rather than adopting stale API state
    package func forget(pid: pid_t) {
        for entry in entries where entry.context.ownerPid == pid || entry.context.root.pid == pid {
            entry.adapter.deactivate()
            if current === entry { current = nil; root = nil; focus = nil }
        }
        entries.removeAll { $0.context.ownerPid == pid || $0.context.root.pid == pid }
    }
}
