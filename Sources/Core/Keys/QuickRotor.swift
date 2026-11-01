// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's rotor without opening it: VO-Command-Left and Right choose the kind (headings, links, form controls,
// tables, landmarks, lists, images; in Word comments, tracked changes, misspelled words, pages), VO-Command-Up and
// Down move to the previous and next one. The speech settings are VO-Command-Shift with the arrows, as Apple's guide
// has them now (17 Oct 2026: "VO Command Shift Left and Right, whilst VO Command is the rotor").
// Each kind runs the move scripts that exist where the cursor is (a page's, Word's), so the rotor offers only what
// can be moved to there.
import Foundation

@MainActor
public enum QuickRotor {
    struct Kind { let spoken: String; let next: [String]; let previous: [String] }
    static let kinds: [Kind] = [
        Kind(spoken: "headings", next: ["vo_nextHeading", "nextHeading"], previous: ["vo_previousHeading", "previousHeading"]),
        Kind(spoken: "links", next: ["vo_nextLink"], previous: ["vo_previousLink"]),
        Kind(spoken: "form controls", next: ["vo_nextControl"], previous: ["vo_previousControl"]),
        Kind(spoken: "text fields", next: ["vo_nextTextField"], previous: ["vo_previousTextField"]),
        Kind(spoken: "buttons", next: ["vo_nextButton"], previous: ["vo_previousButton"]),
        Kind(spoken: "check boxes", next: ["vo_nextCheckBox"], previous: ["vo_previousCheckBox"]),
        Kind(spoken: "tables", next: ["vo_nextTable", "nextTable"], previous: ["vo_previousTable", "previousTable"]),
        Kind(spoken: "landmarks", next: ["vo_nextLandmark"], previous: ["vo_previousLandmark"]),
        Kind(spoken: "lists", next: ["vo_nextList"], previous: ["vo_previousList"]),
        Kind(spoken: "images", next: ["vo_nextGraphic"], previous: ["vo_previousGraphic"]),
        Kind(spoken: "comments", next: ["nextComment"], previous: ["previousComment"]),
        Kind(spoken: "tracked changes", next: ["nextRevision"], previous: ["previousRevision"]),
        Kind(spoken: "misspelled words", next: ["vo_nextSpellingError", "nextSpellingError"], previous: ["vo_previousSpellingError", "previousSpellingError"]),
        Kind(spoken: "pages", next: ["nextPage"], previous: ["previousPage"]),
    ]
    /// The kind chosen last, by name, so it survives a change of app or page.
    private static var chosen = "headings"

    private static func available() -> [Kind] {
        kinds.filter { k in k.next.contains { ScriptHandler.findScript(named: $0) != nil } }
    }

    /// VO-Command-Left and Right: the previous or next kind of those available here.
    public static func step(_ by: Int) {
        let a = available()
        guard !a.isEmpty else { Speech.speakMessage("nothing to move by here"); return }
        let here = a.firstIndex { $0.spoken == chosen } ?? (by > 0 ? -1 : 0)
        let i = ((here + by) % a.count + a.count) % a.count
        chosen = a[i].spoken
        Log.io("rotor: \(chosen)")
        Speech.speakMessage(chosen)
    }

    /// VO-Command-Up and Down: the previous or next item of the chosen kind.
    public static func move(forward: Bool, gesture: KeyboardGesture) {
        let a = available()
        guard !a.isEmpty else { Speech.speakMessage("nothing to move by here"); return }
        let kind = a.first { $0.spoken == chosen } ?? a[0]
        chosen = kind.spoken
        for name in (forward ? kind.next : kind.previous) {
            if let s = ScriptHandler.findScript(named: name) { s.handler(gesture); return }
        }
        Speech.speakMessage("no \(kind.spoken) here")
    }
}
