import Foundation

/// How a phone is recognised across cables, ports, reconnects and reboots (docs/DECISIONS.md, D-004).
public struct DeviceKey: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Kind: String, Sendable, Codable {
        /// USB vendor ID + USB serial number (iSerialNumber). Preferred.
        case usb
        /// MTP DeviceInfo serial, for devices whose USB serial is missing or junk.
        case mtp
        /// ImageCaptureCore's persistent device ID, for a phone whose USB serial Image Capture
        /// does not report.
        case imageCapture = "icc"
    }

    public var kind: Kind
    public var vendorID: UInt16
    public var serial: String

    public init(kind: Kind, vendorID: UInt16, serial: String) {
        self.kind = kind
        self.vendorID = vendorID
        self.serial = serial
    }

    public var description: String {
        String(format: "%@:%04x:%@", kind.rawValue, vendorID, serial)
    }

    /// Parses `description` ("usb:04e8:R58N…"), as stored in the journal and sent to the app.
    public init?(parsing text: String) {
        let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let kind = Kind(rawValue: parts[0]), let vendor = UInt16(parts[1], radix: 16) else { return nil }
        self.init(kind: kind, vendorID: vendor, serial: parts[2])
    }

    /// Serial numbers that some devices report for every unit, so they identify nothing.
    public static func isUsableSerial(_ serial: String?) -> Bool {
        guard let serial = serial?.trimmingCharacters(in: .whitespaces), serial.count >= 4 else { return false }
        let junk: Set<String> = ["0123456789ABCDEF", "0123456789abcdef", "123456789ABCDEF", "N/A", "none"]
        if junk.contains(serial) { return false }
        return serial.contains { $0 != "0" }
    }
}

/// What the USB layer reports about a connected device before any MTP session is opened.
public struct USBDeviceSummary: Sendable, Hashable, Codable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var vendorName: String?
    public var productName: String?
    public var usbSerial: String?
    public var locationID: UInt32
    public var address: UInt8
    /// Negotiated link speed in bits per second (480_000_000 for USB 2 high speed).
    public var linkSpeedBitsPerSecond: UInt64?
    /// Connected through a hub (a monitor, dock or adapter) rather than directly to the Mac.
    public var throughHub: Bool

    public init(
        vendorID: UInt16, productID: UInt16, vendorName: String?, productName: String?,
        usbSerial: String?, locationID: UInt32, address: UInt8, linkSpeedBitsPerSecond: UInt64?,
        throughHub: Bool = false
    ) {
        self.throughHub = throughHub
        self.vendorID = vendorID
        self.productID = productID
        self.vendorName = vendorName
        self.productName = productName
        self.usbSerial = usbSerial
        self.locationID = locationID
        self.address = address
        self.linkSpeedBitsPerSecond = linkSpeedBitsPerSecond
    }

    /// Bus number as libusb derives it on macOS (`locationID >> 24`).
    public var busNumber: UInt32 { locationID >> 24 }

    public var linkGeneration: LinkGeneration {
        LinkGeneration(bitsPerSecond: linkSpeedBitsPerSecond)
    }
}

/// USB generation, for the "your cable is the bottleneck" badge.
public enum LinkGeneration: String, Sendable, Codable {
    case usb1, usb2, usb3, unknown

    public init(bitsPerSecond: UInt64?) {
        switch bitsPerSecond {
        case nil: self = .unknown
        case let bps? where bps >= 5_000_000_000: self = .usb3
        case let bps? where bps >= 480_000_000: self = .usb2
        case .some: self = .usb1
        }
    }
}

/// How file contents can be read from a device.
public enum ReadStrategy: String, Sendable, Codable {
    /// Android GetPartialObject64 (0x95C1): any offset. Resumable.
    case partial64
    /// Standard GetPartialObject (0x101B): 32-bit offsets, so resumable only below 4 GiB.
    case partial32
    /// Whole-object transfer only. Not resumable.
    case whole

