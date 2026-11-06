// SPDX-License-Identifier: GPL-3.0-or-later
// Tones (NVDA: tones.beep; VoiceOver's sound effects). Short, distinct, mixed
// with speech so they never delay it. Each element kind has its own sound.
import Foundation

public enum Tones {
    /// Whose sounds (Settings, Sounds; 17 Oct 2026): "VoiceOver's" is VoiceOver's own files (VoiceOverSounds) for the
    /// events VoiceOver marks with a sound, and TurnOver's own set (TurnOverSounds) for the rest, which VoiceOver says
    /// or passes over (headings, lists, moving and pressing, the modes, taking over). "TurnOver's" is the set
    /// throughout. Coexisting, VoiceOver is on and plays its own, so TurnOver's own are off ("turn off TurnOver's
    /// sounds"). The plain tones from before the set play where a file is missing. (3 Nov 2026: with VoiceOver's chosen
    /// and VoiceOver off, what VoiceOver hasn't fell to the plain tones, "they don't sound quite right".)
    static var chosen: Bool { config.general.effectiveSounds == "turnover" }
    /// A sound of TurnOver's own may play: its set is chosen, or VoiceOver is off.
    static var own: Bool { chosen || !Coexist.on }
    /// One of TurnOver's own set, where TurnOver's own may play: false leaves the old tone to play.
    private static func fresh(_ name: String) -> Bool {
        guard own else { return false }
        return Thread.isMainThread ? MainActor.assumeIsolated { TurnOverSounds.play(name) } : false
    }
    public static func beep(_ frequency: Double, _ ms: Int, volume: Float = 0.25) {
        guard own else { return }
        Speech.player?.playTone(frequency: frequency, durationMs: ms, volume: volume)
    }
    /// Headings: higher for level 1, descending by level.
    public static func heading(level: Int) { if fresh("heading\(min(6, max(1, level)))") { return }; beep(level <= 0 ? 700 : max(440, 1000 - Double(level - 1) * 110), 60) }
    /// VoiceOver's own sound where it has one (17 Oct 2026), or the set's with TurnOver's chosen; false off the main
    /// thread or with neither file, so the old tone plays.
    private static func voiceOver(_ name: String) -> Bool { Thread.isMainThread ? MainActor.assumeIsolated { VoiceOverSounds.play(name) } : false }
    public static func link() { if !voiceOver("LinkBegin.aiff") { beep(1400, 25, volume: 0.18) } }
    public static func list() { if fresh("list") { return }; beep(520, 40) }
    public static func landmark() { if fresh("landmark") { return }; beep(620, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { beep(780, 40) } }
    public static func table() { if fresh("table") { return }; beep(400, 50) }
    public static func graphic() { if fresh("graphic") { return }; beep(1100, 35, volume: 0.18) }
    public static func blockQuote() { if fresh("blockquote") { return }; beep(560, 45) }
    public static func spellingError() { if !voiceOver("Misspelled.aiff") { beep(300, 70) } }
    /// The caret could not leave the line or the document (NVDA re-reads the line; a bump is kinder).
    /// Also felt on the trackpad while trackpad control is on (Trackpad sets it).
    nonisolated(unsafe) public static var onEdge: (@MainActor () -> Void)?
    /// Coexisting, VoiceOver's own boundary sound plays (it sees the key TurnOver sends on), so TurnOver's tone is
    /// silent there: both played at a boundary in Word (17 Oct 2026: "we should be using VoiceOver sounds").
    /// `keySent`: the key went on to the app, so VoiceOver's own boundary sound plays and TurnOver's stays silent;
    /// otherwise, coexisting, VoiceOver's boundary file (a list's end in Messages was silent, 17 Oct 2026).
    /// A sound-only opt-out preserves the trackpad boundary feedback. Native caret callers take their app
    /// policy before sending the key; every other caller keeps the existing sound decision (#190).
    public static func edge(keySent: Bool = false, sound: Bool = true) {
        if sound { edgeSound(keySent) }
        onEdge?()
    }
    // A narrow playback seam lets regression tests observe the real edge request without starting audio.
    // The production function retains the existing sound-set and coexist decisions.
    package static var edgeSound: @MainActor (Bool) -> Void = playEdgeSound
    /// VoiceOver's "Boundary reached" (its Sounds Help menu) is WrapBoundary.aiff; ElementBorderHit.aiff is one of its
    /// trackpad sounds, with ElementHit and EmptyHit, "touched an element" and "touched empty space" (3 Nov 2026).
    private static func playEdgeSound(keySent: Bool) {
        if Coexist.on, keySent { return }   // VoiceOver sees the key and plays its own boundary sound
        if !voiceOver("WrapBoundary.aiff") { beep(220, 50, volume: 0.2) }
    }
    /// Taking over from VoiceOver: two bell notes a fifth apart, rising (G5, D6). Handing back: the same falling.
    /// Short and soft, as it is heard every time an application changes hands.
    /// TurnOver has started while VoiceOver has the Mac: a short rising pair, so a tester with Open at login knows it is
    /// there (NVDA's start-up sound; a tester, 9 Oct 2026). Speech would be silent with VoiceOver on; a tone is not.
    public static func startup() { if !own { return }; if fresh("startup") { return }; Speech.player?.playBell(frequencies: [659, 880], spacingMs: 90, ringMs: 160, volume: 0.18) }
    public static func takeOver() { if !own { return }; if fresh("take_over") { return }; Speech.player?.playBell(frequencies: [784, 1175], spacingMs: 70, ringMs: 150) }
    /// A braille display connected and gone: VoiceOver's sounds for them, or three notes up and three down.
    public static func brailleConnected() { if !own { return }; if !voiceOver("BrailleDisplayConnected.aiff") { Speech.player?.playBell(frequencies: [523, 659, 784], spacingMs: 80, ringMs: 220, volume: 0.22) } }
    public static func brailleDisconnected() { if !own { return }; if !voiceOver("BrailleDisplayDisconnected.aiff") { Speech.player?.playBell(frequencies: [784, 659, 523], spacingMs: 80, ringMs: 220, volume: 0.22) } }
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
    /// A progress bar's beep, NVDA's (ProgressOutput): 40 ms, 110 Hz at 0 percent, an octave higher each 25 percent,
    /// 1760 Hz at 100.
    public static func progress(_ percent: Int) { beep(progressFrequency(percent), 40) }
    package static func progressFrequency(_ percent: Int) -> Double { 110 * pow(2, Double(max(0, min(100, percent))) / 25) }
    /// Commented text in a document (Word): two quick notes.
    public static func comment() { if fresh("comment") { return }; beep(880, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { beep(1175, 35, volume: 0.18) } }
}
