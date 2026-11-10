// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

nonisolated struct BrowseRootCollection: Sendable {
    let window: AXUIElement?
    let collection: WebBufferCollection?
    /// The window's page as the app gives it now, asked on the worker: the answer when the collection has no page in
    /// it (it was cut short, or an element on the way to the page did not answer its batch).
    let liveRoot: AXUIElement?

    static func collect(pid: pid_t, request: AXWalkRequest) -> Self {
        let budget = AXWalkBudget(request: request, startedAt: DispatchTime.now().uptimeNanoseconds)
        return AXReadScope.with(while: { budget.check() }, onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
            let app = AXUIElementCreateApplication(pid)
            guard let window = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute), budget.check() else {
                return Self(window: nil, collection: nil, liveRoot: nil)
            }
            let live = window.firstDescendant(role: "AXWebArea", maxVisited: 400)
            return Self(window: window, collection: WebBufferCollection.collect(root: window, focus: nil, request: request), liveRoot: live)
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
            var how = "in the collection"
            var fresh: AXUIElement? = result.collection?.snapshot.with {
                guard let window = result.window else { return nil }
                let root = window.firstDescendant(role: "AXWebArea", maxVisited: 400)
                    ?? AppModuleHandler.shared.appModule(for: pid).browseRoot(inWindow: window)
                if !requireEmpty, root?.elements(kAXChildrenAttribute).isEmpty != false { return nil }
                return root
            }
            // The page the app gave the worker, when the collection holds none (only for an empty document: with
            // `requireEmpty` off the page must be seen to have content, which only the collection can say).
            if fresh == nil, requireEmpty, let live = result.liveRoot { fresh = live; how = "asked of the app" }
            if let fresh, !fresh.isSame(webArea) {
                Log.io("browse mode: the page root was replaced; following the current window (\(how))")
                AXHandler.shared.focusChanged(fresh, pid: pid)
                completion(true)
            } else {
                // Why not, for the log (10 Nov 2026: a replaced Safari page was not followed for ten seconds, and
                // nothing said which of these it was).
                let why = result.window == nil ? "the app gave no window"
                    : fresh != nil ? "the window's page is the one already read"
                    : "no page in the window (\(result.collection?.snapshot.nodes.count ?? 0) elements collected, stop \(result.collection?.stop?.rawValue ?? "none"); asked of the app: \(result.liveRoot == nil ? "none" : "one"))"
                Log.io("browse mode: looked for the window's current page: \(why)")
                completion(false)
            }
        })
    }

    /// The page's own element stopped answering (the app replaced it): look for the window's current page now and
    /// for five seconds, rather than at the next key and a second after it. One chase at a time.
    func followAfterRootFailure() {
        guard !followingRootFailure else { return }
        followingRootFailure = true
        let epoch = pageGeneration
        func attempt(_ left: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, pageGeneration == epoch else { return }
                guard API.focusTreeInterceptor === self, buffer.lines.isEmpty else { followingRootFailure = false; return }
                followCurrentRoot { [weak self] followed in
                    guard let self, pageGeneration == epoch else { return }
                    if followed || left <= 1 { followingRootFailure = false } else { attempt(left - 1) }
                }
            }
        }
        attempt(20)
    }
}