    public func supportsResume(fileSize: UInt64) -> Bool {
        switch self {
        case .partial64: true
        case .partial32: fileSize <= UInt64(UInt32.max)
        case .whole: false
        }
    }
}

public struct DeviceInfo: Sendable, Hashable, Codable {
    public var key: DeviceKey
    public var usb: USBDeviceSummary
    public var manufacturer: String?
    public var model: String?
    public var friendlyName: String?
    public var mtpSerial: String?
    public var readStrategy: ReadStrategy

    public init(
        key: DeviceKey, usb: USBDeviceSummary, manufacturer: String?, model: String?,
        friendlyName: String?, mtpSerial: String?, readStrategy: ReadStrategy
    ) {
        self.key = key
        self.usb = usb
        self.manufacturer = manufacturer
        self.model = model
        self.friendlyName = friendlyName
        self.mtpSerial = mtpSerial
        self.readStrategy = readStrategy
    }

    public var displayName: String {
        friendlyName ?? model ?? usb.productName ?? "Android phone"
    }
}

public typealias StorageID = UInt32

public struct StorageInfo: Sendable, Hashable, Codable, Identifiable {
    public var id: StorageID
    public var description: String
    public var volumeIdentifier: String?
    public var capacityBytes: UInt64?
    public var freeBytes: UInt64?

    public init(id: StorageID, description: String, volumeIdentifier: String?, capacityBytes: UInt64?, freeBytes: UInt64?) {
        self.id = id
        self.description = description
        self.volumeIdentifier = volumeIdentifier
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
    }
}

/// A file name compared byte for byte.
///
/// Swift's `String` equality treats canonically equivalent names as equal (an NFC "é" equals an
/// NFD "é"), but a phone's file system can hold both side by side as two different files.
public struct ExactName: Sendable, Hashable {
    public let bytes: [UInt8]

    public init(_ name: String) {
        bytes = Array(name.utf8)
    }
}

/// A slash-separated path on a storage, relative to its root. Never contains an object handle.
/// Equality and hashing are byte-exact (see `ExactName`).
public struct RemotePath: Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var components: [String]

    public init(components: [String]) {
        self.components = components
    }

    public init(_ string: String) {
        components = string.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public static let root = RemotePath(components: [])

    public var name: String { components.last ?? "" }
    public var parent: RemotePath { RemotePath(components: Array(components.dropLast())) }
    public var isRoot: Bool { components.isEmpty }
    public var description: String { "/" + components.joined(separator: "/") }

    public func appending(_ name: String) -> RemotePath {
        RemotePath(components: components + [name])
    }

    public static func == (lhs: RemotePath, rhs: RemotePath) -> Bool {
        lhs.components.count == rhs.components.count
            && zip(lhs.components, rhs.components).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(components.count)
        for component in components {
            hasher.combine(ExactName(component))
        }
    }
}

/// Identifies one open session. Object handles are only valid within the epoch that produced them.
public struct SessionEpoch: Sendable, Hashable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public var description: String { "epoch \(rawValue)" }
}

/// An MTP object handle bound to the session it came from. Deliberately not Codable: handles are
/// never persisted, because phones renumber objects between sessions (brief, failure cause 4).
public struct ObjectRef: Sendable, Hashable {
    public let handle: UInt32
    public let storage: StorageID
    public let epoch: SessionEpoch

    public init(handle: UInt32, storage: StorageID, epoch: SessionEpoch) {
        self.handle = handle
        self.storage = storage
        self.epoch = epoch
    }
}

public struct RemoteEntry: Sendable, Hashable {
    public var name: String
    public var isFolder: Bool
    public var size: UInt64
    /// The phone's wall-clock modification time, encoded as if it were UTC (D-005).
    public var modifiedWallClock: Int64
    public var ref: ObjectRef

    public init(name: String, isFolder: Bool, size: UInt64, modifiedWallClock: Int64, ref: ObjectRef) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.modifiedWallClock = modifiedWallClock
        self.ref = ref
    }
}
