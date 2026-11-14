// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverAX

/// 14 Nov 2026: an operation can request native focus and return before its label arrives. Keep the
/// mode as an obligation until that item is reported (350 ms ceiling), and until its words complete.
/// An ordinary speech cancellation transfers the obligation; Control explicitly retires it.
package enum ModeAnnouncement {
    private struct Change {
        let document: BrowseModeDocument
        let before: Bool
        var announce: Bool
        var playSound: Bool
    }
    private final class Pending {
        weak var document: BrowseModeDocument?
        let page: Int
        let mode: Bool
        let expires: Date
        var field: AXUIElement?
        var virtual = false
        var position: Int?
        var ready = false
        var queued = false
        var retryAfter = Date.distantPast
        var revision = 0
        var sound: Bool

        init(_ document: BrowseModeDocument, sound: Bool) {
            self.document = document
            page = document.pageGeneration
            mode = document.passThrough
            expires = now().addingTimeInterval(8)
            field = API.focusObject?.element
            self.sound = sound
        }
    }
    private static var depth = 0
    private static var changes: [Change] = []
    private static var reported: (BrowseModeDocument, AXUIElement, Bool)?
    private static var pending: Pending?
    // A deferred quick-navigation result owns its mode until it reports the actual item.
    private static var navigation: (document: BrowseModeDocument, page: Int, intent: Int, ticket: Int)?
    private static var nextNavigationTicket = 0
    package static var now: () -> Date = { Date() }
    package static var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }

    static func begin() { depth += 1 }

    static func changed(_ document: BrowseModeDocument, from before: Bool, announce: Bool, playSound: Bool) {
        if let index = changes.firstIndex(where: { $0.document === document }) {
            changes[index].announce = changes[index].announce || announce
            changes[index].playSound = playSound
        } else {
            changes.append(Change(document: document, before: before, announce: announce, playSound: playSound))
        }
    }

    static func end() {
        depth -= 1
        guard depth == 0 else { return }
        let completed = changes
        changes = []
        for change in completed {
            guard API.focusTreeInterceptor === change.document else { continue }
            guard change.announce else { continue }
            guard change.before != change.document.passThrough else { continue }
            pending = Pending(change.document, sound: change.playSound)
            waitForItem()
        }
        if let (document, field, virtual) = reported {
            reported = nil
            attach(document, field: field, virtual: virtual)
        }
    }

    /// Called after the real focus chain has enqueued the item's words, including unchanged focus mode.
    static func focusReported(_ document: BrowseModeDocument, field: AXUIElement) {
        reported = (document, field, false)
        if depth == 0 {
            reported = nil
            attach(document, field: field, virtual: false)
        }
    }

    @discardableResult
    static func navigationStarted(_ document: BrowseModeDocument) -> Int {
        nextNavigationTicket += 1
        navigation = (document, document.pageGeneration, document.bufferIntent, nextNavigationTicket)
        return nextNavigationTicket
    }

    static func navigationFinished(_ document: BrowseModeDocument, ticket: Int) {
        guard navigation?.document === document else { return }
        guard navigation?.ticket == ticket else { return }
        navigation = nil
        waitForItem()
    }

    /// Arrows carry an existing mode obligation onto their spoken line, without creating a new one.
    static func readingReported(_ document: BrowseModeDocument) {
        guard API.focusTreeInterceptor === document else { return }
        guard !document.passThrough, let field = document.elementAtPosition() else { return }
        if navigation?.document === document { navigation = nil }
        reported = (document, field, true)
        if depth == 0 {
            reported = nil
            attach(document, field: field, virtual: true)
        }
    }

    /// The quick-navigation path uses this same owner, never an independent suffix.
    static func navigationReported(_ document: BrowseModeDocument, object: TurnOverObject) {
        guard !document.passThrough else { return }
        if pending?.document !== document || pending?.mode != false {
            if object.states.contains(.editable) { pending = Pending(document, sound: false) }
        }
        document.lastQuickNavTarget = object.element
        reported = (document, object.element, true)
        if depth == 0 {
            reported = nil
            attach(document, field: object.element, virtual: true)
        }
        navigation = nil
    }

    private static func attach(_ document: BrowseModeDocument, field: AXUIElement, virtual: Bool) {
        guard let item = pending else { return }
        guard item.document === document else { return }
        guard valid(item) else { retire(item); return }
        // A heading/link can own the quick-navigation result while its text child owns the
        // buffer offset. Bind the retry to what actually occupies that reading position.
        item.field = virtual ? document.elementAtPosition() : field
        item.virtual = virtual
        item.position = virtual ? document.position : nil
        item.ready = true
        deliver(item)
    }

    /// A cancellation callback can arrive after a newer focus. Retire its revision immediately, before
    /// that focus is reported, so it cannot requeue the old field's words over the new one.
    static func cancelled(explicit: Bool) {
        // Each ordinary key supersedes any deferred navigation, even when its discarded
        // callback never runs. A newer deferred command acquires its own ticket.
        navigation = nil
        if explicit {
            pending = nil
            changes = []
            reported = nil
            return
        }
        guard let item = pending else { return }
        item.revision += 1
        item.queued = false
        item.ready = false
        waitForItem()
    }

    private static func waitForItem() {
        guard let item = pending else { return }
        let revision = item.revision
        schedule(0.35) { [weak item] in
            guard let item else { return }
            guard pending === item else { return }
            guard item.revision == revision else { return }
            if let navigation,
               navigation.document === item.document,
               navigation.page == item.page,
               navigation.intent == item.document?.bufferIntent { return }
            item.ready = true
            deliver(item)
        }
        schedule(8) { [weak item] in
            guard let item else { return }
            if pending === item, now() >= item.expires {
                retire(item)
            }
        }
    }

    private static func retire(_ item: Pending) {
        guard pending === item else { return }
        pending = nil
        if navigation?.document === item.document { navigation = nil }
    }

    private static func valid(_ item: Pending) -> Bool {
        guard let document = item.document else { return false }
        guard API.focusTreeInterceptor === document else { return false }
        guard document.pageGeneration == item.page else { return false }
        guard document.passThrough == item.mode else { return false }
        guard now() < item.expires else { return false }
        return true
    }

    static func outputFinished() {
        if let item = pending { deliver(item) }
    }

    private static func deliver(_ item: Pending) {
        guard pending === item else { return }
        guard valid(item) else { retire(item); return }
        guard item.ready else { return }
        guard !item.queued else { return }
        guard now() >= item.retryAfter else { return }
        // Keep mode words on main until preceding item speech finishes. They cannot sit in the player's
        // audio queue behind a long field and begin on a later page (14 Nov 2026).
        guard !Speech.hasPendingOutput else { return }
        guard let field = item.field else { return }
        if item.virtual, item.document?.position != item.position { return }
        let current = item.virtual ? item.document?.elementAtPosition() : API.focusObject?.element
        guard current?.isSame(field) == true else { return }
        item.queued = true
        item.revision += 1
        let revision = item.revision
        if item.sound, config.general.navigationSounds { BrowseModeDocument.modeSound(item.mode) }
        item.sound = false
        let words = item.mode ? String(localized: "focus mode", comment: "Spoken message") : String(localized: "browse mode", comment: "Spoken message")
        Speech.speakMessage(words, completion: { [weak item] completed in
            onMain {
                guard let item else { return }
                guard pending === item else { return }
                guard item.revision == revision else { return }
                guard valid(item) else { retire(item); return }
                if completed {
                    pending = nil
                } else {
                    item.queued = false
                    item.retryAfter = now().addingTimeInterval(0.05)
                    // Output can be temporarily gated. Retry only this field and page, within the original expiry.
                    schedule(0.05) { [weak item] in
                        if let item { deliver(item) }
                    }
                }
            }
        })
    }

    package static func reset() {
        pending = nil
        navigation = nil
        changes = []
        reported = nil
        depth = 0
    }
}
