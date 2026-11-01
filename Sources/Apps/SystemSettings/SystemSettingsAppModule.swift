// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX
import os

nonisolated private final class SettingsPartWork: Sendable {
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let deadline = DispatchTime.now().uptimeNanoseconds + 1_500_000_000
    func cancel() { cancelled.withLock { $0 = true } }
    func current() -> Bool { !cancelled.withLock { $0 } && DispatchTime.now().uptimeNanoseconds < deadline }
}

/// Explicit part commands only. The system's Tab, arrows, search editing and dialog navigation remain native.
package final class SystemSettingsAppModule: AppModule {
    package static let bundleID = "com.apple.systempreferences"

    nonisolated package struct Context: Sendable {
        package let window: AXUIElement
        package let focus: AXUIElement
        package let ancestors: [AXUIElement]
        package init(window: AXUIElement, focus: AXUIElement, ancestors: [AXUIElement] = []) {
            self.window = window; self.focus = focus; self.ancestors = ancestors
        }
    }
    package struct Dependencies {
        package var resolver: SystemSettingsPartResolving
        package var context: @MainActor () -> Context?
        package var keys: @Sendable () -> Int
        package var schedule: @MainActor (@escaping @Sendable () -> Void) -> Void
        package var deliver: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void
        package var freshlyEligible: @MainActor (SystemSettingsPartRequest, AXUIElement, @escaping @Sendable () -> Bool) -> Bool
        package var setFocus: @MainActor (AXUIElement) -> AXError
        package var review: @MainActor (AXUIElement) -> Void
        package var reportFocus: @MainActor (AXUIElement) -> Void
        package var speak: @MainActor (String) -> Void
        package init(resolver: SystemSettingsPartResolving, context: @escaping @MainActor () -> Context?,
                     keys: @escaping @Sendable () -> Int,
                     schedule: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void,
                     deliver: @escaping @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void,
                     freshlyEligible: @escaping @MainActor (SystemSettingsPartRequest, AXUIElement, @escaping @Sendable () -> Bool) -> Bool,
                     setFocus: @escaping @MainActor (AXUIElement) -> AXError,
                     review: @escaping @MainActor (AXUIElement) -> Void,
                     reportFocus: @escaping @MainActor (AXUIElement) -> Void,
                     speak: @escaping @MainActor (String) -> Void) {
            self.resolver = resolver; self.context = context; self.keys = keys; self.schedule = schedule
            self.deliver = deliver; self.setFocus = setFocus; self.review = review; self.reportFocus = reportFocus; self.speak = speak
            self.freshlyEligible = freshlyEligible
        }
    }
    nonisolated private struct Pending: Sendable {
        let work: SettingsPartWork
        let request: SystemSettingsPartRequest
        let context: Context
        let keys: Int
        var target: AXUIElement?
    }
    private var dependencies: Dependencies
    private var pending: Pending?
    private var active = true
    private var terminated = false

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        let queue = DispatchQueue(label: "turnover.system-settings.parts", qos: .userInitiated)
        dependencies = .init(resolver: SystemSettingsAXParts(), context: { Self.context(pid: pid) },
                             keys: { ScriptHandler.keysArrivedCount }, schedule: { queue.async(execute: $0) },
                             deliver: { onMain($0) }, freshlyEligible: { SystemSettingsAXParts.eligible($0, focus: $1, current: $2) },
                             setFocus: { $0.set(kAXFocusedAttribute, kCFBooleanTrue) },
                             review: { ObjectNavigator.shared.releaseHold(); ObjectNavigator.shared.place($0) },
                             reportFocus: { target in
                                 if API.focusObject?.isSameElement(as: target) != true { AXHandler.shared.focusChanged(target, pid: pid) }
                             }, speak: { Speech.speakOnly($0) })
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        for part in SystemSettingsPart.allCases {
            script("systemSettings_\(part)", "Moves to the \(part.name); uses the review cursor if keyboard focus is unavailable",
                   gestures: ["kb:control+command+\(part.rawValue + 1)"], category: "System Settings") { [weak self] _ in
                self?.move(to: part)
            }.isAvailable = { [weak self] in self?.isAvailable == true }
        }
    }

    /// Package-only dependency seam: tests invoke the registered module's real command handlers and lifecycle.
    package func useForTesting(_ dependencies: Dependencies) { retire(); self.dependencies = dependencies }

    private static func context(pid: pid_t) -> Context? {
        guard Core.active, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !AXHandler.shared.isMenuOpen, !TurnOverMenu.shared.isOpen, let focus = API.focusObject, focus.pid == pid else { return nil }
        let objects = [focus] + API.focusAncestors
        guard !objects.contains(where: { $0.axRole == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains($0.axSubrole ?? "") }),
              let window = objects.first(where: { $0.axRole == "AXWindow" })?.element else { return nil }
        return .init(window: window, focus: focus.element, ancestors: API.focusAncestors.map(\.element))
    }
    private var isAvailable: Bool { active && !terminated && dependencies.context() != nil }
    private func retire() { pending?.work.cancel(); pending = nil }
    private func finish(_ work: SettingsPartWork) { if pending?.work === work { retire() } }

    private func accepts(_ value: Pending, expected: AXUIElement? = nil) -> Bool {
        guard active, !terminated, pending?.work === value.work, value.work.current(), dependencies.keys() == value.keys,
              let now = dependencies.context(), CFEqual(now.window, value.context.window) else { return false }
        if CFEqual(now.focus, value.context.focus) { return true }
        guard let expected else { return false }
        return CFEqual(now.focus, expected) || now.ancestors.contains { CFEqual($0, expected) }
    }

    private func acceptsEffect(_ value: Pending, focus: AXUIElement, expected: AXUIElement? = nil) -> Bool {
        guard accepts(value, expected: expected) else { return false }
        let keys = dependencies.keys
        let current: @Sendable () -> Bool = { value.work.current() && keys() == value.keys }
        guard dependencies.freshlyEligible(value.request, focus, current) else { return false }
        return accepts(value, expected: expected)   // keys/focus may have changed during the bounded AX queries
    }

    private func move(to part: SystemSettingsPart) {
        guard isAvailable, let context = dependencies.context() else { return }
        retire()
        let value = Pending(work: SettingsPartWork(), request: .init(pid: pid, window: context.window, part: part),
                            context: context, keys: dependencies.keys())
        pending = value
        let resolver = dependencies.resolver, deliver = dependencies.deliver, keys = dependencies.keys
        dependencies.schedule { [weak self] in
            let current: @Sendable () -> Bool = { value.work.current() && keys() == value.keys }
            let result = current() ? resolver.resolve(value.request, current: current) : nil
            deliver { [weak self] in self?.resolved(result, for: value) }
        }
    }

    private func resolved(_ result: SystemSettingsPartResolution?, for value: Pending) {
        guard accepts(value) else { finish(value.work); return }
        guard let result else {
            guard acceptsEffect(value, focus: value.context.focus) else { finish(value.work); return }
            dependencies.speak("could not locate the \(value.request.part.name)"); finish(value.work); return
        }
        pending?.target = result.target
        if result.canFocus {
            guard acceptsEffect(value, focus: value.context.focus) else { finish(value.work); return }
            _ = dependencies.setFocus(result.target)
        }
        guard accepts(value, expected: result.target) else { finish(value.work); return }
        // A successful AXFocused write is only a request. Read the actual focus, and re-resolve the part, before
        // claiming keyboard movement. Revalidate even a review-only target after main delivery: a rebuilt or
        // background pane never falls back to an old cached control.
        let resolver = dependencies.resolver, deliver = dependencies.deliver, keys = dependencies.keys
        dependencies.schedule { [weak self] in
            let current: @Sendable () -> Bool = { value.work.current() && keys() == value.keys }
            let verification = current() ? resolver.verify(value.request, target: result.target, current: current) : nil
            deliver { [weak self] in
                guard let self, accepts(value, expected: result.target) else { self?.finish(value.work); return }
                guard let verification else {
                    guard acceptsEffect(value, focus: value.context.focus, expected: result.target) else { finish(value.work); return }
                    dependencies.speak("could not reach the \(value.request.part.name)"); finish(value.work); return
                }
                let focused = verification.focused
                guard let context = dependencies.context(),
                      CFEqual(context.focus, value.context.focus) || CFEqual(context.focus, focused) else { finish(value.work); return }
                if verification.inside {
                    guard acceptsEffect(value, focus: focused, expected: result.target) else { finish(value.work); return }
                    dependencies.review(focused)
                    dependencies.speak(value.request.part.name)
                    dependencies.reportFocus(focused)
                    finish(value.work)
                } else { fallback(result.target, for: value, focused: focused) }
            }
        }
    }

    private func fallback(_ target: AXUIElement, for value: Pending, focused: AXUIElement) {
        guard acceptsEffect(value, focus: focused, expected: target) else { finish(value.work); return }
        dependencies.review(target)
        dependencies.speak("\(value.request.part.name), review cursor. Keyboard focus is elsewhere")
        finish(value.work)
    }

    package override func objectClass(for element: AXUIElement, role: Role, subrole: String?) -> TurnOverObject.Type? {
        role == .button ? SystemSettingsLabelledButton.self : nil
    }
    package override func handleEvent(_ event: Event, next: () -> Void) {
        if let pending {
            if event.kind == .gainFocus {
                let expected = pending.target
                let own = expected.map { target in
                    CFEqual(event.obj.element, target) || dependencies.context()?.ancestors.contains { CFEqual($0, target) } == true
                } ?? false
                if !own, !CFEqual(event.obj.element, pending.context.focus) { retire() }
            } else if [.foreground, .selection, .valueChange].contains(event.kind) { retire() }
        }
        super.handleEvent(event, next: next)
    }
    package override func event_appModuleGainFocus() { guard !terminated else { return }; retire(); active = true }
    package override func event_appModuleLoseFocus() { retire(); active = false; super.event_appModuleLoseFocus() }
    package override func terminate() { retire(); terminated = true; active = false; super.terminate() }
}
