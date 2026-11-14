// SPDX-License-Identifier: GPL-3.0-or-later

/// 14 Nov 2026: a key or focus event says its own words first. Mode words follow, after focus speech has
/// dropped the previous focus. A mode left and resumed within that operation is not a change to the listener.
enum ModeAnnouncement {
    private struct Change {
        let document: BrowseModeDocument
        let before: Bool
        var announce: Bool
        var playSound: Bool
    }
    private static var depth = 0
    private static var changes: [Change] = []
    static var isCollecting: Bool { depth > 0 }

    static func begin() { depth += 1 }

    static func changed(_ document: BrowseModeDocument, from before: Bool, announce: Bool, playSound: Bool) {
        guard isCollecting else { return }
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
            // A queued focus event may have left this page before the key finished (14 Nov 2026).
            guard API.focusTreeInterceptor === change.document else { continue }
            guard change.announce else { continue }
            guard change.before != change.document.passThrough else { continue }
            change.document.announceMode(playSound: change.playSound)
        }
    }

    private static var nextTicket: UInt64 = 0
    private static var tickets: [ObjectIdentifier: UInt64] = [:]

    static func sayWords(_ words: String, document: BrowseModeDocument) {
        nextTicket &+= 1
        let ticket = nextTicket
        tickets[ObjectIdentifier(document)] = ticket
        queueWords(words, document: document, mode: document.passThrough, ticket: ticket)
    }

    private static func queueWords(_ words: String, document: BrowseModeDocument, mode: Bool, ticket: UInt64) {
        let key = ObjectIdentifier(document)
        let focusGeneration = Speech.focusCancellationGeneration
        let explicitGeneration = Speech.explicitCancellationGeneration
        // 14 Nov 2026: the native focus after Enter can arrive after its key has finished. If its words
        // cancel this mode's queued words, append them again after that focus, without replaying the sound.
        Speech.speakMessage(words, completion: { [weak document] completed in
            onMain {
                guard tickets[key] == ticket else { return }
                guard !completed,
                      Speech.explicitCancellationGeneration == explicitGeneration,
                      Speech.focusCancellationGeneration != focusGeneration,
                      let document,
                      API.focusTreeInterceptor === document,
                      document.passThrough == mode else {
                    tickets.removeValue(forKey: key)
                    return
                }
                queueWords(words, document: document, mode: mode, ticket: ticket)
            }
        })
    }

}
