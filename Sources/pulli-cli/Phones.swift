import ArgumentParser
import DeviceAPI
import Foundation
import MTPKit
import USBKit
import WorkerIPC

/// The outcome of evaluating an error when opening a phone.
enum OpenDecision: Equatable, Sendable {
    case retry
    case waitForUser(String)
    case fail(String)
}

/// The retry backoff sequence when a phone is resetting or busy.
struct BackoffSchedule: Sequence, IteratorProtocol, Sendable {
    private(set) var attempt = 0
    static let initialDelay: Duration = .milliseconds(500)
    static let maxDelay: Duration = .seconds(8)
    static let retryTimeout: Duration = .seconds(45)
    static let userPollInterval: Duration = .seconds(2)
    static let userTimeout: Duration = .seconds(120)

    mutating func next() -> Duration? {
        defer { attempt += 1 }
        return Self.delay(forAttempt: attempt)
    }

    static func delay(forAttempt attempt: Int) -> Duration {
        switch attempt {
        case 0: .milliseconds(500)
        case 1: .seconds(1)
        case 2: .seconds(2)
        case 3: .seconds(4)
        default: .seconds(8)
        }
    }
}

/// Finding phones and opening sessions, with the guidance a user needs when that fails.
enum Phones {
    static var androidVendors: [UInt16: String] { USBRegistry.androidVendors }

    struct Candidate {
        var record: USBDeviceRecord
        /// libmtp recognised it (known device or MTP descriptor probe).
        var listedByLibmtp: Bool

        var isPhone: Bool {
            listedByLibmtp || record.hasMTPInterface || Phones.androidVendors[record.summary.vendorID] != nil
        }
    }

    static func candidates() async -> [Candidate] {
        let raw = (try? await MTPLibrary.detectRawDevices()) ?? []
        return USBRegistry.devices().map { record in
            Candidate(record: record, listedByLibmtp: raw.contains {
                $0.busLocation == record.summary.busNumber && $0.deviceNumber == record.summary.address
            })
        }.filter(\.isPhone)
    }

    static func select(serial: String?) async throws -> USBDeviceRecord {
        let phones = await candidates()
        if let serial {
            guard let match = phones.first(where: { $0.record.summary.usbSerial == serial }) else {
                throw ValidationError("No phone with USB serial \(serial). Run `pulli-cli devices`.")
            }
            return match.record
        }
        switch phones.count {
        case 0: throw CLIError("No Android phone found. Plug it in with a data cable and unlock it.")
        case 1: return phones[0].record
        default: throw ValidationError("Several phones are connected; choose one with --device <serial>.")
        }
    }

    /// Evaluates whether an error opening the phone can be retried or needs user action.
    static func classify(
        _ error: any Error,
        reportOnly: Bool = false,
        workerOwner: (Int32) -> OwnWorkers.Owner = { OwnWorkers.owner(of: $0) }
    ) -> OpenDecision {
        guard let deviceError = error as? DeviceError else {
            return .fail(guidance(for: error))
        }
        return classify(deviceError, reportOnly: reportOnly, workerOwner: workerOwner)
    }

    /// Pure classification of a `DeviceError` when opening a phone.
    static func classify(
        _ error: DeviceError,
        reportOnly: Bool = false,
        workerOwner: (Int32) -> OwnWorkers.Owner = { OwnWorkers.owner(of: $0) }
    ) -> OpenDecision {
        switch error {
        case .deviceGone, .transient:
            return .retry

        case .contended(let holder):
            switch holder {
            case .process(_, let name) where SystemCameraDaemons.isSystemCameraDaemonName(name):
                return reportOnly ? .fail(guidance(for: error)) : .retry

            case .process(let pid, let name) where OwnWorkers.isOwnWorker(name):
                switch workerOwner(pid) {
                case .orphan:
                    return .retry
                case .thisEngine, .backgroundHelper, .otherPulli:
                    return .fail("Pulli is using the phone. Quit Pulli or pause its copy, then try again.")
                }

            default:
                return .fail(guidance(for: error))
            }

        case .noStorage:
            return .waitForUser(guidance(for: .noStorage))

        case .noMTPInterface:
            return .waitForUser(guidance(for: .noMTPInterface))

        default:
            return .fail(guidance(for: error))
        }
    }

