// SPDX-License-Identifier: GPL-3.0-or-later
// Bass, middle and treble for every voice, the Mac's and the natural ones alike (Oliver, 2 Nov 2026: "rate, volume,
// and the eq should be specific to each voice"): a low shelf at 250 Hz, a peak at 2.5 kHz and a high shelf at 6 kHz,
// the usual biquads (Robert Bristow-Johnson's audio EQ cookbook), run on each utterance's buffers before the volume.
// Lowered first by the largest boost, so a boost doesn't clip. Flat, it does nothing.
import AVFoundation

package struct SpeechEQ {
    private struct Biquad {
        let b0, b1, b2, a1, a2: Float
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        mutating func run(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }
    private var bands: [Biquad] = []
    private let headroom: Float

    /// `gains`: bass, middle and treble in decibels, -12 to 12.
    package init(_ gains: [Float], sampleRate: Double) {
        let kinds: [(Double, Int)] = [(250, -1), (2500, 0), (6000, 1)]   // low shelf, peak, high shelf
        for (g, (f, kind)) in zip(gains, kinds) where abs(g) >= 0.5 { bands.append(Self.band(f, gain: Double(g), kind: kind, rate: sampleRate)) }
        headroom = Float(pow(10, -Double(max(0, gains.max() ?? 0)) / 20))
    }

    package var isFlat: Bool { bands.isEmpty }

    private static func band(_ f: Double, gain: Double, kind: Int, rate: Double) -> Biquad {
        let a = pow(10, gain / 40), w = 2 * Double.pi * f / rate, c = cos(w), sn = sin(w)
        let b0, b1, b2, a0, a1, a2: Double
        if kind == 0 {
            let alpha = sn / 2   // a Q of 1
            b0 = 1 + alpha * a; b1 = -2 * c; b2 = 1 - alpha * a; a0 = 1 + alpha / a; a1 = -2 * c; a2 = 1 - alpha / a
        } else {
            let k = 2 * sqrt(a) * sn / 2 * sqrt(2.0)   // a shelf slope of 1
            let s: Double = kind < 0 ? 1 : -1   // the cookbook's two shelves in one: +1 low, -1 high
            b0 = a * ((a + 1) - s * (a - 1) * c + k); b1 = s * 2 * a * ((a - 1) - s * (a + 1) * c); b2 = a * ((a + 1) - s * (a - 1) * c - k)
            a0 = (a + 1) + s * (a - 1) * c + k; a1 = -s * 2 * ((a - 1) + s * (a + 1) * c); a2 = (a + 1) + s * (a - 1) * c - k
        }
        return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0))
    }

    /// One buffer of the utterance, in place; the filters carry on from the last, so there is no click between them.
    /// The player's format is mono, so the first channel is the sound.
    package mutating func run(_ b: AVAudioPCMBuffer) {
        guard !bands.isEmpty, let p = b.floatChannelData?[0] else { return }
        for i in 0..<Int(b.frameLength) {
            var x = p[i] * headroom
            for k in bands.indices { x = bands[k].run(x) }
            p[i] = x
        }
    }
}
