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
}
