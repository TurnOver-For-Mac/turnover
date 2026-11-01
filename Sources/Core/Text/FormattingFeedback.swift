// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit
import TurnOverAX

/// Feedback for native formatting shortcuts that no script owns. The key keeps its normal delivery;
/// only a verified provider result is spoken. Character attributes do not establish insertion style.
package final class FormattingFeedback {
    nonisolated package enum Kind: String, Sendable { case bold, italic }
    nonisolated package enum State: Sendable, Equatable { case on, off, mixed, unknown }
    nonisolated package struct Context: Sendable {
        package let focus: AXUIElement
        package let foreground: AXUIElement?
        package let pid: pid_t
        package let bundleIdentifier: String
        package let keys: Int

        package init(focus: AXUIElement, foreground: AXUIElement?, pid: pid_t, bundleIdentifier: String, keys: Int) {
            self.focus = focus; self.foreground = foreground; self.pid = pid
            self.bundleIdentifier = bundleIdentifier; self.keys = keys
        }
    }
    nonisolated package struct MouseClicks: Sendable, Equatable {
        package var left: UInt32
        package var right: UInt32
        package var other: UInt32

        package init(left: UInt32, right: UInt32, other: UInt32) {
            self.left = left; self.right = right; self.other = other
        }

        package static func current() -> MouseClicks {
            .init(left: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown),
                  right: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown),
                  other: CGEventSource.counterForEventType(.combinedSessionState, eventType: .otherMouseDown))
        }
    }
    nonisolated private struct Freshness: Sendable {
        let began: UInt64
        let mouse: MouseClicks

        func permits(at now: UInt64, mouse: MouseClicks) -> Bool {
            now >= began && now - began < 1_000_000_000 && mouse == self.mouse
        }
    }
    package typealias Provider = @Sendable (Context, Kind, AXWalkBudget) -> State
    package typealias Read = @MainActor (Context, Kind, @escaping Provider, @escaping @MainActor (State) -> Void) -> Void

    // Only providers with observed current-state semantics are enabled (#212).
    package static var shared = FormattingFeedback(provider: { context, kind, budget in
        switch context.bundleIdentifier {
        case "com.apple.TextEdit": TextEditFormatting.read(context, kind, budget)
        case "com.ulyssesapp.mac": UlyssesFormatting.read(context, kind, budget)
        default: .unknown
        }
    })
    private let provider: Provider?
    private let isCurrent: @MainActor (pid_t) -> Bool
    private let keyCount: @Sendable () -> Int
    private let now: @Sendable () -> UInt64
    private let mouseClicks: @Sendable () -> MouseClicks
    private let after: @MainActor (@escaping @MainActor () -> Void) -> Void
    private let read: Read?
    private let worker = AXWalkRunner<State>()
    private var pending: UUID?

    package init(provider: Provider? = nil,
                 isCurrent: @escaping @MainActor (pid_t) -> Bool = { pid in
                     Core.active && API.focusPid == pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                         && !AXHandler.shared.isMenuOpen && !TurnOverMenu.shared.isOpen
                         && InputManager.directPid != pid && !InputManager.isAsleep(pid)
                 }, keyCount: @escaping @Sendable () -> Int = { ScriptHandler.keysArrivedCount },
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 mouseClicks: @escaping @Sendable () -> MouseClicks = { MouseClicks.current() },
                 after: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void = { reply in onMain(after: 0.08, reply) },
                 read: Read? = nil) {
        self.provider = provider; self.isCurrent = isCurrent; self.keyCount = keyCount
        self.now = now; self.mouseClicks = mouseClicks; self.after = after; self.read = read
    }

    package func cancel() {
        pending = nil
        worker.cancel()
    }

    /// Called before normal pass-through is scheduled, so an app/focus change cannot retarget the original key.
    package func keyWillPassThrough(_ gesture: KeyboardGesture) {
        guard let provider, !gesture.isRepeat, !gesture.isTurnOverModifier, gesture.modifiers == [.command],
              let kind = ["b": Kind.bold, "i": Kind.italic][gesture.keyName],
              let focus = API.focusObject as? EditableText, focus.role != .passwordEdit,
              isCurrent(focus.pid) else { return }
        let bundle = focus.appModule.bundleIdentifier
        // Word owns these scripts and queries its selection through its existing automation bridge.
        guard bundle != "com.microsoft.Word" else { return }
        let context = Context(focus: focus.element, foreground: API.foregroundObject?.element,
                              pid: focus.pid, bundleIdentifier: bundle, keys: keyCount())
        let id = UUID()
        // AX selection events caused by the formatting command are valid. A new mouse click can move the caret
        // inside the same editor without a key/focus event, so capture public session counters instead (#212).
        let freshness = Freshness(began: now(), mouse: mouseClicks())
        pending = id
        after { [weak self] in
            guard let self, self.canReply(id, context, freshness) else { return }
            let reply: @MainActor (State) -> Void = { [weak self] state in
                guard let self, self.canReply(id, context, freshness) else { return }
                self.pending = nil   // even an accidentally repeated completion can speak only once
                switch (kind, state) {
                case (.bold, .on): Speech.speakMessage(String(localized: "bold on"))
                case (.bold, .off): Speech.speakMessage(String(localized: "bold off"))
                case (.bold, .mixed): Speech.speakMessage(String(localized: "bold mixed"))
                case (.italic, .on): Speech.speakMessage(String(localized: "italic on"))
                case (.italic, .off): Speech.speakMessage(String(localized: "italic off"))
                case (.italic, .mixed): Speech.speakMessage(String(localized: "italic mixed"))
                case (_, .unknown): break
                }
            }
            if let read = self.read { read(context, kind, provider, reply) }
            else {
                let keys = self.keyCount, clock = self.now, clicks = self.mouseClicks
                self.worker.submit { request in
                    // Only immutable snapshots and a locked key counter cross onto the AX worker. A stuck provider
                    // cannot delay native keys; its result expires, and later requests replace queued work (#212).
                    let budget = AXWalkBudget(request: request, duration: 500_000_000, maxVisits: 160,
                                              maxQueries: 800, maxAXQueries: 800, maxDepth: 12)
                    let current = { @Sendable in keys() == context.keys && freshness.permits(at: clock(), mouse: clicks()) }
                    guard current(), budget.check() else { return .unknown }
                    let state = AXReadScope.with(while: { budget.check() && current() },
                                                 onQuery: { budget.admitAXQuery() }, onResult: { budget.record($0) }) {
                        provider(context, kind, budget)
                    }
                    return budget.check() && current() ? state : .unknown
                } publish: { state in reply(state) }
            }
        }
    }

    private func canReply(_ id: UUID, _ context: Context, _ freshness: Freshness) -> Bool {
        pending == id && keyCount() == context.keys && freshness.permits(at: now(), mouse: mouseClicks())
            && isCurrent(context.pid)
            && API.focusObject?.isSameElement(as: context.focus) == true
            && Self.same(API.foregroundObject?.element, context.foreground)
    }

    private static func same(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): CFEqual(lhs, rhs)
        default: false
        }
    }
}
