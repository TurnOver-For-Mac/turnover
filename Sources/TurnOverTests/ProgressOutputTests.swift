// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import TurnOverCore
import TurnOverSpeech
import TurnOverAX
import AXFixtures

private final class ClaudeProgressTrial {
    var now = Date(timeIntervalSince1970: 1000)
    var speechBusy = true
    var callbacks: [@MainActor () -> Void] = []
    var said: [String] = []
    var forwarded = 0

    func load(_ session: String, alpha: String = "Public task Alpha progress", groupTail: String = "Public group detail", live: String = "polite", sidebar: Int? = nil, sidebarURLs: Bool = true) {
        AXReplay.load(.init(app: "Public progress sample", bundle: "test.claude-progress", recorded: "synthetic",
                            root: 0, application: 1, focus: 0, nodes: [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url(session), "AXParent": .element(1), "AXChildren": .elements([12, 2])]),
            .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
            .init(id: 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(alpha), "AXARIALive": .string(live), "AXParent": .element(sidebar ?? 0)]),
            .init(id: 3, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public task Beta progress"), "AXARIALive": .string("polite")]),
            .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXTitle": .string("Progress label"), "AXValue": .string("Progress value"),
                                 "AXChildren": .elements([6, 7]), "AXARIALive": .string("polite")]),
            .init(id: 6, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public group summary. ")]),
            .init(id: 7, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(groupTail)]),
            .init(id: 10, attrs: ["AXRole": .string("AXLink"), "AXParent": .element(12), "AXChildren": .elements(sidebar == 10 ? [2] : []), "AXURL": .string(sidebarURLs ? "https://example.com/sidebar-a" : "")]),
            .init(id: 11, attrs: ["AXRole": .string("AXLink"), "AXParent": .element(12), "AXChildren": .elements(sidebar == 11 ? [2] : []), "AXURL": .string(sidebarURLs ? "https://example.com/sidebar-b" : "")]),
            .init(id: 12, attrs: ["AXRole": .string("AXGroup"), "AXSubrole": .string("AXLandmarkNavigation"), "AXChildren": .elements([10, 11])]),
            .init(id: 4, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public task Gamma progress"), "AXARIALive": .string("polite")]),
        ]))
        if sidebar != nil, let page = API.focusTreeInterceptor {
            // The production module must classify from the real buffer publication, not a test lookup.
            page.buffer.buildForInspection()
        }
    }

    func event(_ id: Int, module: ClaudeAppModule) {
        module.handleEvent(Event(.liveRegionChange, ObjectFactory.make(AXReplay.element(id)))) { self.forwarded += 1 }
    }

    func poll(after seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let ready = callbacks
        callbacks = []
        for callback in ready { callback() }
    }
}

private func withClaudeProgress(overrideSpeechBusy: Bool = true, _ body: (ClaudeProgressTrial, ClaudeAppModule) -> Void) {
    let savedConfig = config, savedSink = Speech.sink, savedMode = Speech.mode
    let savedKey = InputManager.lastKeyDownAt, savedPid = AXHandler.shared.activePid
    let savedFocus = API.focusObject, savedAncestors = API.focusAncestors, savedPage = API.focusTreeInterceptor
    let trial = ClaudeProgressTrial()
    trial.load("https://example.com/progress-a")
    let root = AXReplay.element(0)
    let page = BrowseModeDocument(webArea: root, buffer: WebBuffer(webArea: root))
    API.setFocusObject(ObjectFactory.make(root), ancestors: [], interceptor: page)
    AXHandler.shared.activePid = root.pid
    config.presentation.reportDynamicContentChanges = true
    Speech.mode = .off
    Speech.sink = { trial.said.append($0) }
    InputManager.lastKeyDownAt = trial.now.addingTimeInterval(-10)
    let module = ClaudeAppModule(pid: root.pid, bundleIdentifier: "com.anthropic.claudefordesktop", appName: "Claude")
    module.progressNow = { trial.now }
    if overrideSpeechBusy { module.progressSpeechBusy = { trial.speechBusy } }
    module.progressScheduler = { delay, callback in
        expect(delay, 0.5, "quiet is checked promptly even after the ceiling")
        trial.callbacks.append(callback)
    }
    defer {
        trial.callbacks = []
        API.setFocusObject(savedFocus, ancestors: savedAncestors, interceptor: savedPage)
        AXHandler.shared.activePid = savedPid
        InputManager.lastKeyDownAt = savedKey
        Speech.sink = savedSink; Speech.mode = savedMode; config = savedConfig
        AXReplay.unload()
    }
    body(trial, module)
}

