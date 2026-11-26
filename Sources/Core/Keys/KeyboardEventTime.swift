// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// HID callbacks supply Mach ticks. Quartz documents nanoseconds, but a live
/// HID event tap on Apple silicon also delivered Mach ticks (November 2026).
/// Tap events are recent. Interpret the stamp in the domain closest to uptime,
/// without rewriting the event that will be delivered to another application.
nonisolated public enum KeyboardEventTime {
    private static let timebase: (numerator: UInt64, denominator: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        scale(ticks, by: timebase.numerator, over: timebase.denominator)
    }

    public static func quartzNanoseconds(_ timestamp: UInt64, uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        let converted = nanoseconds(timestamp)
        return usesMachTicks(timestamp, converted: converted, uptime: uptime) ? converted : timestamp
    }

    /// KeyboardGesture and FindPrompt use Mach ticks.
    public static func quartzTicks(_ timestamp: UInt64, uptime: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        let converted = nanoseconds(timestamp)
        return usesMachTicks(timestamp, converted: converted, uptime: uptime)
            ? timestamp : scale(timestamp, by: timebase.denominator, over: timebase.numerator)
    }

    private static func usesMachTicks(_ raw: UInt64, converted: UInt64, uptime: UInt64) -> Bool {
        func distance(_ value: UInt64) -> UInt64 {
            value > uptime ? value - uptime : uptime - value
        }
        return distance(converted) < distance(raw)
    }

    private static func scale(_ value: UInt64, by multiplier: UInt64, over divisor: UInt64) -> UInt64 {
        let product = value.multipliedFullWidth(by: multiplier)
        guard product.high < divisor else { return .max }
        return divisor.dividingFullWidth(product).quotient
    }
}
