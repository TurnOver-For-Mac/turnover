// SPDX-License-Identifier: GPL-3.0-or-later
// Braille through macOS's own display drivers (TOAppleBraille, in TurnOverBraille): every display VoiceOver supports,
// recognised by itself. Keys come back as numbers; the model's own key table (Apple's, beside the driver) says
// what VoiceOver does with each, and TurnOver does the NVDA equivalent (Braille.keyMap).
import Foundation
import TurnOverBraille

final class AppleBrailleDriver: BrailleDisplayDriver {
    let display: TOAppleBrailleDisplay
    var name: String { display.modelIdentifier.components(separatedBy: ".").suffix(3).joined(separator: " ") }
    var cellCount: Int { display.cellCount }
    private var closed = false
    var onLost: (() -> Void)?

    init(_ display: TOAppleBrailleDisplay) {
        self.display = display
        Log.info("braille: Apple's \(display.driverName) driver for \(display.modelIdentifier), \(display.cellCount) cells, \(display.keyCommands.count) keys in its table")
        // The drivers are polled for keys, as VoiceOver does, on the braille thread: a USB driver waits on each read,
        // and polled from the main thread it held TurnOver up most of the time (21 Oct 2026).
        display.startPolling { [weak self] events, loaded in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                for e in events { self.handle(e.intValue) }
                if !loaded { Log.info("braille: \(self.name) disconnected"); self.close(); self.onLost?() }
            }
        }
    }

    /// Writes the display turns down in a row: a Bluetooth link that has gone quiet (the display switched to USB, or
    /// out of range) still says it is loaded, so this is how it is noticed.
    private var failedWrites = 0
    func write(_ cells: [UInt8]) {
        display.writeCellsAsync(Data(cells)) { [weak self] ok in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if ok { self.failedWrites = 0; return }
                self.failedWrites += 1
                if self.failedWrites >= 3 { Log.info("braille: \(self.name) stopped taking cells"); self.close(); self.onLost?() }
            }
        }
    }

    func close() {
        closed = true
        repeatTimer?.invalidate(); repeatTimer = nil; repeating = false   // (a held dot 7 kept deleting after the display went, 8 Oct 2026)
        display.close()
    }

    /// The braille keyboard's keys held now, and all held since the chord began (kind 2: keys 0 to 7 are dots 1 to 8,
    /// measured on the VarioUltra; anything above is a space key).
    private var held = Set<Int>(), chord = Set<Int>()
    /// When the chord's last dot went down, when space went down, and whether a dot was let go before space: how a
    /// space pressed late, while typing, is told from a command (BrailleInput.chord).
    private var lastDotDown: Date?, spaceDown: Date?, dotLetGoBeforeSpace = false
    private var repeatTimer: Timer?
    private var repeating = false

    private func handle(_ v: Int) {
        let pressed = v & 0x10000 != 0, kind = v & 0xFF, key = (v >> 8) & 0xFF
        if kind == 2 {
            if pressed {
                if key < 8 { lastDotDown = Date() } else if spaceDown == nil { spaceDown = Date() }
                held.insert(key); chord.insert(key)
            } else {
                if key < 8, spaceDown == nil, !chord.contains(where: { $0 >= 8 }) { dotLetGoBeforeSpace = true }
                held.remove(key)
            }
            // Dot 7 held alone repeats Backspace, as a held key does (after half a second, then ten a second).
            repeatTimer?.invalidate(); repeatTimer = nil
            if pressed, held == [6], chord == [6] {
                repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in MainActor.assumeIsolated {
                    guard let self else { return }
                    self.repeating = true
                    BrailleInput.chord(dots: [7], space: false)
                    self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in MainActor.assumeIsolated { BrailleInput.chord(dots: [7], space: false) } }
                } }
            }
            if held.isEmpty, repeating { repeating = false; chord.removeAll(); return }
            if held.isEmpty, !chord.isEmpty {
                let dots = Set(chord.filter { $0 < 8 }.map { $0 + 1 })
                let space = chord.contains { $0 >= 8 }
                // Space down well after the dots, or a dot already let go: typing, not a command.
                var late = false
                if space, !dots.isEmpty, let s = spaceDown, let d = lastDotDown {
                    let gap = s.timeIntervalSince(d)
                    late = dotLetGoBeforeSpace || gap > BrailleInput.lateSpaceSeconds
                    Log.io("braille: space key \(chord.filter { $0 >= 8 }), \(Int(gap * 1000)) ms after the last dot\(dotLetGoBeforeSpace ? ", a dot let go first" : "")")
                } else if chord.contains(where: { $0 >= 8 }) { Log.io("braille: space key \(chord.filter { $0 >= 8 })") }
                chord.removeAll(); lastDotDown = nil; spaceDown = nil; dotLetGoBeforeSpace = false
                BrailleInput.chord(dots: dots, space: space, spaceLate: late)
            }
            return
        }
        guard pressed else { return }
        switch kind {
        case 0: Braille.handle(.routing(key))
        case 3: break   // status cells' routing keys: nothing on them yet
        default:
            if let command = display.keyCommands[NSNumber(value: v)] { Braille.handle(.key(command)) }
            else { Braille.handle(.key(kind == 2 ? "brailleKeyboard\(key)" : "key\(kind).\(key)")) }
        }
    }
}
