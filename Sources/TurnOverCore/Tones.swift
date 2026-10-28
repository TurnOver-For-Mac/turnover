// SPDX-License-Identifier: GPL-3.0-or-later
// Tones (NVDA: tones.beep; VoiceOver's sound effects). Short, distinct, mixed
// with speech so they never delay it. Each element kind has its own sound.
import Foundation

public enum Tones {
    /// Coexisting, TurnOver's own tones and bells are off: VoiceOver's sounds (its own, and its files played by
    /// TurnOver) are the sounds (17 Oct 2026: "turn off TurnOver's sounds").
    /// The sounds setting (17 Oct 2026): TurnOver's own tones when "TurnOver's" is chosen; otherwise VoiceOver's
    /// files (VoiceOverSounds), and TurnOver's tones only where VoiceOver has no sound and VoiceOver is off.
    static var own: Bool { config.general.effectiveSounds == "turnover" || !Coexist.on }
    /// One of TurnOver's own sounds (TurnOverSounds) where TurnOver plays its own: false leaves the old tone to play.
    /// `ifChosen`: VoiceOver has its own sound for this, so only when TurnOver's sounds are chosen.
    private static func fresh(_ name: String, ifChosen: Bool = false) -> Bool {
        guard ifChosen ? config.general.effectiveSounds == "turnover" : own else { return false }
        return Thread.isMainThread ? MainActor.assumeIsolated { TurnOverSounds.play(name) } : false
    }
    public static func beep(_ frequency: Double, _ ms: Int, volume: Float = 0.25) {
        guard own else { return }
        Speech.player?.playTone(frequency: frequency, durationMs: ms, volume: volume)
    }
    /// Headings: higher for level 1, descending by level.
    public static func heading(level: Int) { if fresh("heading\(min(6, max(1, level)))") { return }; beep(level <= 0 ? 700 : max(440, 1000 - Double(level - 1) * 110), 60) }
    /// VoiceOver's own sounds where it has one (17 Oct 2026); TurnOver's tone where it hasn't, or off the Mac.
    private static func voiceOver(_ name: String) -> Bool { Thread.isMainThread ? MainActor.assumeIsolated { VoiceOverSounds.play(name) } : false }
    public static func link() { if fresh("link", ifChosen: true) { return }; if !voiceOver("LinkBegin.aiff") { beep(1400, 25, volume: 0.18) } }
    public static func list() { if fresh("list") { return }; beep(520, 40) }
    public static func landmark() { if fresh("landmark") { return }; beep(620, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { beep(780, 40) } }
    public static func table() { if fresh("table") { return }; beep(400, 50) }
    public static func graphic() { if fresh("graphic") { return }; beep(1100, 35, volume: 0.18) }
    public static func blockQuote() { if fresh("blockquote") { return }; beep(560, 45) }
    public static func spellingError() { if fresh("spelling", ifChosen: true) { return }; if !voiceOver("Misspelled.aiff") { beep(300, 70) } }
    /// The caret could not leave the line or the document (NVDA re-reads the line; a bump is kinder).
    /// Also felt on the trackpad while trackpad control is on (Trackpad sets it).
    nonisolated(unsafe) public static var onEdge: (@MainActor () -> Void)?
    /// Coexisting, VoiceOver's own boundary sound plays (it sees the key TurnOver sends on), so TurnOver's tone is
    /// silent there: both played at a boundary in Word (17 Oct 2026: "we should be using VoiceOver sounds").
    /// `keySent`: the key went on to the app, so VoiceOver's own boundary sound plays and TurnOver's stays silent;
    /// otherwise, coexisting, VoiceOver's boundary file (a list's end in Messages was silent, 17 Oct 2026).
    public static func edge(keySent: Bool = false) {
        if !Coexist.on { if !fresh("edge") { beep(220, 50, volume: 0.2) } }
        else if !keySent { _ = voiceOver("WrapBoundary.aiff") }
        onEdge?()
    }
    /// Taking over from VoiceOver: two bell notes a fifth apart, rising (G5, D6). Handing back: the same falling.
    /// Short and soft, as it is heard every time an application changes hands.
    /// TurnOver has started while VoiceOver has the Mac: a short rising pair, so a tester with Open at login knows it is
    /// there (NVDA's start-up sound; a tester, 9 Oct 2026). Speech would be silent with VoiceOver on; a tone is not.
    public static func startup() { if !own { return }; if fresh("startup") { return }; Speech.player?.playBell(frequencies: [659, 880], spacingMs: 90, ringMs: 160, volume: 0.18) }
    public static func takeOver() { if !own { return }; if fresh("take_over") { return }; Speech.player?.playBell(frequencies: [784, 1175], spacingMs: 70, ringMs: 150) }
    /// A braille display connected (three notes up) and gone (three down), as VoiceOver gives a sound for it.
    public static func brailleConnected() { if !own { return }; if fresh("braille_on") { return }; Speech.player?.playBell(frequencies: [523, 659, 784], spacingMs: 80, ringMs: 220, volume: 0.22) }
    public static func brailleDisconnected() { if !own { return }; if fresh("braille_off") { return }; Speech.player?.playBell(frequencies: [784, 659, 523], spacingMs: 80, ringMs: 220, volume: 0.22) }
    public static func handBack() { if !own { return }; if fresh("hand_back") { return }; Speech.player?.playBell(frequencies: [1175, 784], spacingMs: 70, ringMs: 150) }
    /// The focus moved (Tab, a new control): VoiceOver's little tick. Very short, high and quiet.
    public static func focusTick() {
        guard own else { return }
        guard config.general.navigationSounds else { return }
        if Date().timeIntervalSince(lastTick) < 0.05 { return }   // a burst of focus events is one move
        lastTick = Date()
        if fresh("tick") { return }
        Speech.player?.playBell(frequencies: [2600], spacingMs: 0, ringMs: 18, volume: 0.07)
    }
    private static var lastTick = Date.distantPast
    /// An item was pressed (a link followed, a button pressed): a fuller click, lower, two partials together.
    public static func press() {
        guard own else { return }
        guard config.general.navigationSounds else { return }
        if fresh("press") { return }
        Speech.player?.playBell(frequencies: [1300, 1950], spacingMs: 6, ringMs: 35, volume: 0.09)
    }
    /// Into focus mode (typing into the page): two notes rising. Back to browse mode: the same falling. NVDA's
    /// "audio indication of focus and browse modes".
    // (The browse and focus mode tones are TurnOver's own idea, NVDA's: VoiceOver plays nothing when a field takes the
    // focus, so its Quick Nav sounds were wrong here: every return to Claude played "Quick Nav off", 17 Oct 2026.)
    public static func focusMode() { if fresh("focus_mode") { return }; beep(523, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { beep(784, 45, volume: 0.18) } }
    public static func browseMode() { if fresh("browse_mode") { return }; beep(784, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { beep(523, 45, volume: 0.18) } }
    /// Commented text in a document (Word): two quick notes.
    public static func comment() { if fresh("comment") { return }; beep(880, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { beep(1175, 35, volume: 0.18) } }
}
