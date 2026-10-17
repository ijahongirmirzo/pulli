public import DeviceAPI
import Foundation
import IOKit
import IOKit.usb

/// One USB device as seen in the IOKit registry, with its interfaces.
public struct USBDeviceRecord: Sendable, Hashable {
    public var registryID: UInt64
    public var summary: USBDeviceSummary
    /// Holder of the device itself (libusb's `USBDeviceOpenSeize` target).
    public var deviceHolder: InterfaceHolder?
    public var interfaces: [USBInterfaceRecord]

    /// True when the phone exposes an MTP/PTP interface, i.e. it is in "File transfer" mode.
    /// A phone in "Charging only" mode has none.
    public var hasMTPInterface: Bool {
        interfaces.contains(where: \.looksLikeMTP)
    }

    /// Who is keeping us from the MTP interface, if anyone.
    ///
    /// A kernel driver on the device itself (e.g. the composite driver) does not block us: when
    /// libusb's `USBDeviceOpenSeize` fails it carries on and claims the interface directly. So only
    /// the MTP interface's holder counts, or a user process that opened the whole device.
    public var mtpHolder: InterfaceHolder? {
        if let holder = interfaces.first(where: \.looksLikeMTP)?.holder { return holder }
        if case .process = deviceHolder { return deviceHolder }
        return nil
    }
}

public struct USBInterfaceRecord: Sendable, Hashable {
    public var number: UInt8
    public var interfaceClass: UInt8
    public var interfaceSubClass: UInt8
    public var interfaceProtocol: UInt8
    public var name: String?
    public var holder: InterfaceHolder?

    /// Still Image class (6/1/1, what Android uses for MTP) or a vendor interface named "MTP".
    public var looksLikeMTP: Bool {
        if interfaceClass == 6 && interfaceSubClass == 1 && interfaceProtocol == 1 { return true }
        return name?.localizedCaseInsensitiveContains("MTP") == true
    }
}

/// Snapshot queries against the IOKit USB registry. Read-only; opens nothing.
public enum USBRegistry {
    /// USB vendor IDs of Android phone makers, to recognise a phone in "Charging only" mode
    /// (which exposes no MTP interface, so libmtp cannot see it).
    public static let androidVendors: [UInt16: String] = [
        0x04e8: "Samsung", 0x18d1: "Google", 0x2717: "Xiaomi", 0x22b8: "Motorola", 0x2a70: "OnePlus",
        0x12d1: "Huawei", 0x0bb4: "HTC", 0x1004: "LG", 0x0fce: "Sony", 0x05c6: "Qualcomm", 0x2d95: "vivo",
        0x22d9: "OPPO", 0x1949: "Amazon", 0x0e8d: "MediaTek", 0x19d2: "ZTE", 0x2ae5: "Fairphone",
        0x17ef: "Lenovo", 0x1ebf: "Nothing", 0x2e04: "HMD Global",
    ]

    /// All USB devices currently attached.
    public static func devices() -> [USBDeviceRecord] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var records: [USBDeviceRecord] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let record = record(for: service) {
                records.append(record)
            }
        }
        return records
    }

    /// The device libmtp/libusb calls (bus, address).
    public static func device(busNumber: UInt32, address: UInt8) -> USBDeviceRecord? {
        devices().first { $0.summary.busNumber == busNumber && $0.summary.address == address }
    }

    /// The device with this identity, wherever it is plugged in.
    public static func device(matching key: DeviceKey) -> USBDeviceRecord? {
        guard key.kind == .usb else { return nil }
        return devices().first { $0.summary.vendorID == key.vendorID && $0.summary.usbSerial == key.serial }
    }

    static func record(for service: io_service_t) -> USBDeviceRecord? {
        let props = properties(of: service)
        guard let vendorID = props.uint("idVendor"), let productID = props.uint("idProduct") else { return nil }

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)

        let summary = USBDeviceSummary(
            vendorID: UInt16(truncatingIfNeeded: vendorID),
            productID: UInt16(truncatingIfNeeded: productID),
            vendorName: props.string("kUSBVendorString") ?? props.string("USB Vendor Name"),
            productName: props.string("kUSBProductString") ?? props.string("USB Product Name"),
            usbSerial: props.string("kUSBSerialNumberString") ?? props.string("USB Serial Number"),
            locationID: UInt32(truncatingIfNeeded: props.uint("locationID") ?? 0),
            address: UInt8(truncatingIfNeeded: props.uint("USB Address") ?? 0),
            linkSpeedBitsPerSecond: props.uint("UsbLinkSpeed") ?? linkSpeed(fromUSBSpeed: props.uint("USBSpeed")),
            throughHub: isBehindHub(service)
        )

        return USBDeviceRecord(
            registryID: registryID,
            summary: summary,
            deviceHolder: props.string("UsbExclusiveOwner").map(InterfaceHolder.init(ownerString:)),
            interfaces: interfaces(of: service)
        )
    }

    /// True when the device's parent in the USB plane is another USB device (a hub), not the Mac's
    /// own controller.
    private static func isBehindHub(_ device: io_service_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(device, kIOUSBPlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        return IOObjectConformsTo(parent, "IOUSBHostDevice") != 0
    }

    private static func interfaces(of device: io_service_t) -> [USBInterfaceRecord] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(device, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [USBInterfaceRecord] = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
            let props = properties(of: child)
            result.append(USBInterfaceRecord(
                number: UInt8(truncatingIfNeeded: props.uint("bInterfaceNumber") ?? 0),
                interfaceClass: UInt8(truncatingIfNeeded: props.uint("bInterfaceClass") ?? 0),
                interfaceSubClass: UInt8(truncatingIfNeeded: props.uint("bInterfaceSubClass") ?? 0),
                interfaceProtocol: UInt8(truncatingIfNeeded: props.uint("bInterfaceProtocol") ?? 0),
                name: props.string("kUSBString") ?? props.string("USB Interface Name"),
                holder: props.string("UsbExclusiveOwner").map(InterfaceHolder.init(ownerString:))
            ))
        }
        return result.sorted { $0.number < $1.number }
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    /// Fallback when `UsbLinkSpeed` is absent. `USBSpeed` uses `tIOUSBHostConnectionSpeed`
    /// (Apple-internal numbering, IOUSBHostFamilyDefinitions.h).
    private static func linkSpeed(fromUSBSpeed value: UInt64?) -> UInt64? {
        switch value {
        case 1: 12_000_000
        case 2: 1_500_000
        case 3: 480_000_000
        case 4: 5_000_000_000
        case 5: 10_000_000_000
        case 6: 20_000_000_000
        default: nil
        }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func uint(_ key: String) -> UInt64? {
        (self[key] as? NSNumber)?.uint64Value
    }

    func string(_ key: String) -> String? {
        guard let value = self[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
