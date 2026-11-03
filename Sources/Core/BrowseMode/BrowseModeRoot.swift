// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated struct BrowseRootCollection: Sendable {
    let window: AXUIElement?
    let collection: WebBufferCollection?

    static func collect(pid: pid_t, request: AXWalkRequest) -> Self {
        let budget = AXWalkBudget(request: request)
        return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            let app = AXUIElementCreateApplication(pid)
            guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute), budget.check() else {
                return Self(window: nil, collection: nil)
            }
            return Self(window: window, collection: WebBufferCollection.collect(root: window, focus: nil, request: request))
        }
    }
}

extension BrowseModeDocument {
    /// Root replacement is another provider walk. A loading timer must not put it back onto main after the
    /// document itself moved to a worker. App root policies interpret the same frozen window attributes.
    func followCurrentRoot(requireEmpty: Bool = true, _ completion: @escaping (Bool) -> Void) {
        guard !discoveringRoot else { completion(false); return }
        discoveringRoot = true
        let epoch = pageGeneration, pid = webArea.pid
        rootRunner.submit(collect: { BrowseRootCollection.collect(pid: pid, request: $0) }, publish: { [weak self] result in
            guard let self, pageGeneration == epoch else { return }
            discoveringRoot = false
            guard API.focusTreeInterceptor === self, !requireEmpty || buffer.lines.isEmpty else { return }
            let fresh: AXUIElement? = result.collection?.snapshot.with {
                guard let window = result.window else { return nil }
                let root = window.firstDescendant(role: "AXWebArea", maxVisited: 400)
                    ?? AppModuleHandler.shared.appModule(for: pid).browseRoot(inWindow: window)
                if !requireEmpty, root?.elements(kAXChildrenAttribute).isEmpty != false { return nil }
                return root
            }
            if let fresh, !fresh.isSame(webArea) {
                Log.io("browse mode: the page root was replaced; following the current window")
                AXHandler.shared.focusChanged(fresh, pid: pid)
                completion(true)
            } else { completion(false) }
        })
    }
}