    /// Opens a direct MTP session, retrying with backoff if the phone is resetting or held by ptpcamerad/leftover workers.
    static func open(
        _ record: USBDeviceRecord,
        options: PhoneOptions
    ) async throws -> MTPSession {
        try await openSession(initialRecord: record, options: options, workerConnector: nil) as! MTPSession
    }

    /// Opens a direct MTP session, selecting the phone first and retrying with backoff.
    static func open(
        options: PhoneOptions
    ) async throws -> MTPSession {
        try await openSession(initialRecord: nil, options: options, workerConnector: nil) as! MTPSession
    }

    /// Opens a session with retries, using a worker process when `workerConnector` is non-nil.
    static func open(
        options: PhoneOptions,
        workerConnector: WorkerConnector?
    ) async throws -> any DeviceSession {
        try await openSession(initialRecord: nil, options: options, workerConnector: workerConnector)
    }

    /// Opens a session with retries from an initial record.
    static func open(
        _ record: USBDeviceRecord,
        options: PhoneOptions,
        workerConnector: WorkerConnector?
    ) async throws -> any DeviceSession {
        try await openSession(initialRecord: record, options: options, workerConnector: workerConnector)
    }

    /// Shared retry loop for opening a phone.
    static func openSession(
        initialRecord: USBDeviceRecord? = nil,
        options: PhoneOptions,
        workerConnector: WorkerConnector? = nil,
        clock: some Clock<Duration> = ContinuousClock(),
        workerOwner: (Int32) -> OwnWorkers.Owner = { OwnWorkers.owner(of: $0) },
        logNote: @escaping @Sendable (String) -> Void = { Log.note($0) }
    ) async throws -> any DeviceSession {
        var knownSerial = options.serial ?? initialRecord?.summary.usbSerial
        var schedule = BackoffSchedule()
        let startTime = clock.now
        var printedUserGuidance = false
        var currentRecord = initialRecord
        var isFirstAttempt = true

        while true {
            let record: USBDeviceRecord
            if isFirstAttempt, let currentRecord {
                record = currentRecord
                if knownSerial == nil, let serial = record.summary.usbSerial, DeviceKey.isUsableSerial(serial) {
                    knownSerial = serial
                }
            } else {
                do {
                    record = try await select(serial: knownSerial)
                    currentRecord = record
                    if knownSerial == nil, let serial = record.summary.usbSerial, DeviceKey.isUsableSerial(serial) {
                        knownSerial = serial
                    }
                } catch {
                    if isFirstAttempt {
                        throw error
                    }
                    if isNoPhoneFound(error) {
                        let elapsed = startTime.duration(to: clock.now)
                        if elapsed >= BackoffSchedule.retryTimeout {
                            throw CLIError(guidance(for: error))
                        }
                        let delay = schedule.next() ?? BackoffSchedule.maxDelay
                        let delayString = delay >= .seconds(1) ? "\(Int(delay.components.seconds)) s" : "0.5 s"
                        logNote("The phone is not free yet; trying again in \(delayString)…")
                        try await clock.sleep(for: delay)
                        continue
                    }
                    throw error
                }
            }
            isFirstAttempt = false

            do {
                if let workerConnector {
                    guard let serial = record.summary.usbSerial, DeviceKey.isUsableSerial(serial) else {
                        throw CLIError("This phone has no usable USB serial; --via-worker needs one.")
                    }
                    let key = DeviceKey(kind: .usb, vendorID: record.summary.vendorID, serial: serial)
                    return try await workerConnector.open(key)
                } else {
                    return try await MTPConnector.open(record, policy: options.reportOnly ? .reportOnly : .releaseSystemDaemons) { attempt in
                        if let released = attempt.released, case .terminated(let pid) = released {
                            logNote("Released the phone from macOS's camera service (ptpcamerad, pid \(pid)).")
                        }
                        if let recovered = attempt.recovered {
                            logNote("Recovered the phone after an interrupted transfer: \(recovered).")
                        }
                    }
                }
            } catch {
                let decision = classify(error, reportOnly: options.reportOnly, workerOwner: workerOwner)
                switch decision {
                case .retry:
                    if let deviceError = error as? DeviceError,
                       case .contended(holder: .process(let pid, let name)) = deviceError,
                       OwnWorkers.isOwnWorker(name) {
                        OwnWorkers.stopLeftover(pid)
                    }
                    let elapsed = startTime.duration(to: clock.now)
                    if elapsed >= BackoffSchedule.retryTimeout {
                        throw CLIError(guidance(for: error))
                    }
                    let delay = schedule.next() ?? BackoffSchedule.maxDelay
                    let delayString = delay >= .seconds(1) ? "\(Int(delay.components.seconds)) s" : "0.5 s"
                    logNote("The phone is not free yet; trying again in \(delayString)…")
                    currentRecord = nil
                    try await clock.sleep(for: delay)

                case .waitForUser(let message):
                    let elapsed = startTime.duration(to: clock.now)
                    if elapsed >= BackoffSchedule.userTimeout {
                        throw CLIError(message)
                    }
                    if !printedUserGuidance {
                        logNote(message)
                        printedUserGuidance = true
                    }
                    currentRecord = nil
                    try await clock.sleep(for: BackoffSchedule.userPollInterval)

                case .fail(let message):
                    throw CLIError(message)
                }
            }
        }
    }