func progressOutputTests() {
    // 14 Nov 2026: sidebar notices were sent through the assertive bypass and interrupted reading.
    test("Claude progress: named sidebar status waits for speech and keys and keeps the newest per session") {
        withClaudeProgress { trial, module in
            let openSession = "https://example.com/progress-a"
            trial.load(openSession, alpha: "Public Alpha task. Running", live: "assertive", sidebar: 10)
            AXReplay.reads = []
            trial.event(2, module: module)
            expect(AXReplay.reads?.filter { $0.attribute == "AXParent" }.count, 0,
                   "captured structural sidebar identity needs no live ancestor queries")
            AXReplay.reads = nil
            check(trial.said.isEmpty, "busy speech holds the sidebar notice")
            expect(trial.forwarded, 0, "a sidebar assertive notice cannot bypass the quiet rule")
            trial.poll(after: 2)
            check(trial.said.isEmpty, "quiet keys alone do not release sidebar status")
            trial.load(openSession, alpha: "Public Alpha task. Awaiting input", live: "assertive", sidebar: 10)
            trial.event(2, module: module)
            trial.poll(after: 0.1)
            trial.load(openSession, alpha: "Public Beta task. Unread response", live: "assertive", sidebar: 11)
            trial.event(2, module: module)
            trial.speechBusy = false
            InputManager.lastKeyDownAt = trial.now
            trial.poll(after: 1)
            check(trial.said.isEmpty, "idle speech alone does not release while keys are recent")
            trial.poll(after: 0.5)
            expect(trial.said, ["Public Alpha task. Awaiting input"], "only Alpha's newest status is released on the still-open page")
            trial.speechBusy = true
            trial.poll(after: 2)
            expect(trial.said.count, 1, "the next session cannot interrupt speech that started after the first release")
            trial.speechBusy = false
            trial.poll(after: 0.5)
            expect(trial.said, ["Public Alpha task. Awaiting input", "Public Beta task. Unread response"], "Beta retains its own newest status")
            check(trial.callbacks.isEmpty, "each session status is consumed once")
            trial.load(openSession, alpha: "Claude finished the response", live: "assertive")
            trial.event(2, module: module)
            expect(trial.forwarded, 1, "the open conversation's assertive notice keeps its ordinary delivery")
        }
    }

    test("Claude progress: identical sidebar titles retain separate sessions") {
        withClaudeProgress { trial, module in
            let page = "https://example.com/progress-a"
            trial.load(page, alpha: "Same title. Running", live: "assertive", sidebar: 10)
            trial.event(2, module: module)
            trial.load(page, alpha: "Same title. Unread response", live: "assertive", sidebar: 11)
            trial.event(2, module: module)
            trial.speechBusy = false
            trial.poll(after: 2)
            trial.poll(after: 0.5)
            expect(Set(trial.said), Set(["Same title. Running", "Same title. Unread response"]))
            expect(trial.said.count, 2, "identical titles do not overwrite separate sessions")
        }
    }

    test("Claude progress: a sidebar rename replaces its pending notice with URL or element identity") {
        for hasURL in [false, true] {
            withClaudeProgress { trial, module in
                let page = "https://example.com/progress-a"
                trial.load(page, alpha: "Old title. Running", live: "assertive", sidebar: 10, sidebarURLs: hasURL)
                trial.event(2, module: module)
                trial.load(page, alpha: "Renamed title. Awaiting input", live: "assertive", sidebar: 10, sidebarURLs: hasURL)
                trial.event(2, module: module)
                trial.speechBusy = false
                trial.poll(after: 2)
                trial.poll(after: 0.5)
                expect(trial.said, ["Renamed title. Awaiting input"], "renaming leaves no obsolete pending title")
            }
        }
    }

    test("Claude progress: current conversation suffix keeps assertive delivery without a duplicate text walk") {
        withClaudeProgress { trial, module in
            trial.load("https://example.com/progress-a", alpha: "Public task. Running", live: "assertive")
            let object = ObjectFactory.make(AXReplay.element(2))
            _ = object.value
            AXReplay.reads = []
            defer { AXReplay.reads = nil }
            module.handleEvent(Event(.liveRegionChange, object)) {
                trial.forwarded += 1
                object.event_liveRegionChange()
            }
            expect(trial.forwarded, 1, "matching words in the conversation are ordinary assertive news")
            expect(AXReplay.reads?.filter { $0.attribute == "AXParent" }.count, 0,
                   "an uncaptured status-like notice never queries its ancestors on main")
            expect(AXReplay.reads?.filter { $0.id == 2 && $0.attribute == "AXValue" }.count, 1,
                   "the object reads the transcript once; its cached value needs no preliminary transcript walk")
            check(trial.callbacks.isEmpty, "ordinary assertive text is never held as sidebar status")
        }
    }

    test("Claude progress: unrelated assertive text inside sidebar navigation keeps ordinary delivery") {
        withClaudeProgress { trial, module in
            trial.load("https://example.com/progress-a", alpha: "Public sidebar command completed", live: "assertive", sidebar: 10)
            trial.event(2, module: module)
            expect(trial.forwarded, 1, "structural location alone does not identify session status")
            check(trial.callbacks.isEmpty, "unrelated sidebar news has no held progress")
        }
    }

    test("Claude progress: a large ordinary assertive region is traversed only once by the production object handler") {
        withClaudeProgress { trial, module in
            let children = Array(100..<1100)
            var nodes: [AXFixture.Node] = [
                .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/progress-a")]),
                .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
                .init(id: 5, attrs: ["AXRole": .string("AXGroup"), "AXParent": .element(0),
                                      "AXARIALive": .string("assertive"), "AXChildren": .elements(children)])
            ]
            nodes += children.map { .init(id: $0, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string("Public progress. ")]) }
            AXReplay.load(.init(app: "Public progress sample", bundle: "test.claude-progress", recorded: "synthetic",
                                root: 0, application: 1, focus: 0, nodes: nodes))
            let object = ObjectFactory.make(AXReplay.element(5))
            _ = object.value
            _ = object.name
            AXReplay.reads = []
            defer { AXReplay.reads = nil }
            module.handleEvent(Event(.liveRegionChange, object)) {
                trial.forwarded += 1
                object.event_liveRegionChange()
            }
            expect(trial.forwarded, 1)
            expect(AXReplay.reads?.filter { children.contains($0.id) && $0.attribute == "AXValue" }.count, 1000,
                   "each child is read once across module and object dispatch")
            check((AXReplay.reads?.count ?? Int.max) < 2100, "AX calls grow with one traversal, not two")
            check(!trial.said.isEmpty, "the real object handler reaches speech output")
        }
    }

    test("Claude progress: default busy provider follows the real player's pending queue") {
        let savedPlayer = Speech.player
        defer { Speech.player = savedPlayer }
        withClaudeProgress(overrideSpeechBusy: false) { trial, module in
            Speech.player = SpeechPlayer(pendingSpeechForTesting: true)
            check(Speech.player.isBusy, "a pending utterance sets the production busy count")
            trial.event(2, module: module)
            check(trial.said.isEmpty, "the default busy provider cannot deliver immediately")
            check(module.progressHeldSince(session: "https://example.com/progress-a") != nil, "the busy player admits a pending notice")
            expect(trial.forwarded, 0, "the default provider must hold an event while the actual player is busy")
            trial.poll(after: 2)
            check(trial.said.isEmpty, "quiet keys cannot release over the busy player's queue")
            Speech.player = SpeechPlayer(pendingSpeechForTesting: false)
            check(!Speech.player.isBusy, "an empty production queue is idle")
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Alpha progress"])
            Speech.player = nil
            check(!module.progressSpeechBusy(), "no player is idle")
            trial.poll(after: 1)
            expect(trial.said.count, 1, "the notice was delivered once")
        }
    }

    test("Claude progress: a delivered line repeated during speech is not queued again") {
        withClaudeProgress { trial, module in
            trial.event(2, module: module)
            trial.speechBusy = false
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Alpha progress"])
            trial.speechBusy = true
            trial.event(2, module: module)
            trial.speechBusy = false
            trial.poll(after: 1)
            expect(trial.said, ["Public task Alpha progress"], "an identical event while speaking cannot repeat after idle")
            check(trial.callbacks.isEmpty, "the delivered duplicate starts no release chain")
            trial.event(4, module: module)
            expect(trial.said.last, "Public task Gamma progress", "different progress remains eligible for immediate delivery")
        }
    }

    // 14 Nov 2026 (third review): X said, Y held, X again: Y is out of date and must not be said later.
    test("Claude progress: a repeat of the spoken line drops an older held line") {
        withClaudeProgress { trial, module in
            trial.speechBusy = false
            trial.event(2, module: module)
            expect(trial.said, ["Public task Alpha progress"])
            trial.speechBusy = true
            trial.event(3, module: module)
            check(module.progressHeldSince(session: "https://example.com/progress-a") != nil, "Beta waits while speech is busy")
            trial.event(2, module: module)
            check(module.progressHeldSince(session: "https://example.com/progress-a") == nil, "the repeated Alpha drops the held Beta")
            trial.speechBusy = false
            trial.poll(after: 2)
            expect(trial.said, ["Public task Alpha progress"], "the out-of-date Beta is never said")
        }
    }

    test("Claude progress: immediate delivery deduplicates per conversation and permits changed lines") {
        withClaudeProgress { trial, module in
            trial.speechBusy = false
            trial.event(2, module: module)
            trial.event(2, module: module)
            trial.event(3, module: module)
            trial.event(2, module: module)
            expect(trial.said, ["Public task Alpha progress", "Public task Beta progress", "Public task Alpha progress"], "X then Y then X are distinct updates")
            trial.load("https://example.com/progress-b")
            trial.event(2, module: module)
            expect(trial.said.count, 4, "identical words in another conversation are delivered immediately")
            trial.load("https://example.com/progress-a")
            trial.event(2, module: module)
            expect(trial.said.count, 4, "returning remembers this conversation's delivered line")
        }
    }

    for initiallyBusy in [false, true] {
        test("Claude progress: a named group's descendant words survive \(initiallyBusy ? "held" : "immediate") delivery") {
            withClaudeProgress { trial, module in
                trial.speechBusy = initiallyBusy
                trial.event(5, module: module)
                if initiallyBusy {
                    check(trial.said.isEmpty, "the aggregate notice waits while busy")
                    trial.speechBusy = false
                    trial.poll(after: 0.5)
                }
                expect(trial.said, ["Public group summary. Public group detail"], "both children are spoken instead of the group's label or value")
                trial.event(5, module: module)
                expect(trial.said.count, 1, "the complete aggregate is deduplicated")
                trial.load("https://example.com/progress-a", groupTail: "Public changed detail")
                trial.event(5, module: module)
                expect(trial.said.last, "Public group summary. Public changed detail", "changed children remain news despite unchanged group label and value")
                expect(trial.said.count, 2)
            }
        }
    }

    test("Claude progress: quiet keys do not interrupt long reading") {
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 1.5, speechBusy: true), .wait)
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 20, speechBusy: true), .wait)
    }

    test("Claude progress: speech becoming idle releases the held line") {
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 2, speechBusy: true), .wait)
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 2.5, speechBusy: false), .release)
    }

    test("Claude progress: renewed key activity waits even when speech is idle") {
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 1.49, speechBusy: false), .wait)
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 0, speechBusy: false), .wait)
        expect(ClaudeProgressReadiness.decision(keyQuietFor: 1.5, speechBusy: false), .release)
    }

    test("Claude progress: ceiling retains a real event until speech and keys are quiet, once") {
        withClaudeProgress { trial, module in
            trial.event(2, module: module)
            expect(trial.forwarded, 0, "busy speech holds the production live-region event")
            trial.poll(after: 59)
            trial.poll(after: 1)
            check(trial.said.isEmpty, "the ceiling cannot interrupt reading")
            check(module.progressHeldSince(session: "https://example.com/progress-a") != nil, "the line survives its ceiling")
            trial.speechBusy = false
            InputManager.lastKeyDownAt = trial.now
            trial.poll(after: 1)
            check(trial.said.isEmpty, "idle speech alone cannot release while keys are active")
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Alpha progress"])
            trial.poll(after: 5)
            expect(trial.said, ["Public task Alpha progress"], "no duplicate release")
            check(trial.callbacks.isEmpty, "the polling chain ends after delivery")
        }
    }

    test("Claude progress: speech becoming idle exactly at the ceiling releases the notice") {
        withClaudeProgress { trial, module in
            trial.event(2, module: module)
            trial.poll(after: 59)
            trial.speechBusy = false
            trial.poll(after: 1)
            expect(trial.said, ["Public task Alpha progress"])
            check(trial.callbacks.isEmpty, "the deadline neither drops the notice nor schedules another release")
        }
    }

    test("Claude progress: a newer same-conversation line replaces the waiting line without resetting its clock") {
        withClaudeProgress { trial, module in
            trial.event(2, module: module)
            let first = module.progressHeldSince(session: "https://example.com/progress-a")
            trial.poll(after: 61)
            trial.event(4, module: module)
            expect(module.progressHeldSince(session: "https://example.com/progress-a"), first)
            expect(trial.callbacks.count, 1, "replacement does not start a second polling chain")
            trial.speechBusy = false
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Gamma progress"], "only the newest notice is delivered")
        }
    }

    test("Claude progress: conversation B gets its own clock after A waits 59 seconds, and A survives returning") {
        withClaudeProgress { trial, module in
            trial.event(2, module: module)
            let firstA = module.progressHeldSince(session: "https://example.com/progress-a")
            trial.poll(after: 59)
            trial.load("https://example.com/progress-b")
            trial.event(3, module: module)
            expect(module.progressHeldSince(session: "https://example.com/progress-b"), trial.now, "B starts its own hold")
            expect(module.progressHeldSince(session: "https://example.com/progress-a"), firstA, "A keeps its own clock")
            trial.poll(after: 1)
            trial.speechBusy = false
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Beta progress"], "only the current conversation speaks")
            trial.load("https://example.com/progress-a")
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Beta progress", "Public task Alpha progress"], "A was retained beyond its ceiling")
            check(trial.callbacks.isEmpty, "all notices delivered once")
        }
    }

    test("Claude progress: identical notices in different conversations are each delivered once") {
        withClaudeProgress { trial, module in
            let same = "Public identical progress in two conversations"
            trial.load("https://example.com/progress-a", alpha: same)
            trial.event(2, module: module)
            trial.load("https://example.com/progress-b", alpha: same)
            trial.event(2, module: module)
            trial.speechBusy = false
            trial.poll(after: 0.5)
            expect(trial.said, [same], "B's notice is delivered first")
            trial.load("https://example.com/progress-a", alpha: same)
            trial.poll(after: 0.5)
            expect(trial.said, [same, same], "global live-region deduplication cannot discard A's held notice")
            check(trial.callbacks.isEmpty, "both waiting notices are consumed once")
        }
    }

    for changedText in ["", "A different region now uses this element"] {
        test("Claude progress: event text survives its live region being removed or reused: \(changedText.isEmpty ? "removed" : "reused")") {
            withClaudeProgress { trial, module in
                let original = changedText.isEmpty ? "Public saved notice before removal" : "Public saved notice before reuse"
                trial.load("https://example.com/progress-a", alpha: original)
                trial.event(2, module: module)
                // No new live-region event arrived. Provider churn must not replace an undelivered notice.
                AXReplay.load(.init(app: "Public progress sample", bundle: "test.claude-progress", recorded: "synthetic",
                                    root: 0, application: 1, focus: 0, nodes: [
                    .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/progress-a"), "AXParent": .element(1)]),
                    .init(id: 1, attrs: ["AXRole": .string("AXApplication")]),
                ] + (changedText.isEmpty ? [] : [
                    .init(id: 2, attrs: ["AXRole": .string("AXStaticText"), "AXValue": .string(changedText)]),
                ])))
                trial.speechBusy = false
                trial.poll(after: 61)
                expect(trial.said, [original], "the event's original words survive provider churn")
                trial.poll(after: 1)
                expect(trial.said.count, 1, "the saved notice is released once")
            }
        }
    }

    test("Claude progress: release still checks speech after an event was held only by recent keys") {
        withClaudeProgress { trial, module in
            trial.speechBusy = false
            InputManager.lastKeyDownAt = trial.now
            trial.event(4, module: module)
            expect(trial.forwarded, 0)
            trial.speechBusy = true
            trial.poll(after: 2)
            check(trial.said.isEmpty, "speech beginning during key quiet still holds the line")
            trial.speechBusy = false
            trial.poll(after: 0.5)
            expect(trial.said, ["Public task Gamma progress"])
        }
    }

    test("progress output: NVDA's pitch, 110 Hz at 0 percent, an octave each 25, 1760 Hz at 100") {
        expect(Tones.progressFrequency(0), 110)
        expect(Tones.progressFrequency(25), 220)
        expect(Tones.progressFrequency(50), 440)
        expect(Tones.progressFrequency(100), 1760)
        expect(Tones.progressFrequency(-5), 110, "below the range")
        expect(Tones.progressFrequency(150), 1760, "above the range")
    }

    test("progress output: a beep for each percent, words for each ten, 100 said as it climbs there") {
        typealias Step = ProgressOutput.Step
        @MainActor func step(_ p: Int, _ beeped: Int, _ said: Int, _ last: Int, _ mode: String) -> Step {
            ProgressOutput.step(p, beeped: beeped, said: said, last: last, mode: mode)
        }
        expect(step(7, 6, 6, 6, "beep"), Step(beep: true))
        expect(step(6, 6, 6, 6, "beep"), Step(), "no change, no beep")
        expect(step(12, 9, 9, 9, "beep"), Step(beep: true), "beep mode says nothing")
        expect(step(9, 3, 3, 3, "speak"), Step(), "still in the same ten")
        expect(step(12, 9, 9, 9, "speak"), Step(say: "12 percent"))
        expect(step(12, 11, 9, 11, "both"), Step(beep: true, say: "12 percent"))
        expect(step(4, 12, 12, 12, "both"), Step(beep: true, say: "4 percent"), "a bar going back")
        expect(step(100, 97, 90, 97, "speak"), Step(say: "100 percent", done: true))
        expect(step(100, 97, 90, 97, "beep"), Step(beep: true, done: true))
        expect(step(100, 97, 97, 97, "off"), Step(done: true), "off: silent, and still over at 100")
        expect(step(50, 3, 3, 3, "off"), Step())
        expect(step(100, 100, 100, 100, "both"), Step(), "a bar read at 100 isn't over")
    }

    test("progress output: a bar read at 100 can fall back and climb again") {
        let savedSink = Speech.sink, savedMode = config.presentation.progressBars
        defer { Speech.sink = savedSink; config.presentation.progressBars = savedMode }
        var said: [String] = []
        Speech.sink = { said.append($0) }
        config.presentation.progressBars = "speak"
        var progress = ProgressOutput(at: 100)
        check(!progress.update(100), "still at 100: not over")
        check(!progress.update(0), "the next stage")
        check(!progress.update(55), "climbing")
        check(progress.update(100), "over as it climbs to 100")
        expect(said, ["0 percent", "55 percent", "100 percent"])
    }

    test("progress output: a progress kept by a module is said through the setting") {
        let savedSink = Speech.sink, savedMode = config.presentation.progressBars
        defer { Speech.sink = savedSink; config.presentation.progressBars = savedMode }
        var said: [String] = []
        Speech.sink = { said.append($0) }
        config.presentation.progressBars = "speak"
        var progress = ProgressOutput(at: 5)
        check(!progress.update(5), "the percentage just read isn't said again")
        check(!progress.update(8), "under the next ten")
        check(!progress.update(31), "a new ten")
        check(progress.update(100), "over at 100")
        expect(said, ["31 percent", "100 percent"])
    }

    test("progress output: a named progress says its name with the percentage, as an App Store download does") {
        let savedSink = Speech.sink, savedMode = config.presentation.progressBars
        defer { Speech.sink = savedSink; config.presentation.progressBars = savedMode }
        var said: [String] = []
        Speech.sink = { said.append($0) }
        config.presentation.progressBars = "speak"
        var download = ProgressOutput(at: 0, name: "Example App")
        download.update(4); download.update(12); download.update(99)
        expect(said, ["Example App, 12 percent", "Example App, 99 percent"])
        check(download.update(100), "over at 100")
        expect(said.last, "100 percent", "the end isn't named: the module says the app is installed")
        config.presentation.progressBars = "both"
        check(ProgressOutput.beeps, "both beeps")
        config.presentation.progressBars = "speak"
        check(!ProgressOutput.beeps, "speak doesn't")
    }

    test("progress output: NVDA+U goes off, speak, beep, both, and round again") {
        expect(ProgressOutput.mode(after: "off"), "speak")
        expect(ProgressOutput.mode(after: "speak"), "beep")
        expect(ProgressOutput.mode(after: "beep"), "both")
        expect(ProgressOutput.mode(after: "both"), "off")
        let savedSink = Speech.sink, savedMode = config.presentation.progressBars
        defer { Speech.sink = savedSink; config.presentation.progressBars = savedMode }
        var said: [String] = []
        Speech.sink = { said.append($0) }
        config.presentation.progressBars = "speak"
        ProgressOutput.cycleMode()
        expect(config.presentation.progressBars, "beep")
        expect(said, ["Beep for progress bar updates"])
    }

    test("progress output: a page's progress bar is a line of its own in browse mode, read as a control") {
        var f = AXFixture(app: "T", bundle: "t", recorded: "", root: 0, application: 9, focus: 0, nodes: [])
        f.nodes = [
            .init(id: 0, attrs: ["AXRole": .string("AXWebArea"), "AXURL": .url("https://example.com/"), "AXParent": .element(9), "AXChildren": .elements([1])]),
            .init(id: 1, attrs: ["AXRole": .string("AXProgressIndicator"), "AXTitle": .string("Test progress"), "AXValue": .number(40),
                                 "AXMinValue": .number(0), "AXMaxValue": .number(100), "AXParent": .element(0)]),
            .init(id: 9, attrs: ["AXRole": .string("AXApplication"), "AXTitle": .string("T"), "AXChildren": .elements([0])]),
        ]
        AXReplay.load(f)
        defer { AXReplay.unload() }
        // The buffer alone, not BrowseModeHandler's document: a document kept there for this made-up page was found
        // again by the next test's page of the same ids.
        let buffer = WebBuffer(webArea: AXReplay.root!)
        buffer.build()
        waitForBuffer(buffer)
        let line = buffer.lines.first { $0.isControl }
        check(line != nil, "the bar has a control line")
        expect(line.map { buffer.text.substring(with: NSRange(location: $0.start, length: $0.end - $0.start)) }, "Test progress")
        expect(line?.fields ?? [], ["progress bar", "40 percent"])
    }

    test("progress output: the setting reads beep when missing or unknown") {
        @MainActor func mode(_ json: String) -> String? {
            (try? JSONDecoder().decode(Config.Presentation.self, from: Data(json.utf8)))?.progressBars
        }
        expect(mode("{}"), "beep")
        expect(mode(#"{"progressBars": "speak"}"#), "speak")
        expect(mode(#"{"progressBars": "loud"}"#), "beep")
        expect(Config.Presentation().progressBars, "beep")
    }
}
