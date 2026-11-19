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
    /// THE RULE (19 Nov 2026; SHORTCOMINGS rule 10; Oliver: "the VoiceOver sounds are not correct"). With VoiceOver's
    /// sounds chosen, TurnOver plays a sound only for an event VoiceOver plays one for, and plays VoiceOver's file for
    /// it; every tone TurnOver invented (focus tick, press, heading, list, landmark, table, graphic, block quote, focus
    /// and browse mode, comment, the keystroke beep, the jump beeps, the assorted beeps) is silent. With TurnOver's
    /// chosen, all play. Every invented tone asks here first. (`own` was always true once CoExist went, so they all
    /// played with VoiceOver's chosen.) Kept in both sets, outside this gate, because they are TurnOver's own
    /// lifecycle and tell a blind user which reader is running: startup, take-over, hand-back; and the progress beep.
    /// A test sets `inventedProbe`: the gate then records the name where it would have played, and plays nothing.
    nonisolated(unsafe) package static var inventedProbe: ((String) -> Void)?
    package static func invented(_ name: String) -> Bool {
        guard chosen else { return false }
        if let probe = inventedProbe { probe(name); return false }
        return true
    }
    /// THE LOW-LEVEL GATE (19 Nov 2026): Tones.beep, the bell and TurnOverSounds.play all refuse with VoiceOver's sounds
    /// chosen, whoever asks, unless the caller passes `exempt: true`. Exempt, and only these: the lifecycle sounds (startup,
    /// take-over, hand-back), the progress beep, the plain tones and TurnOver's files that stand in for a VoiceOver file
    /// (VoiceOverSounds.ownTone; the fallbacks of link, spelling, boundary, drill, braille and secure-field sounds), and
    /// a plugin script's own tone or sound, which its author asked for. With TurnOver's sounds chosen nothing is refused.
    /// A test sets `outputProbe`: what would be played is recorded and nothing is played.
    nonisolated(unsafe) package static var outputProbe: ((String) -> Void)?
    /// One of TurnOver's own set, where TurnOver's own may play: false leaves the old tone to play.
    private static func fresh(_ name: String, exempt: Bool = false, why: String = #function) -> Bool {
        guard own else { return false }
        return Thread.isMainThread ? MainActor.assumeIsolated { TurnOverSounds.play(name, exempt: exempt, why: why) } : false
    }
    /// A synthesised bell, logged as it plays (19 Nov 2026).
    package static func bell(frequencies: [Double], spacingMs: Int, ringMs: Int, volume: Float = 0.12, exempt: Bool = false, why: String = #function) {
        guard chosen || exempt else { return }
        if let probe = outputProbe { probe("bell"); return }
        SoundLog.played("bell \(frequencies.map { String(Int($0)) }.joined(separator: "+")) Hz", why: why)
        Speech.player?.playBell(frequencies: frequencies, spacingMs: spacingMs, ringMs: ringMs, volume: volume)
    }
    public static func beep(_ frequency: Double, _ ms: Int, volume: Float = 0.25, exempt: Bool = false, why: String = #function) {
        guard own, chosen || exempt else { return }
        if let probe = outputProbe { probe("tone"); return }
        SoundLog.played("tone \(Int(frequency)) Hz \(ms) ms", why: why)
        Speech.player?.playTone(frequency: frequency, durationMs: ms, volume: volume)
    }
    /// Headings: higher for level 1, descending by level.
    public static func heading(level: Int) { guard invented("heading") else { return }; if fresh("heading\(min(6, max(1, level)))") { return }; beep(level <= 0 ? 700 : max(440, 1000 - Double(level - 1) * 110), 60) }
    /// VoiceOver's own sound where it has one (17 Oct 2026), or the set's with TurnOver's chosen; false off the main
    /// thread or with neither file, so the old tone plays.
    private static func voiceOver(_ name: String, why: String = #function) -> Bool { Thread.isMainThread ? MainActor.assumeIsolated { VoiceOverSounds.play(name, why: why) } : false }
    /// 19 Nov 2026, like for like with VoiceOver's Sounds Help (its configuration maps each event to a file): a search
    /// that found nothing is "Search did not find anything", NotFound.aiff. TurnOver's set has no sound for it.
    public static func searchNotFound() { _ = voiceOver("NotFound.aiff") }
    /// A menu opening is "Menu or popup displayed", MenuDown.aiff. TurnOver's set has none for a menu opening.
    public static func menuOpened() { _ = voiceOver("MenuDown.aiff") }
    /// A context menu is a menu, so with VoiceOver's sounds it is MenuDown (menuOpened); PopupAppeared.aiff is VoiceOver's
    /// "Popover appeared". TurnOver's set keeps its popup sound for a context menu, as before.
    public static func contextMenuOpened() { if chosen { _ = voiceOver("PopupAppeared.aiff") } }
    /// A page finished loading: VoiceOver's "Web area loaded" event plays WebPageLoaded.aiff (WebAreaLoaded.aiff is not
    /// the file its configuration names for it).
    public static func pageLoaded() { _ = voiceOver("WebPageLoaded.aiff") }
    /// A mouse click on the item (VO-Shift-Space): VoiceOver's "Mouse click" event plays SingleClick.aiff; TurnOver's own
    /// set plays its press click, as it did before.
    public static func mouseClick() { if chosen { press() } else if config.general.navigationSounds { _ = voiceOver("SingleClick.aiff") } }
    /// The rotor moved to its previous or next setting: VoiceOver's RotorLeft.aiff or RotorRight.aiff. TurnOver's own set has none.
    public static func rotorMoved(forward: Bool) { if !chosen { _ = voiceOver(forward ? "RotorRight.aiff" : "RotorLeft.aiff") } }
    /// Find wrapped round the page: with VoiceOver's sounds WrapForward.aiff or WrapBack.aiff; TurnOver's own set keeps its edge sound.
    public static func searchWrapped(forward: Bool) {
        guard !chosen else { edge(); return }
        _ = voiceOver(forward ? "WrapForward.aiff" : "WrapBack.aiff")
        onEdge?()
    }
    /// A window became the front one, including on an app switch, but not the Finder's desktop: VoiceOver's "Window
    /// activated" plays WindowActivated.aiff. TurnOver's own set has none.
    public static func windowActivated() { if !chosen { _ = voiceOver("WindowActivated.aiff") } }
    /// A dialog or a system prompt appeared: VoiceOver's "System dialog appeared" plays Alert.aiff. TurnOver's own set has none.
    public static func dialogAppeared() { if !chosen { _ = voiceOver("Alert.aiff") } }
    /// Text was added to the selection: VoiceOver's "Text added to selection" plays DragShort.aiff. One sound per
    /// change however many pieces were added. TurnOver's own set has none.
    public static func selectionAdded() { if !chosen { _ = voiceOver("DragShort.aiff") } }
    public static func link() { if !voiceOver("LinkBegin.aiff") { beep(1400, 25, volume: 0.18, exempt: true) } }
    public static func list() { guard invented("list") else { return }; if fresh("list") { return }; beep(520, 40) }
    public static func landmark() { guard invented("landmark") else { return }; if fresh("landmark") { return }; beep(620, 40); DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { beep(780, 40) } }
    public static func table() { guard invented("table") else { return }; if fresh("table") { return }; beep(400, 50) }
    public static func graphic() { guard invented("graphic") else { return }; if fresh("graphic") { return }; beep(1100, 35, volume: 0.18) }
    public static func blockQuote() { guard invented("blockquote") else { return }; if fresh("blockquote") { return }; beep(560, 45) }
    public static func spellingError() { if !voiceOver("Misspelled.aiff") { beep(300, 70, exempt: true) } }
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
        if !voiceOver("WrapBoundary.aiff") { beep(220, 50, volume: 0.2, exempt: true) }
    }
    /// Taking over from VoiceOver: two bell notes a fifth apart, rising (G5, D6). Handing back: the same falling.
    /// Short and soft, as it is heard every time an application changes hands.
    /// TurnOver has started while VoiceOver has the Mac: a short rising pair, so a tester with Open at login knows it is
    /// there (NVDA's start-up sound; a tester, 9 Oct 2026). Speech would be silent with VoiceOver on; a tone is not.
    public static func startup() { if !own { return }; if fresh("startup", exempt: true) { return }; bell(frequencies: [659, 880], spacingMs: 90, ringMs: 160, volume: 0.18, exempt: true) }
    public static func takeOver() { if !own { return }; if fresh("take_over", exempt: true) { return }; bell(frequencies: [784, 1175], spacingMs: 70, ringMs: 150, exempt: true) }
    /// A braille display connected and gone: VoiceOver's sounds for them, or three notes up and three down.
    public static func brailleConnected() { if !own { return }; if !voiceOver("BrailleDisplayConnected.aiff") { bell(frequencies: [523, 659, 784], spacingMs: 80, ringMs: 220, volume: 0.22, exempt: true) } }
    public static func brailleDisconnected() { if !own { return }; if !voiceOver("BrailleDisplayDisconnected.aiff") { bell(frequencies: [784, 659, 523], spacingMs: 80, ringMs: 220, volume: 0.22, exempt: true) } }
    public static func handBack() { if !own { return }; if fresh("hand_back", exempt: true) { return }; bell(frequencies: [1175, 784], spacingMs: 70, ringMs: 150, exempt: true) }
    /// The focus moved (Tab, a new control): VoiceOver's little tick. Very short, high and quiet.
    public static func focusTick() {
        guard invented("focus_tick") else { return }
        guard config.general.navigationSounds else { return }
        if Date().timeIntervalSince(lastTick) < 0.05 { return }   // a burst of focus events is one move
        lastTick = Date()
        if fresh("tick") { return }
        bell(frequencies: [2600], spacingMs: 0, ringMs: 18, volume: 0.07)
    }
    private static var lastTick = Date.distantPast
    /// An item was pressed (a link followed, a button pressed): a fuller click, lower, two partials together.
    /// With VoiceOver's sounds chosen (19 Nov 2026, second pass) it is VoiceOver's "Select" file, the sound it plays when
    /// an item is activated; TurnOver's own set plays its own click as before.
    public static func press() {
        guard config.general.navigationSounds else { return }
        guard chosen else { _ = voiceOver("Select.aiff"); return }
        guard invented("press") else { return }
        if fresh("press") { return }
        bell(frequencies: [1300, 1950], spacingMs: 6, ringMs: 35, volume: 0.09)
    }
    /// Into focus mode (typing into the page): two notes rising. Back to browse mode: the same falling. NVDA's
    /// "audio indication of focus and browse modes".
    // (The browse and focus mode tones are TurnOver's own idea, NVDA's: VoiceOver plays nothing when a field takes the
    // focus, so its Quick Nav sounds were wrong here: every return to Claude played "Quick Nav off", 17 Oct 2026.)
    public static func focusMode() { guard invented("focus_mode") else { return }; if fresh("focus_mode") { return }; beep(523, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { beep(784, 45, volume: 0.18) } }
    public static func browseMode() { guard invented("browse_mode") else { return }; if fresh("browse_mode") { return }; beep(784, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.045) { beep(523, 45, volume: 0.18) } }
    /// A progress bar's beep, NVDA's (ProgressOutput): 40 ms, 110 Hz at 0 percent, an octave higher each 25 percent,
    /// 1760 Hz at 100.
    public static func progress(_ percent: Int) { beep(progressFrequency(percent), 40, exempt: true) }
    package static func progressFrequency(_ percent: Int) -> Double { 110 * pow(2, Double(max(0, min(100, percent))) / 25) }
    /// The sound of "Mark a problem" (the marked file of TurnOver's set, else a plain tone): invented, so silent with VoiceOver's sounds.
    public static func marked() { guard invented("marked") else { return }; if fresh("marked") { return }; beep(660, 60, volume: 0.2) }
    /// An app finished installing in the App Store window: invented.
    public static func installed() { guard invented("installed") else { return }; beep(880, 80) }
    /// A beep each second while something is gathered or an AI is asked: invented.
    public static func waitingTick() { guard invented("waiting_tick") else { return }; beep(880, 30, volume: 0.1) }
    /// Commented text in a document (Word): two quick notes.
    public static func comment() { guard invented("comment") else { return }; if fresh("comment") { return }; beep(880, 35, volume: 0.18); DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { beep(1175, 35, volume: 0.18) } }
}
