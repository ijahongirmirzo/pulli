import AppIntents
import AppKit
import Foundation
import PulliProtocol

// Shortcuts support (owner request, 2026-09-27): actions in the Shortcuts app, and pulli:// links
// that do the same (usable from Shortcuts' "Open URLs", scripts and other apps; accepts relay:// too).
//
//   pulli://copy-new       copy new photos and videos from the connected phone
//   pulli://storage-map    show the storage map
//   pulli://open           bring Pulli to the front

/// Copies what is new on the phone since the last copy (or the whole camera roll the first time).
struct CopyNewPhotosIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy New Photos from Phone"
    static let description = IntentDescription("Copies the photos and videos taken since Pulli's last copy from the connected Android phone to your Mac.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppDelegate.model else { throw PulliIntentError.notRunning }
        let result = try await model.copyNewForShortcut()
        return .result(value: result, dialog: IntentDialog(stringLiteral: result))
    }
}

/// What Pulli sees: the phone, its connection and running copies.
struct PhoneStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Phone Status"
    static let description = IntentDescription("Tells which Android phone is connected, at what USB speed, and how copies are going.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let model = AppDelegate.model else { throw PulliIntentError.notRunning }
        let status = model.statusForShortcut()
        return .result(value: status, dialog: IntentDialog(stringLiteral: status))
    }
}

struct OpenStorageMapIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Phone Storage Map"
    static let description = IntentDescription("Opens Pulli's map of what fills the connected phone.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.model?.handle(url: URL(string: "pulli://storage-map")!)
        return .result()
    }
}

enum PulliIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning
    case noPhone
    case nothingNew

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Pulli is not ready yet. Open Pulli and try again."
        case .noPhone: "No Android phone is connected. Plug it in and unlock it."
        case .nothingNew: "Nothing new on the phone since the last copy."
        }
    }
}

struct PulliShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CopyNewPhotosIntent(), phrases: ["Copy new photos with \(.applicationName)", "Back up my phone with \(.applicationName)"],
                    shortTitle: "Copy New Photos", systemImageName: "arrow.down.to.line.circle")
        AppShortcut(intent: PhoneStatusIntent(), phrases: ["Phone status in \(.applicationName)"],
                    shortTitle: "Phone Status", systemImageName: "iphone.gen3")
        AppShortcut(intent: OpenStorageMapIntent(), phrases: ["Show phone storage in \(.applicationName)"],
                    shortTitle: "Storage Map", systemImageName: "square.grid.3x3.square")
    }
}

extension AppModel {
    /// For the Copy New Photos action: waits (up to 30 s) for a phone and its summary.
    func copyNewForShortcut() async throws -> String {
        await start()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let device, device.state == .ready, summaries[device.id] != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard let device, let summary = summaries[device.id] else { throw PulliIntentError.noPhone }
        if summary.cameraMark != nil {
            guard !summary.newItems.isEmpty else { throw PulliIntentError.nothingNew }
            picks = [.new]
        } else {
            picks = [.camera]
        }
        let picked = pickedItems()
        await copyPicks()
        return "Copying \(Format.count(picked.count, "item")) (\(Format.bytes(picked.bytes))) from \(device.name) to \(Format.place(destination))."
    }

    func statusForShortcut() -> String {
        guard let device else { return "No Android phone is connected." }
        var parts = ["\(device.name) is connected at \(Format.link(device.link))."]
        let running = state.batches.values.filter { $0.phase == .copying || $0.phase == .scanning }
        if running.isEmpty {
            parts.append("No copies running.")
        } else {
            for batch in running {
                parts.append("\(batch.title): \(Int((batch.fractionDone * 100).rounded()))%\(batch.secondsRemaining.map { ", \(Format.duration($0)) left" } ?? "").")
            }
        }
        return parts.joined(separator: " ")
    }

    /// pulli:// and legacy relay:// links (Shortcuts, scripts, other apps).
    func handle(url: URL) {
        guard url.scheme == "pulli" || url.scheme == "relay" else { return }
        switch url.host {
        case "copy-new": Task { _ = try? await copyNewForShortcut() }
        case "storage-map":
            show(.phone)
            if device?.state == .ready { openStorageMap() }
        case "open":
            NSApp.activate(ignoringOtherApps: true)
        default: break
        }
    }
}
