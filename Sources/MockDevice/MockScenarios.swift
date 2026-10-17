import DeviceAPI
import Foundation
import Synchronization

/// Named simulated phones, identical in every process: the worker runs one with `--mock <name>`,
/// and tests build the same one in-process to know the expected bytes.
///
/// - `standard`: a camera roll with a multi-chunk video, screenshots and downloads.
/// - `hang-on-read-N`: `standard`, but the N-th read of each process never returns.
/// - `crash-on-read-N`: `standard`, but the process exits on its N-th read.
public enum MockScenarios {
    public static let serial = "MOCKWORKER"

    public static func device(named name: String) -> MockDevice {
        let phone = MockDevice(serial: serial, model: "Worker Phone")
        phone.addFile("DCIM/Camera/IMG_0001.jpg", size: 3_100_000)
        phone.addFile("DCIM/Camera/VID_0002.mp4", size: 40 << 20)
        phone.addFile("DCIM/Camera/IMG_0003.jpg", size: 2_700_000)
        phone.addFile("DCIM/Screenshots/Screenshot_1.png", size: 420_000)
        phone.addFile("Download/report.pdf", size: 1_200_000)

        let reads = Mutex(0)
        if let n = number(after: "hang-on-read-", in: name) {
            phone.setFaultInjector { point in
                if case .read = point, reads.withLock({ $0 += 1; return $0 }) == n { sleep(3_600) }
                return nil
            }
        } else if let n = number(after: "crash-on-read-", in: name) {
            phone.setFaultInjector { point in
                if case .read = point, reads.withLock({ $0 += 1; return $0 }) == n { exit(3) }
                return nil
            }
        }
        return phone
    }

    private static func number(after prefix: String, in name: String) -> Int? {
        name.hasPrefix(prefix) ? Int(name.dropFirst(prefix.count)) : nil
    }
}
