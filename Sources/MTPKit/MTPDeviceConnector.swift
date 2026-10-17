public import DeviceAPI
import Foundation
import USBKit

/// Opens MTP sessions to a phone by identity, wherever it is plugged in.
public struct MTPDeviceConnector: DeviceConnector {
    public var policy: MTPConnector.ContentionPolicy
    public var onAttempt: @Sendable (MTPConnector.Attempt) -> Void

    public init(policy: MTPConnector.ContentionPolicy = .releaseSystemDaemons,
                onAttempt: @escaping @Sendable (MTPConnector.Attempt) -> Void = { _ in }) {
        self.policy = policy
        self.onAttempt = onAttempt
    }

    public func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        switch key.kind {
        case .usb:
            guard let record = USBRegistry.device(matching: key) else { throw .deviceGone }
            return try await MTPConnector.open(record, policy: policy, log: onAttempt)
        case .mtp:
            // No usable USB serial: open each phone from this vendor and compare MTP serials.
            let candidates = USBRegistry.devices().filter { $0.summary.vendorID == key.vendorID && $0.hasMTPInterface }
            for record in candidates {
                guard let session = try? await MTPConnector.open(record, policy: policy, log: onAttempt) else { continue }
                if session.info.key == key { return session }
                await session.close()
            }
            throw .deviceGone
        case .imageCapture:
            // An identity only ImageCaptureCore knows: libmtp cannot find that phone by it.
            throw .deviceGone
        }
    }
}
