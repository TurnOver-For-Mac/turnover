// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore

/// An app switch hands over only once nothing is moving, and then for the app in front (18 Nov 2026, with Codex's
/// review). HandOverSettler is driven with a given clock and scheduler, and a world of Command, the hand-over and
/// VoiceOver written by hand from the log of 18 Nov 2026, 07:32; nothing touches VoiceOver or the keyboard. Its
/// wiring into the lead watcher (activations, hand-over answers) is not driven here. Logic evidence only.
func handOverSettleTests() {
    final class World {
        var t: TimeInterval = 0
        var command = false
        var underWay = false
        var voiceOverSettled = true
        var lastHandOverAt: TimeInterval = -100
        var timers: [(at: TimeInterval, body: () -> Void)] = []
        var decisions: [(at: TimeInterval, unsettled: Bool)] = []
        lazy var settler = HandOverSettler(
            standing: { [unowned self] in
                .init(commandHeld: command, handOverUnderWay: underWay, voiceOverSettled: voiceOverSettled,
                      sinceLastHandOver: t - lastHandOverAt)
            },
            now: { [unowned self] in t },
            schedule: { [unowned self] delay, body in timers.append((t + delay, body)) },
            decide: { [unowned self] unsettled in decisions.append((t, unsettled)) }, log: { _ in })
        /// Runs the timers due up to `until`, in order.
        func run(to until: TimeInterval) {
            while let i = timers.indices.min(by: { timers[$0].at < timers[$1].at }), timers[i].at <= until {
                let next = timers.remove(at: i)
                t = next.at
                next.body()
            }
            t = until
        }
    }
    typealias S = HandOverSettle.Standing

    test("hand-over settle: a single switch with nothing moving decides at once, as before") {
        expect(HandOverSettle.decide(S(commandHeld: false, handOverUnderWay: false, voiceOverSettled: true, sinceLastHandOver: 30), waited: 0), .decideNow)
    }
    test("hand-over settle: 07:32, Safari after Claude waits for VoiceOver's process to go, then decides once") {
        let w = World()
        w.t = 17.88; w.lastHandOverAt = 16.49; w.voiceOverSettled = false   // Claude's hand-over; VoiceOver stopping
        w.settler.request("Safari activated")
        w.run(to: 18.7)
        w.settler.request("Claude activated")   // more switches meanwhile: still one check
        w.settler.request("Safari activated")
        w.run(to: 19.98); w.voiceOverSettled = true
        w.run(to: 25)
        expect(w.decisions.count, 1, "one decision for the whole burst")
        check((w.decisions.first?.at ?? 0) >= 19.98 && (w.decisions.first?.at ?? 99) < 20.2, "decided as VoiceOver settled")
        check(w.decisions.first?.unsettled == false, "settled")
    }
    test("hand-over settle: Command held for 30 s, then Escape and release with no activation: still decided") {
        let w = World()
        w.command = true
        w.settler.request("Mail activated while Command is held")
        w.run(to: 30)
        expect(w.decisions.count, 0, "nothing while Command is held, however long")
        check(w.settler.waiting, "the check is not dropped")
        w.command = false
        w.run(to: 31)
        expect(w.decisions.count, 1, "decided on Command's release alone")
    }
    test("hand-over settle: an earlier hand-over's 12 s fallback start keeps the check waiting until its answer") {
        let w = World()
        w.underWay = true; w.voiceOverSettled = false; w.lastHandOverAt = 0   // VoiceOver.app opened for Safari
        w.settler.request("Claude activated while a hand-over is under way")
        w.run(to: 11.9)
        expect(w.decisions.count, 0, "not past the 6 s limit while the start is alive")
        w.underWay = false; w.voiceOverSettled = true   // VoiceOver arrived at 12 s: the hand-over's answer
        w.run(to: 13)
        expect(w.decisions.count, 1, "then the app in front (Claude) decides")
        check(w.decisions.first?.unsettled == false, "settled")
    }
    test("hand-over settle: VoiceOver's flag on with no VoiceOver is decided anyway after the limit") {
        let w = World()
        w.voiceOverSettled = false
        w.settler.request("Safari activated while VoiceOver is still starting or stopping")
        w.run(to: HandOverSettle.limit + 1)
        expect(w.decisions.count, 1)
        check(w.decisions.first?.unsettled == true, "marked unsettled, so the gate lets it through")
    }
    test("hand-over settle: a request after the check has decided starts a new one") {
        let w = World()
        w.settler.request("first")
        w.run(to: 1)
        w.settler.request("the hand-over finished")
        w.run(to: 2)
        expect(w.decisions.count, 2)
    }
    // Codex's second review (18 Nov 2026): a hand-over's answer asked for a check after it; stopped from outside
    // (SIGTERM) meanwhile, that check could turn VoiceOver off while the quit brought it back.
    test("hand-over settle: quitting drops the check a finished hand-over asked for, and any asked after") {
        let w = World()
        let shutdown = ReaderShutdown()
        w.lastHandOverAt = 0
        w.settler.request("the hand-over for Mail finished")   // waits out the 1.5 s spacing
        w.run(to: 0.5)
        shutdown.begin()   // SIGTERM: begun off main
        w.settler.stop()   // then the app's shutDown on main
        w.run(to: 5)
        expect(w.decisions.count, 0, "no reader decided while the quit brings VoiceOver back")
        check(!w.settler.waiting, "nothing waiting")
        w.settler.request("Safari activated")   // an activation during the quit
        w.run(to: 10)
        expect(w.decisions.count, 0, "nothing after the quit began")
        expect(w.timers.count, 0, "nothing even scheduled")
        check(!shutdown.allowsHandOver, "and no hand-over, either way, may post or go on waiting")
    }
    test("hand-over settle: before a quit, hand-overs are allowed") {
        check(ReaderShutdown().allowsHandOver, "a fresh TurnOver hands over as before")
    }
}
