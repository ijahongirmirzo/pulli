public import DeviceAPI
public import Foundation
import HelperCore
import ICCKit
import WorkerIPC

/// Which code talks to real phones. libmtp (in worker processes) reaches every file; Apple's
/// ImageCaptureCore reaches photos and videos only, but works inside the App Sandbox
/// (docs/APP_STORE.md). Chosen with `PULLI_PHONE_BACKEND=icc`; libmtp otherwise.
public enum PhoneBackend: String, Sendable {
    case libmtp
    case icc

    public static let environmentVariable = "PULLI_PHONE_BACKEND"

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> PhoneBackend {
        environment[environmentVariable].flatMap { PhoneBackend(rawValue: $0.lowercased()) } ?? .libmtp
    }

    /// The connector and watcher for the engine. `workerURL` is the `pulli-mtp-worker` used by libmtp.
    public func devices(workerURL: URL) -> (connector: any DeviceConnector, watcher: any DeviceWatcher) {
        switch self {
        case .libmtp: (WorkerConnector(executable: workerURL), USBPhoneWatcher())
        case .icc: (ICCDeviceConnector(), ICCDeviceWatcher())
        }
    }
}
