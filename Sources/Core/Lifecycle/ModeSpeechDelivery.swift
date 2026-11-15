// SPDX-License-Identifier: GPL-3.0-or-later
// 14 Nov 2026: the executable and tests share the entire delayed delivery loop. A changed
// foreground owner or readiness restarts the settling delay, within the original ceiling.
@MainActor public final class ModeSpeechDelivery {
    public init() {}
    public func announce(_ text: String, now: @escaping () -> Double,
                         schedule: @escaping (Double, @escaping @MainActor () -> Void) -> Void,
                         current: @escaping () -> Bool,
                         readyReader: @escaping () -> ModeSpeechPolicy.Reader?,
                         output: @escaping (String, ModeSpeechPolicy.Reader) -> Void) {
        let end = now() + 16
        func check(_ settled: ModeSpeechPolicy.Reader? = nil) {
            guard current(), now() < end else { return }
            if let reader = readyReader() {
                if reader == settled { output(text, reader); return }
                schedule(0.4) { check(reader) }
            } else {
                schedule(0.1) { check() }
            }
        }
        check()
    }
}