    private static func isNoPhoneFound(_ error: any Error) -> Bool {
        if let cli = error as? CLIError, cli.description.contains("No Android phone found") {
            return true
        }
        if let val = error as? ValidationError, val.message.contains("No phone with USB serial") {
            return true
        }
        return false
    }

    static func storage(of session: any DeviceSession, matching option: String?) async throws -> StorageInfo {
        let storages = try await session.storages()
        guard !storages.isEmpty else { throw CLIError(guidance(for: DeviceError.noStorage)) }
        guard let option else { return storages[0] }
        let id = option.lowercased().hasPrefix("0x") ? UInt32(option.dropFirst(2), radix: 16) : UInt32(option)
        if let match = storages.first(where: { $0.id == id || $0.description.localizedCaseInsensitiveContains(option) }) {
            return match
        }
        throw ValidationError("No storage matches \(option). Available: " + storages.map { "\(hex($0.id)) \($0.description)" }.joined(separator: ", "))
    }

    static func guidance(for error: DeviceError) -> String {
        switch error {
        case .noMTPInterface:
            "The phone is in \"Charging only\" mode. Unlock it, open the USB notification and choose \"File transfer\"."
        case .noStorage:
            "The phone is locked or has not allowed access yet. Unlock it and tap \"Allow\" if it asks."
        case .contended(let holder):
            switch holder {
            case .process(_, let name) where name.contains("ptpcamerad") || name.contains("mscamerad"):
                "macOS's camera service is holding the phone (\(holder)). Run without --report-only to release it."
            case .process(_, let name):
                "\(name) is using the phone. Quit \(name) and try again."
            case .driver(let name):
                "A system driver (\(name)) has claimed the phone's file-transfer interface."
            }
        case .deviceGone:
            "The phone was disconnected."
        default:
            error.description
        }
    }

    static func guidance(for error: any Error) -> String {
        (error as? DeviceError).map { guidance(for: $0) } ?? String(describing: error)
    }
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

enum Log {
    static func note(_ message: String) {
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + message + "\n").utf8))
    }
}

func hex(_ value: UInt32) -> String { String(format: "0x%x", value) }

enum Format {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(UInt64(max(0, bytesPerSecond))) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--" }
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \(total % 3600 / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }

    static func link(_ summary: USBDeviceSummary) -> String {
        switch summary.linkGeneration {
        case .usb3: "USB 3 (\(Int((summary.linkSpeedBitsPerSecond ?? 0) / 1_000_000_000)) Gb/s)"
        case .usb2: "USB 2 (480 Mb/s)"
        case .usb1: "USB 1"
        case .unknown: "unknown speed"
        }
    }
}
