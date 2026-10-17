internal import CLibMTP
public import Foundation

/// Process-wide libmtp state.
public enum MTPLibrary {
    /// Version of the libmtp that was compiled against (from the vendored header).
    public static let version: String = LIBMTP_VERSION_STRING

    /// A USB device that libmtp recognises as MTP-capable, before any session is opened.
    public struct RawDevice: Sendable, Hashable {
        public var vendor: String
        public var vendorID: UInt16
        public var product: String
        public var productID: UInt16
        public var deviceFlags: UInt32
        public var busLocation: UInt32
        public var deviceNumber: UInt8
    }

    public enum DetectError: Error, Equatable {
        case libmtp(code: Int)
    }

    /// The Mac's time zone, captured before `bootstrap()` switches the process to UTC.
    nonisolated(unsafe) public private(set) static var systemTimeZone: TimeZone = .current

    /// Prepares the process for libmtp. Call first thing in `main`, before any other thread starts.
    ///
    /// libmtp parses the phone's time-zone-less dates with `mktime()`. With `TZ=UTC` that yields
    /// the phone's wall-clock time as if it were UTC, which stays stable when the Mac changes time
    /// zone or daylight saving time (docs/DECISIONS.md, D-005).
    public static func bootstrap() {
        systemTimeZone = TimeZone.current
        setenv("TZ", "UTC", 1)
        tzset()
    }

    @MTPActor private static var initialized = false

    @MTPActor static func ensureInitialized() {
        guard !initialized else { return }
        LIBMTP_Init()
        initialized = true
    }

    /// Lists MTP-capable devices on the USB bus without opening them.
    ///
    /// Opening nothing means this never competes with ptpcamerad for the interface.
    @MTPActor public static func detectRawDevices() throws(DetectError) -> [RawDevice] {
        try withRawDevices { devices in
            devices.map { device in
                RawDevice(
                    vendor: device.device_entry.vendor.map { String(cString: $0) } ?? "",
                    vendorID: device.device_entry.vendor_id,
                    product: device.device_entry.product.map { String(cString: $0) } ?? "",
                    productID: device.device_entry.product_id,
                    deviceFlags: device.device_entry.device_flags,
                    busLocation: device.bus_location,
                    deviceNumber: device.devnum
                )
            }
        }
    }

    /// Runs `body` with libmtp's raw device array, which is freed afterwards.
    @MTPActor static func withRawDevices<T>(
        _ body: (UnsafeMutableBufferPointer<LIBMTP_raw_device_t>) throws(DetectError) -> T
    ) throws(DetectError) -> T {
        ensureInitialized()
        var raw: UnsafeMutablePointer<LIBMTP_raw_device_t>?
        var count: Int32 = 0
        let status = LIBMTP_Detect_Raw_Devices(&raw, &count)
        defer { free(raw) }

        switch status {
        case LIBMTP_ERROR_NONE:
            return try body(UnsafeMutableBufferPointer(start: raw, count: raw == nil ? 0 : Int(count)))
        case LIBMTP_ERROR_NO_DEVICE_ATTACHED:
            return try body(UnsafeMutableBufferPointer(start: nil, count: 0))
        default:
            throw .libmtp(code: Int(status.rawValue))
        }
    }
}
