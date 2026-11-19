// SPDX-License-Identifier: GPL-3.0-or-later
// The fix pass after the independent review of plugin scripts (16 Nov 2026): the parts that need no host program and no
// recorded screen. (The rest of that pass's tests are beside the code they test: ScriptHostTests, ScriptPluginsTests,
// ScriptKeeperTests and ScriptTrustTests.) Nothing here uses XPC, the Keychain, the real support folder or the home folder.
import Foundation
import TurnOverCore
import TurnOverPluginWire

func scriptReviewTests() {
    test("script review: what is known of a process id is kept with the process's start, so a reused id is not believed") {
        let store = ProfileStore()
        var starts: [pid_t: UInt64] = [5000: 1]
        var names: [pid_t: String] = [5000: "com.a"]
        var lookups = 0
        store.processStart = { starts[$0] }
        store.lookupBundle = { lookups += 1; return names[$0] ?? "" }
        expect(store.bundle(of: 5000), "com.a", "the app that has the id")
        names[5000] = "com.b"
        expect(store.bundle(of: 5000), "com.a", "the same process is not asked again")
        expect(lookups, 1, "just the once")
        starts[5000] = 2   // the first program quit and another has the id
        expect(store.bundle(of: 5000), "com.b", "a process that started later is another program")
        starts[5000] = nil   // not a process any more
        names[5000] = ""
        expect(store.bundle(of: 5000), "", "and one that is gone is nobody's")
        // The real thing: this program's own id has a start, and a bundle answer the second time too.
        let live = ProfileStore()
        let me = getpid()
        check(live.processStart(me) != nil, "this process has a start time")
        expect(live.bundle(of: me), live.bundle(of: me), "and is answered the same twice")
    }

    test("script review: a line is never held past the limit, and a long one is dropped whole whichever way the reads fall") {
        var framer = LineFramer(maxBytes: 10)
        expect(framer.add(Data("0123456789".utf8)), [], "exactly the limit, no newline yet: held")
        expect(framer.add(Data("A".utf8)), [.tooLong], "one more is dropped as soon as it is known")
        expect(framer.add(Data("BCD\nnext\n".utf8)), [.line(Data("next".utf8))], "the rest of it is thrown away to its newline")
        expect(framer.add(Data("01234".utf8)), [], "a part")
        expect(framer.add(Data("56789\n".utf8)), [.line(Data("0123456789".utf8))], "that finishes exactly at the limit")
        expect(framer.add(Data("01234".utf8)), [], "a part")
        expect(framer.add(Data("567890\nok\n".utf8)), [.tooLong, .line(Data("ok".utf8))], "that would pass it by one, in a read that also ends the line")
        expect(framer.add(Data("0123456789ABCDEF\n".utf8)), [.tooLong], "a single read past the limit that holds its newline")
    }

    test("script review: the limits the fixes added are the ones the reasons say") {
        let limits = ScriptLimits()
        check(limits.messagesPerSecond > limits.requestsPerSecond, "lines are allowed for more than the requests, for the answers to events")
        check(limits.floodDropsAllowed > limits.messagesPerSecond, "a flood is more than a burst")
        expect(limits.mainQueueLimit, 64, "requests waiting for main")
        expect(ScriptLimits.globPatternCharacters * ScriptLimits.globTextCharacters <= 2_000_000, true, "a comparison is at most two million steps")
        check(ElementMatcher.validNth(1) && ElementMatcher.validNth(-1) && !ElementMatcher.validNth(0) && !ElementMatcher.validNth(Int.min) && !ElementMatcher.validNth(Int.max), "nth is a place: not zero, not out of reach")
    }
}
