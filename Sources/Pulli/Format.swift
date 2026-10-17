import Foundation
import PulliProtocol

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        let megabytes = bytesPerSecond / 1_000_000
        return megabytes >= 10 ? String(format: "%.0f MB/s", megabytes) : String(format: "%.1f MB/s", megabytes)
    }

    /// "23 s", "4 min", "1 h 20 min".
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(max(total, 1)) s" }
        let minutes = Int((Double(total) / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func about(_ seconds: Double) -> String { "about \(duration(seconds))" }

    static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value.formatted()) \(value == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func link(_ link: LinkSpeed) -> String {
        switch link {
        case .usb1: "USB 1"
        case .usb2: "USB 2"
        case .usb3: "USB 3"
        case .unknown: "USB"
        }
    }

    /// "Downloads › myGalaxy" for a folder under the home folder.
    static func place(_ path: String) -> String {
        let home = NSHomeDirectory()
        var shown = path
        if shown.hasPrefix(home + "/") { shown = String(shown.dropFirst(home.count + 1)) }
        else if shown.hasPrefix("/Volumes/") { shown = String(shown.dropFirst("/Volumes/".count)) }
        return shown.split(separator: "/").suffix(3).joined(separator: " › ")
    }

    /// One formatter for every row (creating a DateFormatter is expensive).
    private nonisolated(unsafe) static let phoneDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // The phone's wall clock is encoded as UTC (docs/DECISIONS.md): show it as-is.
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d MMM yyyy, HH:mm"
        return formatter
    }()

    static func phoneDate(_ wallClock: Int64) -> String {
        phoneDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(wallClock)))
    }

    static func relativeDay(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
