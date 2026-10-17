internal import CLibMTP
import Foundation
internal import TransferCore

/// Brings a phone back to idle after a Pulli process died mid-transfer, before libmtp opens it.
///
/// Observed on a Galaxy Z Fold7 (docs/DECISIONS.md, D-016): after a `kill -9` during a partial
/// read, the phone keeps sending the rest of the interrupted chunk, and its MTP server answers
/// nothing until the host has read that data. libmtp's OpenSession then fails, and its fallback is
/// a USB reset, after which ptpcamerad grabs the phone again and Samsung hides the storage until
/// the phone is unlocked.
///
/// What does not work on that phone:
/// - PTP class requests: Get Device Status (0x67) got no answer.
/// - Draining the pipe with timed-out reads: a timeout makes libusb abort the pipe and clear the
///   endpoint halt, and the Fold7 dropped off the USB bus in response.
///
/// So this never waits for silence. One thread sends a fresh OpenSession command while this thread
/// reads the IN pipe; each read completes because data keeps coming: first the rest of the stale
/// chunk, then the old transaction's response, then the reply to our OpenSession. Then it closes
/// that session, leaving the phone idle for libmtp. It runs only when `SessionMarker` shows the
/// previous session did not end cleanly.
enum MTPQuiesce {
    struct Report: Sendable, CustomStringConvertible {
        var discardedBytes = 0
        var openResponse: UInt16?
        var closeResponse: UInt16?
        var skipped: String?

        var description: String {
            if let skipped { return "recovery skipped: \(skipped)" }
            func hex(_ code: UInt16?) -> String { code.map { String(format: "0x%04x", $0) } ?? "no reply" }
            return "discarded \(discardedBytes) stale bytes, session open \(hex(openResponse)), close \(hex(closeResponse))"
        }

        var succeeded: Bool { skipped == nil && closeResponse == 0x2001 }
    }

    private static let openSession: UInt16 = 0x1002
    private static let closeSession: UInt16 = 0x1003
    /// Per-read limit. Reads only wait while the phone is actively sending; this bounds a phone
    /// that is truly wedged (a replug is needed then anyway).
    private static let readTimeout: UInt32 = 10_000

    static func run(busNumber: UInt32, address: UInt8, interfaceNumber: UInt8) -> Report {
        var report = Report()
        var context: OpaquePointer?
        guard libusb_init(&context) == 0 else { report.skipped = "libusb init failed"; return report }
        defer { libusb_exit(context) }

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let count = libusb_get_device_list(context, &list)
        guard count > 0, let list else { report.skipped = "no USB devices"; return report }
        defer { libusb_free_device_list(list, 1) }

        var target: OpaquePointer?
        for index in 0..<count {
            guard let device = list[index] else { continue }
            if UInt32(libusb_get_bus_number(device)) == busNumber && libusb_get_device_address(device) == address {
                target = device
                break
            }
        }
        guard let target else { report.skipped = "device not found"; return report }
        guard let (inEndpoint, outEndpoint) = bulkEndpoints(target, interfaceNumber: interfaceNumber) else {
            report.skipped = "no bulk endpoints"
            return report
        }

        var handle: OpaquePointer?
        guard libusb_open(target, &handle) == 0, let handle else { report.skipped = "open failed"; return report }
        defer { libusb_close(handle) }
        guard libusb_claim_interface(handle, Int32(interfaceNumber)) == 0 else {
            report.skipped = "interface busy"
            return report
        }
        defer { libusb_release_interface(handle, Int32(interfaceNumber)) }

        // Transaction 0 for OpenSession (as libmtp does), 1 for CloseSession.
        let (opened, discarded) = transact(handle, command: openSession, transactionID: 0, parameters: [1],
                                           inEndpoint: inEndpoint, outEndpoint: outEndpoint)
        report.discardedBytes = discarded
        report.openResponse = opened
        // 0x2001 OK, or 0x201E SessionAlreadyOpen (the killed process never closed its session).
        guard opened == 0x2001 || opened == 0x201E else { return report }
        report.closeResponse = transact(handle, command: closeSession, transactionID: 1, parameters: [],
                                        inEndpoint: inEndpoint, outEndpoint: outEndpoint).response
        return report
    }

