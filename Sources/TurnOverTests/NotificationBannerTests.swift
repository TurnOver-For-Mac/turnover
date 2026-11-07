// SPDX-License-Identifier: GPL-3.0-or-later
import AXFixtures
import TurnOverAX
import TurnOverCore

func notificationBannerTests() {
    test("Notification Centre: finds live banners and existing alerts in their window") {
        let fixture = AXFixture(app: "Notification Centre", bundle: "com.apple.notificationcenterui",
                                recorded: "synthetic", root: 1, application: 0, focus: nil, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXApplication"), "AXWindows": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXWindow"), "AXChildren": .elements([2, 3, 4])]),
            .init(id: 2, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXNotificationCenterAlert"),
                                "AXIdentifier": .string("public-alert")]),
            .init(id: 3, attrs: ["AXRole": .string("AXScrollArea"), "AXChildren": .elements([5])]),
            .init(id: 4, attrs: ["AXRole": .string("AXGroup"), "AXIdentifier": .string("unrelated-group")]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXNotificationCenterBanner"),
                                "AXIdentifier": .string("public-banner")]),
        ])
        AXReplay.load(fixture)
        defer { AXReplay.unload() }

        let elements = AXHandler.notificationElements(in: [AXReplay.element(1)])
        expect(elements.compactMap { $0.string("AXIdentifier") }, ["public-banner", "public-alert"])
    }
}
