/// Opens sessions to a known phone, wherever it is currently plugged in.
///
/// Implemented by MTPKit (real USB) and MockDevice. The transfer supervisor uses it to reconnect
/// after a disconnect: the phone is identified by its `DeviceKey`, never by port.
public protocol DeviceConnector: Sendable {
    /// Opens a new session. Throws `.deviceGone` if the phone is not attached right now, and the
    /// usual `DeviceError`s (`.noMTPInterface`, `.contended`, …) if it is attached but unusable.
    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession
}

/// An optional capability for connectors that take time to open and can report progress (0...100).
public protocol DeviceOpeningProgress: Sendable {
    func setProgressHandler(_ handler: (@Sendable (DeviceKey, Int) -> Void)?)
}
