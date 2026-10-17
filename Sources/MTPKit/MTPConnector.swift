internal import CLibMTP
public import DeviceAPI
import Foundation
public import USBKit

/// Opens MTP sessions, dealing with macOS's camera daemons on the way (docs/DECISIONS.md, D-008).
public enum MTPConnector {
    public enum ContentionPolicy: Sendable {
        /// Terminate verified Apple camera daemons (ptpcamerad) that hold the phone.
        case releaseSystemDaemons
        /// Never signal anything; report the holder instead.
        case reportOnly
    }

    /// What happened while opening, for logs and `pulli-cli doctor`.
    public struct Attempt: Sendable {
        public var delay: Duration
        public var holder: InterfaceHolder?
        public var released: SystemCameraDaemons.Outcome?
        /// Set when the phone had to be cleaned up after an interrupted transfer.
        public var recovered: String?
    }

    /// Retry schedule after releasing a daemon: it may still be letting go of the interface, and
    /// an app browsing for cameras can make launchd start it again.
    static let retryDelays: [Duration] = [.zero, .milliseconds(150), .milliseconds(400), .seconds(1), .seconds(2)]

    /// Opens a session to the phone at this registry entry.
    public static func open(
        _ record: USBDeviceRecord,
        policy: ContentionPolicy = .releaseSystemDaemons,
        log: @Sendable (Attempt) -> Void = { _ in }
    ) async throws(DeviceError) -> MTPSession {
        if !record.interfaces.isEmpty && !record.hasMTPInterface {
            throw .noMTPInterface
        }

        var lastHolder: InterfaceHolder?
        for delay in retryDelays {
            if delay > .zero { try? await Task.sleep(for: delay) }

            guard let current = USBRegistry.device(busNumber: record.summary.busNumber, address: record.summary.address),
                  current.registryID == record.registryID else {
                throw .deviceGone
            }

            var attempt = Attempt(delay: delay, holder: current.mtpHolder)
            lastHolder = current.mtpHolder
            if let holder = current.mtpHolder, case .process = holder {
                switch policy {
                case .reportOnly:
                    log(attempt)
                    throw .contended(holder: holder)
                case .releaseSystemDaemons:
                    let outcome = SystemCameraDaemons.release(holder)
                    attempt.released = outcome
                    if outcome == .notSystemDaemon {
                        log(attempt)
                        throw .contended(holder: holder)
                    }
                }
            }
            // Only after a session that did not end cleanly (see MTPQuiesce): on a healthy phone even
            // harmless-looking USB requests are best avoided.
            let serial = current.summary.usbSerial
            if SessionMarker.isDirty(serial), let interface = current.interfaces.first(where: \.looksLikeMTP) {
                let report = MTPQuiesce.run(busNumber: current.summary.busNumber, address: current.summary.address,
                                            interfaceNumber: interface.number)
                attempt.recovered = report.description
            }
            log(attempt)

            if let session = await openRaw(current) {
                SessionMarker.markOpen(serial)
                return session
            }
        }

        if let lastHolder { throw .contended(holder: lastHolder) }
        throw .transient("could not open an MTP session")
    }

    @MTPActor
    private static func openRaw(_ record: USBDeviceRecord) -> MTPSession? {
        do {
            return try MTPLibrary.withRawDevices { devices -> MTPSession? in
                for index in devices.indices
                where devices[index].bus_location == record.summary.busNumber && devices[index].devnum == record.summary.address {
                    guard let device = LIBMTP_Open_Raw_Device_Uncached(&devices[index]) else { return nil }
                    return MTPSession(device: device, usb: record)
                }
                return nil
            }
        } catch {
            return nil
        }
    }
}