    /// Sends one PTP command on a helper thread while reading the IN pipe here, discarding
    /// everything until the response to this transaction arrives.
    private static func transact(
        _ handle: OpaquePointer, command: UInt16, transactionID: UInt32, parameters: [UInt32],
        inEndpoint: UInt8, outEndpoint: UInt8
    ) -> (response: UInt16?, discarded: Int) {
        var container = [UInt8]()
        let length = UInt32(12 + 4 * parameters.count)
        container += withUnsafeBytes(of: length.littleEndian, Array.init)
        container += withUnsafeBytes(of: UInt16(1).littleEndian, Array.init)      // command block
        container += withUnsafeBytes(of: command.littleEndian, Array.init)
        container += withUnsafeBytes(of: transactionID.littleEndian, Array.init)
        for parameter in parameters { container += withUnsafeBytes(of: parameter.littleEndian, Array.init) }

        nonisolated(unsafe) let sendHandle = handle
        let sent = DispatchSemaphore(value: 0)
        let command = container
        Thread.detachNewThread {
            var bytes = command
            var transferred: Int32 = 0
            _ = libusb_bulk_transfer(sendHandle, outEndpoint, &bytes, Int32(bytes.count), &transferred, readTimeout)
            sent.signal()
        }

        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var discarded = 0
        var response: UInt16?
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            var transferred: Int32 = 0
            let result = libusb_bulk_transfer(handle, inEndpoint, &buffer, Int32(buffer.count), &transferred, readTimeout)
            guard result == 0 else { break }
            let count = Int(transferred)
            // A response container is short and stands alone: length, type 3, code, transaction.
            if count >= 12, count <= 64, buffer[4] == 3, buffer[5] == 0 {
                let code = UInt16(buffer[6]) | UInt16(buffer[7]) << 8
                let id = UInt32(buffer[8]) | UInt32(buffer[9]) << 8 | UInt32(buffer[10]) << 16 | UInt32(buffer[11]) << 24
                if id == transactionID {
                    response = code
                    break
                }
            }
            discarded += count
        }
        sent.wait()
        return (response, discarded)
    }

    private static func bulkEndpoints(_ device: OpaquePointer, interfaceNumber: UInt8) -> (in: UInt8, out: UInt8)? {
        var config: UnsafeMutablePointer<libusb_config_descriptor>?
        guard libusb_get_active_config_descriptor(device, &config) == 0, let config else { return nil }
        defer { libusb_free_config_descriptor(config) }
        var inEndpoint: UInt8?
        var outEndpoint: UInt8?
        for i in 0..<Int(config.pointee.bNumInterfaces) {
            let interface = config.pointee.interface[i]
            for a in 0..<Int(interface.num_altsetting) {
                let setting = interface.altsetting[a]
                guard setting.bInterfaceNumber == interfaceNumber else { continue }
                for e in 0..<Int(setting.bNumEndpoints) {
                    let endpoint = setting.endpoint[e]
                    guard endpoint.bmAttributes & 0x03 == UInt8(LIBUSB_TRANSFER_TYPE_BULK.rawValue) else { continue }
                    if endpoint.bEndpointAddress & 0x80 != 0 { inEndpoint = endpoint.bEndpointAddress } else { outEndpoint = endpoint.bEndpointAddress }
                }
            }
        }
        guard let inEndpoint, let outEndpoint else { return nil }
        return (inEndpoint, outEndpoint)
    }
}

/// Remembers, across processes, which phones have a session open, so the next open can tell
/// whether the previous one ended cleanly. One empty file per USB serial.
enum SessionMarker {
    static var directory: URL {
        DataFolder.current.appendingPathComponent("sessions", isDirectory: true)
    }

    private static func url(_ serial: String) -> URL {
        directory.appendingPathComponent(serial.replacingOccurrences(of: "/", with: "_"))
    }

    static func isDirty(_ serial: String?) -> Bool {
        guard let serial else { return false }
        return FileManager.default.fileExists(atPath: url(serial).path)
    }

    static func markOpen(_ serial: String?) {
        guard let serial else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url(serial).path, contents: nil)
    }

    static func markClosed(_ serial: String?) {
        guard let serial else { return }
        try? FileManager.default.removeItem(at: url(serial))
    }
}
