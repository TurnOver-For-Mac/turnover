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
}
