/// A phone seen on USB, before any session is opened.
///
/// Lives here rather than in HelperCore so that every phone backend (libmtp's USB registry,
/// ImageCaptureCore's device browser) can report phones without depending on the helper.
public struct DeviceCandidate: Sendable, Hashable {
    /// Known from the USB serial; nil for the rare phone whose serial is missing or junk.
    public var key: DeviceKey?
    public var usb: USBDeviceSummary
    /// False in "Charging only" mode: the phone exposes no file-transfer interface.
    public var hasFileTransferInterface: Bool
    /// A user app holding the phone (never macOS's camera service, which Pulli releases itself).
    public var heldByApp: String?
    /// macOS's camera service holds the file-transfer interface. While Pulli has a session that
    /// means the session is dead: the service re-grabbed the phone (it is relaunched on demand).
    public var heldBySystemCamera: Bool

    public init(key: DeviceKey?, usb: USBDeviceSummary, hasFileTransferInterface: Bool, heldByApp: String?,
                heldBySystemCamera: Bool = false) {
        self.key = key
        self.usb = usb
        self.hasFileTransferInterface = hasFileTransferInterface
        self.heldByApp = heldByApp
        self.heldBySystemCamera = heldBySystemCamera
    }
}

/// Lists the phones currently attached. Cheap; polled about once a second.
public protocol DeviceWatcher: Sendable {
    func currentDevices() async -> [DeviceCandidate]
}
