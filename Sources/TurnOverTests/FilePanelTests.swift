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
}
