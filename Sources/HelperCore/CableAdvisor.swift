import Foundation
public import PulliProtocol

/// Decides what to tell the user about their cable, and how fast a copy will go.
///
/// Speeds are measured per phone and link once a copy has run (the helper records them); until
/// then typical MTP figures are used: about 30 MB/s on USB 2 (a Galaxy Z Fold7 measured 29-32 MB/s)
/// and a conservative 90 MB/s on USB 3 (MTP overhead keeps phones well below the 5 Gb/s line rate).
public enum CableAdvisor {
    static let typicalBytesPerSecond: [LinkSpeed: Double] = [
        .usb1: 0.9e6, .usb2: 30e6, .usb3: 90e6, .unknown: 30e6,
    ]

    /// The fastest link a phone model supports, from manufacturer spec sheets. Only models we are
    /// sure of; unknown models return nil and the advice stays tentative.
    public static func phoneSupports(model: String?) -> LinkSpeed? {
        guard let model = model?.uppercased() else { return nil }
        // Samsung (model numbers): Galaxy Z Fold7 (verified on a device, 2026-09-27) and the S22-S25
        // Ultra line have USB 3.2 Gen 1; the Galaxy A line has USB 2.0.
        let usb3Prefixes = ["SM-F966", "SM-S908", "SM-S918", "SM-S928", "SM-S938"]
        if usb3Prefixes.contains(where: model.hasPrefix) { return .usb3 }
        // Some phones report their marketing name instead of the model number.
        if model.contains("Z FOLD7") || model.range(of: #"S2[2-5] ULTRA"#, options: .regularExpression) != nil { return .usb3 }
        if model.hasPrefix("SM-A") { return .usb2 }
        // Google Pixel 6 and later have USB 3.2.
        if let range = model.range(of: #"PIXEL (\d+)"#, options: .regularExpression),
           let number = Int(model[range].split(separator: " ").last ?? ""), number >= 6 {
            return .usb3
        }
        return nil
    }

    public static func advice(link: LinkSpeed, throughHub: Bool, model: String?,
                              measured: (LinkSpeed) -> Double?) -> CableAdvice {
        let supports = phoneSupports(model: model)
        let suggestion: CableAdvice.Suggestion = switch link {
        case .usb3:
            .none
        case .usb1, .usb2, .unknown:
            if supports == .usb2 && !throughHub { .none }
            else if throughHub { .plugDirectly }
            else if supports == .usb3 { .useUSB3Cable }
            else { .mayBeFaster }
        }
        let now = measured(link) ?? typicalBytesPerSecond[link] ?? 30e6
        var faster: Double?
        if suggestion != .none, supports != .usb2 {
            faster = measured(.usb3) ?? typicalBytesPerSecond[.usb3]
        } else if suggestion == .plugDirectly {
            // A USB 2 phone behind a hub gains a little from a direct port, not a new cable.
            faster = nil
        }
        return CableAdvice(link: link, phoneSupports: supports, throughHub: throughHub, suggestion: suggestion,
                           bytesPerSecond: now, fasterBytesPerSecond: faster.flatMap { $0 > now * 1.2 ? $0 : nil },
                           measured: measured(link) != nil)
    }
}
