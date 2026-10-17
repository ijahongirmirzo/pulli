public import DeviceAPI
import Foundation
import USBKit
import WorkerIPC

/// Lists Android phones on the USB bus from the IOKit registry. Opens nothing.
public struct USBPhoneWatcher: DeviceWatcher {
    public init() {}

    public func currentDevices() async -> [DeviceCandidate] {
        USBRegistry.devices().compactMap { record in
            let isPhone = record.hasMTPInterface || USBRegistry.androidVendors[record.summary.vendorID] != nil
            guard isPhone else { return nil }
            let key = DeviceKey.isUsableSerial(record.summary.usbSerial)
                ? DeviceKey(kind: .usb, vendorID: record.summary.vendorID, serial: record.summary.usbSerial!)
                : nil
            // macOS's own camera service is released by Pulli when it opens the phone, and Pulli's
            // own worker is sorted out when opening it (see `OwnWorkers`); only a user app holding
            // it is worth telling the user about.
            var app: String?
            var systemCamera = false
            if case .process(_, let name)? = record.mtpHolder {
                if SystemCameraDaemons.isSystemCameraDaemonName(name) {
                    systemCamera = true
                } else if !OwnWorkers.isOwnWorker(name) {
                    app = name
                }
            }
            return DeviceCandidate(key: key, usb: record.summary, hasFileTransferInterface: record.hasMTPInterface, heldByApp: app,
                                   heldBySystemCamera: systemCamera)
        }
    }
}
