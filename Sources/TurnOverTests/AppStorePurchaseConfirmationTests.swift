// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Darwin
import TurnOverCore
import AXFixtures

func appStorePurchaseConfirmationTests() {
    let sessionPage = UUID()
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    func context(page: UUID? = nil, item: String = "public-sample-product-id", title: String = "£4.99",
                 button: Int = 99_701) -> AppStorePurchaseConfirmation.Context {
        .init(page: page ?? sessionPage, itemIdentity: item, offerTitle: title, button: AXReplay.element(button))
    }
    func gesture(_ tick: UInt64, repeated: Bool = false) -> KeyboardGesture {
        .init(keyCode: 49, modifiers: [], characters: " ", timestamp: tick, isRepeat: repeated, flags: [])
    }
    func press(_ tick: UInt64) -> AppStoreActionPress { AppStoreActionPress.receive(gesture(tick))! }

    test("App Store purchase: a second physical post-prompt press confirms once") {
        var confirmation = AppStorePurchaseConfirmation()
        expect(confirmation.decide(context(), press: press(10), at: start, armTick: 20), .prompt)
        expect(confirmation.decide(context(), press: press(30), at: start.addingTimeInterval(1), armTick: 40), .confirm)
        expect(confirmation.decide(context(), press: press(50), at: start.addingTimeInterval(2), armTick: 60), .prompt, "confirmed token is consumed")
    }
    test("App Store purchase: a reused button cannot confirm another product or changed terms") {
        for changed in [context(item: "another-public-product-id"), context(title: "£14.99"), context(title: "£4.99 per month")] {
            var confirmation = AppStorePurchaseConfirmation()
            _ = confirmation.decide(context(), press: press(10), at: start, armTick: 20)
            expect(confirmation.decide(changed, press: press(30), at: start.addingTimeInterval(1), armTick: 40), .prompt)
            expect(confirmation.decide(changed, press: press(50), at: start.addingTimeInterval(2), armTick: 60), .confirm)
        }
    }
    test("App Store purchase: a page session change invalidates a confirmation") {
        var confirmation = AppStorePurchaseConfirmation()
        _ = confirmation.decide(context(), press: press(10), at: start, armTick: 20)
        expect(confirmation.decide(context(page: UUID()), press: press(30), at: start.addingTimeInterval(1), armTick: 40), .prompt)
        expect(confirmation.decide(context(), press: press(50), at: start.addingTimeInterval(2), armTick: 60), .prompt)
    }
    test("App Store purchase: button equality uses CF identity and rejects another button") {
        var same = AppStorePurchaseConfirmation()
        _ = same.decide(context(), press: press(10), at: start, armTick: 20)
        expect(same.decide(context(), press: press(30), at: start.addingTimeInterval(1), armTick: 40), .confirm)
        var changed = AppStorePurchaseConfirmation()
        _ = changed.decide(context(), press: press(10), at: start, armTick: 20)
        expect(changed.decide(context(button: 99_702), press: press(30), at: start.addingTimeInterval(1), armTick: 40), .prompt)
    }
    test("App Store purchase: physical five-second expiry and wall-clock rollback require a new prompt") {
        for elapsed in [5.0, 6.0, -1.0] {
            var confirmation = AppStorePurchaseConfirmation()
            _ = confirmation.decide(context(), press: press(10), at: start, armTick: 20)
            expect(confirmation.decide(context(), press: press(30), at: start.addingTimeInterval(elapsed), armTick: 40), .prompt)
        }
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let sixSeconds = UInt64(ceil(6_000_000_000 * Double(timebase.denom) / Double(timebase.numer)))
        var physical = AppStorePurchaseConfirmation()
        _ = physical.decide(context(), press: press(10), at: start, armTick: 20)
        expect(physical.decide(context(), press: press(20 + sixSeconds), at: start.addingTimeInterval(1), armTick: 21 + sixSeconds), .prompt,
               "physical expiry remains enforced even if wall time reports only one second")
    }
    test("App Store purchase: missing identity terms or a nonfinite clock clears pending intent") {
        for invalid in [context(item: ""), context(item: " \n"), context(title: ""), context(title: " \t")] {
            var confirmation = AppStorePurchaseConfirmation()
            _ = confirmation.decide(context(), press: press(10), at: start, armTick: 20)
            expect(confirmation.decide(invalid, press: press(30), at: start.addingTimeInterval(1), armTick: 40), .ignore)
            expect(confirmation.decide(context(), press: press(50), at: start.addingTimeInterval(2), armTick: 60), .prompt)
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            var confirmation = AppStorePurchaseConfirmation()
            _ = confirmation.decide(context(), press: press(10), at: start, armTick: 20)
            expect(confirmation.decide(context(), press: press(30), at: Date(timeIntervalSinceReferenceDate: invalid), armTick: 40), .ignore)
            expect(confirmation.decide(context(), press: press(50), at: start.addingTimeInterval(1), armTick: 60), .prompt)
        }
    }
    test("App Store purchase: reset invalidates selection and nonpurchase transitions") {
        var confirmation = AppStorePurchaseConfirmation()
        _ = confirmation.decide(context(), press: press(10), at: start, armTick: 20)
        confirmation.reset()
        expect(confirmation.decide(context(), press: press(30), at: start.addingTimeInterval(1), armTick: 40), .prompt)
    }
    test("App Store purchase: queued pre-prompt input is ignored without rearming") {
        var confirmation = AppStorePurchaseConfirmation()
        _ = confirmation.decide(context(), press: press(10), at: start, armTick: 100)
        for origin in [UInt64(0), 10, 99, 100] {
            expect(confirmation.decide(context(), press: press(origin), at: start.addingTimeInterval(1), armTick: 200), .ignore,
                   "execution after the prompt cannot turn older physical input into confirmation")
        }
        expect(confirmation.decide(context(), press: press(101), at: start.addingTimeInterval(2), armTick: 201), .confirm,
               "ignored queued keys did not move the original cutoff to 200")
    }
    test("App Store purchase: synthetic future and repeated input cannot confirm") {
        var confirmation = AppStorePurchaseConfirmation()
        expect(confirmation.decide(context(), press: .synthetic, at: start, armTick: 100), .prompt)
        expect(confirmation.decide(context(), press: .synthetic, at: start.addingTimeInterval(1), armTick: 200), .ignore)
        expect(confirmation.decide(context(), press: press(300), at: start.addingTimeInterval(1), armTick: 200), .ignore,
               "future timestamps cannot confirm or replace pending state")
        expect(confirmation.decide(context(), press: press(101), at: start.addingTimeInterval(2), armTick: 201), .confirm)
        var dispatches = 0
        AppStoreActionPress.dispatch(gesture(400, repeated: true)) { _ in dispatches += 1 }
        check(AppStoreActionPress.receive(gesture(400, repeated: true)) == nil, "repeat is rejected at the real module boundary")
        AppStoreActionPress.dispatch(gesture(401)) { accepted in dispatches += 1; expect(accepted.originTick, 401) }
        expect(dispatches, 1, "a held key never dispatches a paid-capable action")
    }
}
