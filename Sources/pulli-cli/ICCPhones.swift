import ArgumentParser
import DeviceAPI
import Foundation
import ICCKit
import MTPKit

/// Which code talks to the phone: libmtp (every file), or Apple's ImageCaptureCore (photos and
/// videos, through macOS's camera service: the App Store edition's backend).
enum PhoneBackendChoice: String, ExpressibleByArgument, CaseIterable {
    case libmtp
    case icc
}

struct BackendOption: ParsableArguments {
    @Option(help: "Phone backend: libmtp (default) or icc (ImageCaptureCore; the phone must be in \"Transferring images\" mode).")
    var backend: PhoneBackendChoice = .libmtp
}

/// Finding and opening a phone through ImageCaptureCore, with the guidance a user needs.
enum ICCPhones {
    /// A connector whose dates use the Mac's real time zone (this process runs in UTC for libmtp).
    static func connector() -> ICCDeviceConnector {
        ICCDeviceConnector(timeZone: MTPLibrary.systemTimeZone)
    }

    /// Opens the phone (`serial`: its USB serial or part of its name, when several are attached),
    /// waiting while it shows no photos (asks for "Transferring images") or is briefly away.
    static func open(_ connector: ICCDeviceConnector, serial: String?) async throws -> any DeviceSession {
        let phones = await connector.browser.waitForCameras(timeout: .seconds(10), phonesOnly: true)
        let matching = phones.filter { phone in
            guard let serial else { return true }
            return phone.usb.usbSerial == serial || phone.key?.serial == serial || (phone.name ?? "").localizedCaseInsensitiveContains(serial)
        }
        guard let phone = matching.first else {
            throw CLIError(phones.isEmpty ? ICCGuidance.noPhone
                           : "No phone matches \(serial ?? ""). Found: " + phones.map { "\($0.name ?? "phone") (\($0.key?.serial ?? "no serial"))" }.joined(separator: ", "))
        }
        if matching.count > 1 { Log.note("Several phones are connected; using \(phone.name ?? "the first") (choose with --device).") }
        guard let key = phone.key else { throw CLIError("ImageCaptureCore gives no identity for \(phone.name ?? "this phone").") }
        Log.note("Opening \(phone.name ?? "the phone") through ImageCaptureCore…")

        let start = ContinuousClock.now
        var schedule = BackoffSchedule()
        var told = false
        while true {
            do {
                return try await connector.open(key)
            } catch {
                switch error {
                case .noStorage:
                    if !told { Log.note(ICCGuidance.chooseTransferringImages) }
                    told = true
                    guard ContinuousClock.now - start < BackoffSchedule.userTimeout else { throw CLIError(ICCGuidance.chooseTransferringImages) }
                    try await Task.sleep(for: BackoffSchedule.userPollInterval)
                case .deviceGone, .transient:
                    // Switching USB mode replugs the phone; wait for it to come back.
                    guard ContinuousClock.now - start < BackoffSchedule.userTimeout else { throw CLIError(Phones.guidance(for: error)) }
                    try await Task.sleep(for: schedule.next() ?? BackoffSchedule.maxDelay)
                default:
                    throw CLIError(Phones.guidance(for: error))
                }
            }
        }
    }
}
