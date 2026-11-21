// SPDX-License-Identifier: GPL-3.0-or-later
// The Open and Save panels, read the light way (17 Nov 2026). Logic evidence only: the words and the once-only rule,
// not the panel's real tree or the time its opening takes, which only a live check on a real panel shows.
import Foundation
import TurnOverCore

func filePanelTests() {
    test("File panel: the folder is the first pop-up with a value") {
        check(FilePanel.folder(popUpValues: ["Downloads", "Rich Text Document"]) == "Downloads", "Save panel: Where comes before the format")
        check(FilePanel.folder(popUpValues: ["", "  Documents "]) == "Documents", "an empty pop-up is passed over, the value trimmed")
        check(FilePanel.folder(popUpValues: []) == nil, "no pop-up met: no folder said")
    }
    test("File panel: the opening words are its title, dialog and folder") {
        check(FilePanel.openingWords(title: "open", dialogWord: "dialog", folder: "Downloads") == "open, dialog, Downloads", "Mail's Save Attachments")
        check(FilePanel.openingWords(title: "Save", dialogWord: "dialog", folder: nil) == "Save, dialog", "no folder found")
        check(FilePanel.openingWords(title: "", dialogWord: "Dialog", folder: "Belgeler") == "Dialog, Belgeler", "no title; words in another language pass through")
    }
    test("File panel: its inner window is not said a second time") {
        check(FilePanel.staysSilent(isSamePart: false, secondsSinceSaid: 1.2, saidPartStillShows: true), "the inner window after its sheet")
        check(!FilePanel.staysSilent(isSamePart: false, secondsSinceSaid: 1.2, saidPartStillShows: false), "a new panel after the last one closed")
        check(!FilePanel.staysSilent(isSamePart: false, secondsSinceSaid: 61, saidPartStillShows: true), "a minute on, said again")
        check(FilePanel.staysSilent(isSamePart: true, secondsSinceSaid: 5, saidPartStillShows: true), "the same part entered again")
        check(!FilePanel.staysSilent(isSamePart: true, secondsSinceSaid: 90, saidPartStillShows: true), "the same part much later")
    }
    test("File panel: a new folder is said once, when it has held for 0.3 s") {
        var change = FilePanel.FolderChange(said: "Documents")
        check(change.note("Documents", at: 0) == nil, "the folder said as the panel opened is not said again")
        check(change.note("Downloads", at: 1.0) == nil, "Option Command L: not yet, it may still change")
        check(change.note("Downloads", at: 1.2) == nil, "0.2 s on: not yet")
        check(change.note("Downloads", at: 1.35) == "Downloads", "0.35 s on: said")
        check(change.note("Downloads", at: 1.6) == nil, "said once only")
        check(change.note("Desktop", at: 2.0) == nil, "Command Shift D")
        check(change.note("Macintosh HD", at: 2.1) == nil, "passing through another folder")
        check(change.note("Home", at: 2.2) == nil, "and another")
        check(change.note("Home", at: 2.6) == "Home", "only the folder it settled in is said")
        check(change.note(nil, at: 3.0) == nil, "the pop-up gone for a moment")
        check(change.note("Home", at: 3.5) == nil, "and back on the same folder: nothing")
        check(change.said == "Home", "the folder last said")
    }
    test("File panel: the folder watch backs off a panel that does not answer, and gives up after three") {
        var pacing = FilePanel.LookPacing()
        var reads = 0
        var finds = 0
        var answers: [FilePanel.Read] = []
        func step(_ now: Double, hasPopUp: Bool = true, found: Bool = true) -> FilePanel.Outcome {
            pacing.step(at: now, hasPopUp: hasPopUp,
                        read: { reads += 1; return answers.isEmpty ? .value("Downloads") : answers.removeFirst() },
                        find: { finds += 1; return found })
        }
        check(step(0) == .value("Downloads"), "an answer")
        answers = [.failed]
        check(step(0.2) == .unanswered, "a look that timed out")
        check(step(0.4) == .skipped && step(2.1) == .skipped, "no look for 2 s after it")
        check(reads == 2, "the skipped steps asked nothing")
        check(step(2.2) == .value("Downloads"), "looked again after 2 s, and answered")
        answers = [.failed]
        check(step(2.4) == .unanswered, "unanswered once")
        answers = [.value("Desktop")]
        check(step(4.4) == .value("Desktop"), "an answer resets the count")
        answers = [.failed, .failed, .failed]
        check(step(4.6) == .unanswered, "one")
        check(step(6.6) == .unanswered, "two")
        check(step(8.6) == .gaveUp, "three in a row: the watch ends")
        check(pacing.gaveUp && step(20) == .gaveUp, "and stays ended")
        check(reads == 8, "nothing asked after giving up")

        var searching = FilePanel.LookPacing()
        var looks = 0
        func search(_ now: Double) -> FilePanel.Outcome {
            searching.step(at: now, hasPopUp: false, read: { .value("Home") }, find: { looks += 1; return false })
        }
        check(search(0) == .unanswered, "the pop-up not found")
        check(search(1) == .skipped && search(1.9) == .skipped, "not looked for again within 2 s")
        check(looks == 1, "one search only")
        check(search(2) == .unanswered && looks == 2, "looked for again after 2 s")

        var closing = FilePanel.LookPacing()
        check(closing.step(at: 0, hasPopUp: true, read: { .closed }, find: { true }) == .closed, "the panel closed: the watch ends")
    }
}
