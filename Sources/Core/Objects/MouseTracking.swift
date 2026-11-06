// SPDX-License-Identifier: GPL-3.0-or-later
// Mouse tracking: what is under the mouse pointer is read as the pointer moves, and the cursor goes there (VoiceOver's
// cursor following the mouse pointer; NVDA+M). Off until the Mouse tracking setting is on, and only while TurnOver is
// the reader that speaks: where VoiceOver leads, its own pointer reading is the one heard.
//
// The pointer is watched with a listen-only monitor of mouse-moved events: nothing is held back or changed, and the
// keyboard is never involved. A move asks for a look at most every tenth of a second, so a long sweep across a window
// says each item it crosses and the pointer coming to rest says where it ended. The look itself (the accessibility
// call for the element at a point) runs off the main thread, because an app that has stopped answering holds a call
// for as long as the messaging timeout (AGENTS.md).
import Foundation
import AppKit
import ApplicationServices

/// The choices of what to say, apart from every accessibility call so a test can drive them with plain values.
public struct PointerTracker<Hit: Equatable> {
    /// A pointer that has not travelled this far (in points) from where it was last looked at is resting, not moving:
    /// a trackpad brushed while typing or the tremor of a hand on a mouse says nothing.
    public static var minimumTravel: CGFloat { 6 }
    private var lookedAt: CGPoint?
    private var spoken: Hit?

    public init() {}

    /// Whether the pointer at `p` is worth a look.
    public func worthLooking(at p: CGPoint) -> Bool {
        guard let from = lookedAt else { return true }
        return hypot(p.x - from.x, p.y - from.y) >= Self.minimumTravel
    }

    public mutating func looked(at p: CGPoint) { lookedAt = p }

    /// What a look found: whether to say it. The same item again is silent; a blank place is forgotten without a
    /// word, so coming back to the item says it again (as VoiceOver does).
    public mutating func answer(_ hit: Hit?) -> Bool {
        guard let hit else { spoken = nil; return false }
        guard hit != spoken else { return false }
        spoken = hit
        return true
    }

    public mutating func reset() { lookedAt = nil; spoken = nil }
}

public enum MouseTracking {
    /// The longest between one look and the next while the pointer moves.
    nonisolated static var interval: TimeInterval { 0.1 }

    private struct Element: Equatable {
        let element: AXUIElement
        static func == (a: Element, b: Element) -> Bool { CFEqual(a.element, b.element) }
    }

    /// An element found on the lookup queue and handed to the main thread once. It is made inside the queue's block and
    /// read only after the hop to main, where the queue no longer touches it: one owner at a time.
    private struct Found: @unchecked Sendable { let element: AXUIElement? }

    private static var monitor: Any?
    private static var tracker = PointerTracker<Element>()
    private static var lookScheduled = false
    private static var lookInFlight = false
    private static var generation = 0
    private static let queue = DispatchQueue(label: "turnover.mouse-tracking", qos: .userInteractive)

    public static var isOn: Bool { config.presentation.mouseTracking }

    /// Watches the pointer while the setting is on and TurnOver is reading, and stops the moment either is not so.
    public static func refresh() {
        let want = isOn && Core.active
        if want, monitor == nil { start() } else if !want, monitor != nil { stop() }
    }

    /// NVDA+M, and the menu: on or off, said.
    public static func toggle() {
        config.presentation.mouseTracking.toggle(); config.save()
        refresh()
        Speech.speakMessage(String(localized: "mouse tracking \(Phrases.onOff(isOn))", comment: "Mouse tracking turned on or off"))
    }

    private static func start() {
        tracker.reset()
        // Global: the pointer over other apps' windows. TurnOver's own are only menus and prompts, said as they open.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { event in
            // TurnOver's own synthetic moves (a click it makes for the person) are not the person's hand.
            if event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
            onMain { moved() }
        }
        Log.info("mouse tracking: on")
    }

    private static func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        generation += 1   // a look still out is dropped when it comes back
        lookInFlight = false; lookScheduled = false
        tracker.reset()
        Log.info("mouse tracking: off")
    }

    private static func moved() {
        guard !lookScheduled else { return }   // the look already asked for reads the pointer where it is by then
        lookScheduled = true
        onMain(after: interval) { look() }
    }

    private static func look() {
        lookScheduled = false
        // The trackpad's explore is reading under the fingers; Say All is reading on, and the pointer is not what
        // the person is asking to be moved to.
        guard isOn, Core.active, !lookInFlight, !Trackpad.controlOn, !SayAll.isRunning else { return }
        let p = VoiceOverKeysPlugin.mouseLocation()
        guard tracker.worthLooking(at: p) else { return }
        tracker.looked(at: p)
        lookInFlight = true
        let g = generation
        queue.async {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit) != .success { hit = nil }
            let found = Found(element: hit)
            onMain { found.element.map { arrived(Element(element: $0), generation: g) } ?? arrived(nil, generation: g) }
        }
    }

    private static func arrived(_ hit: Element?, generation g: Int) {
        guard g == generation else { return }
        lookInFlight = false
        // The pointer may have gone on (or come to rest somewhere else) while the look was out: the moves in that time
        // were not asked for, so its resting place is looked at now.
        defer { if isOn, Core.active, tracker.worthLooking(at: VoiceOverKeysPlugin.mouseLocation()) { moved() } }
        guard isOn, Core.active, tracker.answer(hit), let e = hit?.element else { return }
        // As the trackpad's explore does: what was being said gives way, the cursor goes to the item and it is read.
        Speech.cancel()
        ObjectNavigator.shared.moveTo(e)
    }
}
