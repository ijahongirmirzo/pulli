public import Foundation
public import PulliProtocol
public import SwiftUI
public import WidgetKit

/// Colours and formatting for Pulli's desktop widgets, matching the app's Porcelain theme.
public enum WidgetTheme {
    /// Warm porcelain surface in light appearance, deep slate in dark.
    public static func surface(dark: Bool) -> Color {
        dark ? Color(hex: 0x1C1D24) : Color(hex: 0xF6F4F0)
    }

    /// Primary text ink: dark in light mode, bright in dark mode.
    public static func textPrimary(dark: Bool) -> Color {
        dark ? Color(hex: 0xF3F3F6) : Color(hex: 0x1A1A1F)
    }

    /// Secondary text ink for labels and subtitles.
    public static func textSecondary(dark: Bool) -> Color {
        dark ? Color(hex: 0xA9AAB8) : Color(hex: 0x5B5B66)
    }

    /// Accent ink blue: #3557E0 in light mode, #7C93F7 in dark mode.
    public static func accent(dark: Bool) -> Color {
        dark ? Color(hex: 0x7C93F7) : Color(hex: 0x3557E0)
    }

    /// Amber cable hint pill fill.
    public static func hintFill(dark: Bool) -> Color {
        dark ? Color(hex: 0x412402) : Color(hex: 0xFAEEDA)
    }

    /// Amber cable hint pill text.
    public static func hintText(dark: Bool) -> Color {
        dark ? Color(hex: 0xFAC775) : Color(hex: 0x854F0B)
    }

    /// Subtle quiet pill background.
    public static func quietFill(dark: Bool) -> Color {
        dark ? Color(hex: 0x2C2E3A) : Color(hex: 0xE9E6DF)
    }

    /// Progress bar track background.
    public static func track(dark: Bool) -> Color {
        dark ? Color(hex: 0x30323F) : Color(hex: 0xE3E0D9)
    }

    /// Amber fill for paused copies.
    public static let pausedAmber = Color(hex: 0xEF9F27)

    /// Formats a relative day: "today", "yesterday", or date like "14 Oct".
    public static func relativeDay(for date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) {
            return "today"
        } else if calendar.isDateInYesterday(date) {
            return "yesterday"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    /// Formats progress bytes: "3.4 of 5.6 GB" or "150 of 500 MB".
    public static func bytesProgress(done: UInt64, total: UInt64) -> String {
        let gigabyte: Double = 1_000_000_000
        let megabyte: Double = 1_000_000
        if total >= 1_000_000_000 {
            let totalGB = Double(total) / gigabyte
            let doneGB = Double(done) / gigabyte
            let totalStr = String(format: "%.1f GB", totalGB)
            if done >= 100_000_000 {
                let doneStr = String(format: "%.1f", doneGB)
                return "\(doneStr) of \(totalStr)"
            } else if done > 0 {
                let doneMB = Double(done) / megabyte
                let doneStr = String(format: "%.0f MB", doneMB)
                return "\(doneStr) of \(totalStr)"
            } else {
                return "0 of \(totalStr)"
            }
        } else if total >= 1_000_000 {
            let totalMB = Double(total) / megabyte
            let doneMB = Double(done) / megabyte
            let totalStr = String(format: "%.0f MB", totalMB)
            let doneStr = String(format: "%.0f", doneMB)
            return "\(doneStr) of \(totalStr)"
        } else {
            return "\(done) of \(total) B"
        }
    }

    /// Right-aligned detail for a copy row: "3.4 of 5.6 GB · 23 s left", "paused", or "next".
    public static func copyDetail(_ copy: WidgetSnapshot.Copy) -> String {
        switch copy.tint {
        case .paused:
            return "paused"
        case .waiting:
            return "next"
        case .done:
            return "done"
        case .copying:
            if let done = copy.bytesDone, let total = copy.bytesTotal, total > 0 {
                let progress = bytesProgress(done: done, total: total)
                if !copy.detail.isEmpty && copy.detail != "copying" {
                    return "\(progress) · \(copy.detail)"
                }
                return progress
            }
            return copy.detail
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
