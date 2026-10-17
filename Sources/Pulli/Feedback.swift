import AppKit
import Foundation
import PulliProtocol

/// A feedback email draft ready to open in the user's default email client.
struct FeedbackDraft: Equatable, Sendable {
    var subject: String
    var body: String
    var url: URL
}

/// Pre-fills an email draft with diagnostics for bug reports and suggestions.
@MainActor
enum Feedback {
    /// The recipient address configured for this build, or empty if none.
    static var email: String? {
        Bundle.main.infoDictionary?["PulliFeedbackEmail"] as? String
    }

    /// Whether the feedback menu item should be shown.
    static var isAvailable: Bool {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !email.isEmpty
    }

    /// The hardware model identifier (e.g. "Mac17,3"), or "Unknown".
    static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 1 else { return "Unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let trimmed = buffer.prefix(while: { $0 != 0 })
        return String(decoding: trimmed, as: UTF8.self)
    }

    /// Builds a mailto URL with a blank report section and diagnostics.
    nonisolated static func buildDraft(
        email: String?,
        shortVersion: String,
        build: String,
        commit: String?,
        osVersion: String,
        macModel: String,
        device: DeviceSnapshot?,
        helperEnabled: Bool
    ) -> FeedbackDraft? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty else {
            return nil
        }

        let subject = "Pulli feedback – \(shortVersion) (\(build))"
        let phoneSummary: String
        if let device {
            let maker = device.manufacturer ?? ""
            let model = device.model ?? "Android phone"  // never the phone's own name: it can be a person's
            let name = [maker, model].filter { !$0.isEmpty }.joined(separator: " ")
            let link = Format.link(device.link)
            phoneSummary = "\(name), \(link)"
        } else {
            phoneSummary = "None"
        }

        let commitSuffix = commit.map { " (\($0))" } ?? ""
        let body = """
        What happened?



        ---
        About this Mac:
        Pulli: \(shortVersion) (\(build))\(commitSuffix)
        macOS: \(osVersion)
        Mac model: \(macModel)
        Connected phone: \(phoneSummary)
        Background helper: \(helperEnabled ? "On" : "Off")
        """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body),
        ]

        guard let url = components.url else { return nil }
        return FeedbackDraft(subject: subject, body: body, url: url)
    }

    /// Opens the feedback draft in the system default mail application.
    static func open(model: AppModel?) {
        guard let draft = buildDraft(
            email: email,
            shortVersion: PulliProtocolVersion.shortVersion,
            build: PulliProtocolVersion.buildVersion,
            commit: PulliProtocolVersion.commit,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            macModel: macModel,
            device: model?.device,
            helperEnabled: HelperRegistration.isEnabled
        ) else { return }

        NSWorkspace.shared.open(draft.url)
    }
}
