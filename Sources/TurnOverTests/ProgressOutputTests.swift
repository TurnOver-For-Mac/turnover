// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import TurnOverCore
import AXFixtures

func progressOutputTests() {
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
