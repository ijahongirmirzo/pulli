import DeviceAPI
import Foundation
public import HelperCore
public import MockDevice

/// A simulated phone for developing the app without USB: a camera roll, screenshots, downloads and
/// one long video, served at about USB 2 speed.
public struct MockPhones: DeviceWatcher {
    public let devices: [MockDevice]

    public static func make() -> MockPhones {
        // Like the Galaxy Z Fold7 from the device tests: connected at USB 2 though it supports USB 3.
        let phone = MockDevice(serial: "MOCKFOLD7", model: "Galaxy Z Fold7", linkSpeedBitsPerSecond: 480_000_000)
        for day in 1...28 {
            for shot in 0..<3 {
                let name = String(format: "DCIM/Camera/202609%02d_%02d%02d%02d.jpg", day, 9 + shot, day, shot * 7)
                phone.addFile(RemotePath(name), size: UInt64(2_400_000 + day * 91_000 + shot * 17_000), modifiedWallClock: 1_788_000_000 + Int64(day * 86_400))
            }
            if day % 4 == 0 {
                phone.addFile(RemotePath(String(format: "DCIM/Camera/202609%02d_183000.mp4", day)), size: UInt64(60_000_000 + day * 3_000_000))
            }
        }
        phone.addFile("DCIM/Camera/20260917_081927.mp4", size: 385_437_050)
        for index in 1...12 { phone.addFile(RemotePath("DCIM/Screenshots/Screenshot_202609\(10 + index)_1200.png"), size: UInt64(400_000 + index * 9_000)) }
        phone.addFile("Download/boarding-pass.pdf", size: 180_000)
        phone.addFile("Download/project-brief.docx", size: 64_000)
        phone.addFile("Movies/Long trip.mp4", size: 2_300_000_000)
        phone.addFile("Documents/Work/notes.txt", size: 4_000)
        // About 30 MB/s, like a USB 2 link.
        phone.setFaultInjector { point in
            if case .read(_, _, let length) = point { usleep(useconds_t(min(Double(length) / 30_000_000 * 1_000_000, 900_000))) }
            return nil
        }
        // PULLI_MOCK_LOCKED=1: the phone starts locked, so the app shows its unlock guide.
        if ProcessInfo.processInfo.environment["PULLI_MOCK_LOCKED"] == "1" { phone.setLocked(true) }
        return MockPhones(devices: [phone])
    }

    public func currentDevices() async -> [DeviceCandidate] {
        devices.filter(\.isPluggedIn).map {
            DeviceCandidate(key: $0.key, usb: $0.usb, hasFileTransferInterface: $0.mode == .fileTransfer, heldByApp: nil)
        }
    }
}
