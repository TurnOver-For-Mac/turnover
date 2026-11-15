// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import AXFixtures

func mailMessageReadingTests() {
    func load(_ nodes: [AXFixture.Node]) {
        AXReplay.load(.init(app: "Mail public sample", bundle: "test.mail.message", recorded: "", root: 0, application: nil, focus: nil, nodes: nodes))
    }
    test("Mail message lookup: an editable sibling does not hide a read-only message") {
        load([
            .init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([1, 2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea")]),
            .init(id: 2, attrs: ["AXRole": .string("AXWebArea")]),
        ])
        defer { AXReplay.unload() }
        let message = MailAppModule.messageIn(AXReplay.root!, isEditable: { AXReplay.id(of: $0) == 1 })
        expect(AXReplay.id(of: message), 2)
        check(AXReplay.actions.isEmpty && AXReplay.sets.isEmpty, "lookup does not focus or change Mail")
    }
    test("Mail message lookup: compose descendants are excluded while the next message level is searched") {
        load([
            .init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([1, 2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([3])]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXChildren": .elements([4])]),
            .init(id: 3, attrs: ["AXRole": .string("AXWebArea")]),
            .init(id: 4, attrs: ["AXRole": .string("AXWebArea")]),
        ])
        defer { AXReplay.unload() }
        var editabilityAsked: [Int] = []
        let message = MailAppModule.messageIn(AXReplay.root!, isEditable: {
            let id = AXReplay.id(of: $0)!; editabilityAsked.append(id); return id == 1
        })
        expect(AXReplay.id(of: message), 4)
        check(!editabilityAsked.contains(3), "a nested web area in the compose body is never considered received mail")
    }
    test("Mail message lookup: compose-only and message-list descendants remain excluded") {
        load([
            .init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([1, 2, 3, 4])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWebArea"), "AXChildren": .elements([5])]),
            .init(id: 2, attrs: ["AXRole": .string("AXTable"), "AXChildren": .elements([5])]),
            .init(id: 3, attrs: ["AXRole": .string("AXOutline"), "AXChildren": .elements([5])]),
            .init(id: 4, attrs: ["AXRole": .string("AXScrollBar"), "AXChildren": .elements([5])]),
            .init(id: 5, attrs: ["AXRole": .string("AXWebArea")]),
        ])
        defer { AXReplay.unload() }
        check(MailAppModule.messageIn(AXReplay.root!, isEditable: { AXReplay.id(of: $0) == 1 }) == nil,
              "no read-only message is exposed outside excluded containers")
    }
    test("Mail message lookup: an oversized first level is refused before inspecting message candidates") {
        var nodes: [AXFixture.Node] = [.init(id: 0, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements(Array(1...201))])]
        for id in 1...201 { nodes.append(.init(id: id, attrs: ["AXRole": .string("AXWebArea")])) }
        load(nodes); defer { AXReplay.unload() }
        var inspected = 0
        check(MailAppModule.messageIn(AXReplay.root!, isEditable: { _ in inspected += 1; return false }) == nil, "level cap includes the initial children")
        expect(inspected, 0)
    }

    test("Mail read ahead: Mail confirming the row is not read twice; another row is read as the correction") {
        let a = AXReplay.element(1), b = AXReplay.element(2), c = AXReplay.element(3)
        var ahead = MailReadAhead()
        check(ahead.admits(a, now: 0), "with nothing read ahead, every selection is read")
        ahead.readingAhead(b, now: 10)
        check(ahead.admits(b, now: 10.001), "TurnOver's own reading of the row passes")
        check(!ahead.admits(b, now: 10.045), "Mail's news of the same row is not read again")
        check(!ahead.admits(b, now: 10.2), "nor a repeat of it")
        ahead.readingAhead(c, now: 20)
        check(ahead.admits(c, now: 20.001), "own reading")
        check(ahead.admits(a, now: 20.05), "Mail landing somewhere else is read")
        check(ahead.row == nil, "and ends the expectation")
        ahead.readingAhead(b, now: 30)
        _ = ahead.admits(b, now: 30.001)
        check(ahead.admits(b, now: 34), "news that comes far too late is read as news")
    }

    test("Mail read ahead: a quick second arrow steps from the row just read, not from where Mail still is") {
        let a = AXReplay.element(1), b = AXReplay.element(2)
        var ahead = MailReadAhead()
        check(ahead.base(selected: a, now: 0).map { CFEqual($0, a) } == true, "first press: from the selection")
        ahead.readingAhead(b, now: 1)
        check(ahead.base(selected: a, now: 1.03).map { CFEqual($0, b) } == true, "30 ms on, Mail still on the old row: from the row read ahead")
        check(ahead.base(selected: b, now: 1.03).map { CFEqual($0, b) } == true, "Mail caught up: the same row either way")
        check(ahead.base(selected: a, now: 2).map { CFEqual($0, a) } == true, "a second later and Mail never moved: from where Mail is")
        let s1 = ahead.serial; ahead.readingAhead(a, now: 3)
        expect(ahead.serial, s1 + 1, "each row read ahead is counted")
    }
}
