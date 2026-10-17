import Foundation

/// Errors raised by device sessions, already classified for retry policy.
public enum DeviceError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
    /// The device left the USB bus. Wait for the same `DeviceKey`; never counts as an attempt.
    case deviceGone
    /// Another process holds the USB interface.
    case contended(holder: InterfaceHolder)
    /// The phone is attached but exposes no storage: locked, or in "Charging only" mode.
    case noStorage
    /// The phone is attached but has no MTP interface (USB mode is not "File transfer").
    case noMTPInterface
    /// No object at this path.
    case notFound(RemotePath)
    /// An object handle from an older session was used.
    case staleHandle
    /// The device cannot do what was asked (for example a >4 GiB offset without GetPartialObject64).
    case unsupported(String)
    /// A failure that may succeed on retry (timeout, busy, I/O while still attached).
    case transient(String)
    /// The device refused the operation for good (access denied, invalid object).
    case rejected(String)

    public var description: String {
        switch self {
        case .deviceGone: "device disconnected"
        case .contended(let holder): "USB interface is held by \(holder)"
        case .noStorage: "no storage visible (phone locked or in Charging only mode)"
        case .noMTPInterface: "phone is not in File transfer mode"
        case .notFound(let path): "not found: \(path)"
        case .staleHandle: "object handle from an earlier session"
        case .unsupported(let detail): "unsupported: \(detail)"
        case .transient(let detail): "transient: \(detail)"
        case .rejected(let detail): "rejected: \(detail)"
        }
    }
}

/// Who holds a USB interface exclusively, from IOKit's `UsbExclusiveOwner`.
public enum InterfaceHolder: Sendable, Hashable, Codable, CustomStringConvertible {
    /// A user-space process, e.g. `pid 812, ptpcamerad`.
    case process(pid: Int32, name: String)
    /// A kernel or DriverKit driver, e.g. `AppleUSBACMControl`.
    case driver(name: String)

    /// Parses the `UsbExclusiveOwner` registry property.
    public init(ownerString: String) {
        let trimmed = ownerString.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("pid "),
           let comma = trimmed.firstIndex(of: ","),
           let pid = Int32(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<comma].trimmingCharacters(in: .whitespaces)) {
            let name = trimmed[trimmed.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            self = .process(pid: pid, name: name)
        } else {
            self = .driver(name: trimmed)
        }
    }

    public var name: String {
        switch self {
        case .process(_, let name), .driver(let name): name
        }
    }

    public var description: String {
        switch self {
        case .process(let pid, let name): "\(name) (pid \(pid))"
        case .driver(let name): "driver \(name)"
        }
    }
}
