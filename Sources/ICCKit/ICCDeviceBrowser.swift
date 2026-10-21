public import DeviceAPI
public import Foundation
public import ImageCaptureCore

extension ICDevice: @unchecked @retroactive Sendable {}
extension ICCameraItem: @unchecked @retroactive Sendable {}

/// A camera ImageCaptureCore found, with the identity Pulli knows it by.
public struct ICCCamera: Sendable {
    public let device: ICCameraDevice
    /// Worked out once, when the camera appeared, so it stays the same while it is attached.
    public let key: DeviceKey?
    public let usb: USBDeviceSummary

    public var name: String? { device.name }

    /// A phone Pulli should offer: on USB, and not an iPhone or iPad (Apple's vendor ID), which
    /// Image Capture lists too.
    public var isPhoneCandidate: Bool {
        device.transportType == ICDeviceTransport.transportTypeUSB.rawValue && usb.vendorID != ICCIdentity.appleVendorID
    }

    init(device: ICCameraDevice) {
        self.device = device
        key = ICCIdentity.key(vendorID: Int(device.usbVendorID), serial: device.serialNumberString,
                              persistentID: device.persistentIDString ?? device.uuidString)
        usb = USBDeviceSummary(vendorID: UInt16(truncatingIfNeeded: device.usbVendorID),
                               productID: UInt16(truncatingIfNeeded: device.usbProductID),
                               vendorName: nil, productName: device.name, usbSerial: device.serialNumberString,
                               locationID: UInt32(truncatingIfNeeded: device.usbLocationID), address: 0,
                               linkSpeedBitsPerSecond: nil)
    }
}

/// How a camera from ImageCaptureCore maps to a `DeviceKey`.
public enum ICCIdentity {
    public static let appleVendorID: UInt16 = 0x05AC

    /// The USB serial when Image Capture gives a usable one: the same key libmtp's backend uses,
    /// so a phone is one phone to Pulli whichever backend sees it. Otherwise Image Capture's
    /// persistent ID. Nil when there is neither (the phone is then not offered).
    public static func key(vendorID: Int, serial: String?, persistentID: String?) -> DeviceKey? {
        let vendor = UInt16(truncatingIfNeeded: vendorID)
        if DeviceKey.isUsableSerial(serial), let serial = serial?.trimmingCharacters(in: .whitespaces) {
            return DeviceKey(kind: .usb, vendorID: vendor, serial: serial)
        }
        if let persistentID = persistentID?.trimmingCharacters(in: .whitespaces), !persistentID.isEmpty {
            return DeviceKey(kind: .imageCapture, vendorID: vendor, serial: persistentID)
        }
        return nil
    }
}

/// One long-running `ICDeviceBrowser` for local cameras, shared by the watcher and the connector.
///
/// ImageCaptureCore delivers its callbacks on the main queue, so the browser is started there;
/// every process using it (app, helper, pulli-cli) keeps the main queue running.
public final class ICCDeviceBrowser: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    public static let shared = ICCDeviceBrowser()

    private let browser = ICDeviceBrowser()
    private let lock = NSLock()
    private var started = false
    private var enumerated = false
    private var found: [ICCCamera] = []

    /// Starts browsing; safe to call repeatedly.
    public func start() {
        let first = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard first else { return }
        DispatchQueue.main.async {
            self.browser.delegate = self
            let mask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
            self.browser.browsedDeviceTypeMask = mask
            self.browser.start()
        }
    }

    public func stop() {
        lock.withLock {
            started = false
            enumerated = false
            found.removeAll()
        }
        DispatchQueue.main.async {
            self.browser.stop()
            self.browser.delegate = nil
        }
    }

    /// Every camera attached now, phones or not.
    public var cameras: [ICCCamera] { lock.withLock { found } }

    /// The cameras Pulli offers as phones (see `ICCCamera.isPhoneCandidate`).
    public var phones: [ICCCamera] { cameras.filter(\.isPhoneCandidate) }

    /// Whether the first sweep of already-attached cameras is done.
    public var hasEnumerated: Bool { lock.withLock { enumerated } }

    public func camera(for key: DeviceKey) -> ICCCamera? {
        cameras.first { $0.key == key }
    }

    /// Waits until the first sweep is done and at least one camera is listed (`phonesOnly`: one
    /// phone), or `timeout` passes. Returns whatever is listed then.
    public func waitForCameras(timeout: Duration, phonesOnly: Bool = false) async -> [ICCCamera] {
        start()
        let deadline = ContinuousClock.now + timeout
        while true {
            let list = phonesOnly ? phones : cameras
            if hasEnumerated, !list.isEmpty { return list }
            if ContinuousClock.now >= deadline || Task.isCancelled { return list }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits for the first sweep only (a phone plugged in later shows up through `cameras`).
    public func waitForEnumeration(timeout: Duration) async {
        start()
        let deadline = ContinuousClock.now + timeout
        while !hasEnumerated, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: ICDeviceBrowserDelegate

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        lock.withLock {
            if !found.contains(where: { $0.device === camera }) { found.append(ICCCamera(device: camera)) }
        }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lock.withLock { found.removeAll { $0.device === device } }
    }

    public func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        lock.withLock { enumerated = true }
    }
}

/// One ImageCaptureCore session on a camera: opens it, waits for the complete catalogue, and
/// passes on removal and catalogue changes. Taken from the spike (`pulli-cli icc`).
public final class ICCCameraSession: NSObject, ICCameraDeviceDelegate, @unchecked Sendable {
    public let device: ICCameraDevice
    private let lock = NSLock()
    private var openContinuation: OnceContinuation<Duration>?
    private var sessionOpenStart: ContinuousClock.Instant?
    private var closing = false
    private var onRemoved: (@Sendable () -> Void)?
    private var onCatalogueChanged: (@Sendable () -> Void)?
    private var didBecomeReady = false
    private var catalogComplete = false
    private var quietTimer: DispatchWorkItem?
    private var overallTimeoutItem: DispatchWorkItem?
    private var quietPeriod: TimeInterval = 1.5

    public init(device: ICCameraDevice) {
        self.device = device
        super.init()
    }

    /// Whether ImageCaptureCore has finished enumerating the complete catalogue.
    public var isComplete: Bool { lock.withLock { catalogComplete } }

    /// `removed` runs when the phone leaves or Image Capture ends the session unasked;
    /// `catalogueChanged` when items are added or removed.
    public func setHandlers(removed: @escaping @Sendable () -> Void, catalogueChanged: @escaping @Sendable () -> Void) {
        lock.withLock {
            onRemoved = removed
            onCatalogueChanged = catalogueChanged
        }
    }

    /// Opens the session and returns once the catalogue is complete (how long that took).
    ///
    /// The catalogue is treated as complete when `contentCatalogPercentCompleted == 100`,
    /// `deviceDidBecomeReady(withCompleteContentCatalog:)` was received, and no items have been added
    /// for `quietPeriod`. If the device stalls, `catalogTimeout` answers with whatever items have
    /// been enumerated so far and keeps updating.
    public func open(catalogTimeout: TimeInterval = 120, quietPeriod: TimeInterval = 1.5) async throws -> Duration {
        let (alreadyComplete, start) = lock.withLock { () -> (Bool, ContinuousClock.Instant?) in
            if catalogComplete { return (true, sessionOpenStart) }
            self.quietPeriod = quietPeriod
            return (false, nil)
        }
        if alreadyComplete {
            return ContinuousClock.now - (start ?? .now)
        }

        return try await withCheckedThrowingContinuation { cont in
            let once = OnceContinuation(cont)
            lock.withLock {
                self.openContinuation = once
                self.sessionOpenStart = ContinuousClock.now
                self.closing = false
                self.didBecomeReady = false
                self.catalogComplete = false
                self.quietTimer?.cancel()
                self.quietTimer = nil
            }

            DispatchQueue.main.async {
                self.device.delegate = self
                self.device.requestOpenSession()
            }

            let timeoutItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finishTimeout()
            }
            lock.withLock {
                self.overallTimeoutItem?.cancel()
                self.overallTimeoutItem = timeoutItem
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + catalogTimeout, execute: timeoutItem)
        }
    }

    /// Closes the session; gives up waiting for Image Capture's answer after `timeout`.
    public func close(timeout: TimeInterval = 5) async {
        lock.withLock {
            closing = true
            quietTimer?.cancel()
            quietTimer = nil
            overallTimeoutItem?.cancel()
            overallTimeoutItem = nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let once = OnceContinuation(cont)
            guard device.hasOpenSession else {
                once.resume(returning: ())
                return
            }
            device.requestCloseSession(options: nil) { _ in once.resume(returning: ()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(returning: ()) }
        }
        DispatchQueue.main.async {
            if self.device.delegate === self { self.device.delegate = nil }
        }
    }

    private func finishTimeout() {
        let (once, start) = lock.withLock { () -> (OnceContinuation<Duration>?, ContinuousClock.Instant?) in
            guard openContinuation != nil else { return (nil, nil) }
            quietTimer?.cancel()
            quietTimer = nil
            overallTimeoutItem = nil
            catalogComplete = true
            let continuation = openContinuation
            openContinuation = nil
            return (continuation, sessionOpenStart)
        }
        once?.resume(returning: ContinuousClock.now - (start ?? .now))
    }

    private func evaluateCatalogueReadiness(itemsAdded: Bool = false) {
        guard openContinuation != nil else { return }
        let percent = device.contentCatalogPercentCompleted
        let ready = didBecomeReady && percent == 100

        if ready {
            quietTimer?.cancel()
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finishIfQuiet()
            }
            quietTimer = timer
            DispatchQueue.global().asyncAfter(deadline: .now() + quietPeriod, execute: timer)
        } else {
            quietTimer?.cancel()
            quietTimer = nil
        }
    }

    private func finishIfQuiet() {
        let (once, start) = lock.withLock { () -> (OnceContinuation<Duration>?, ContinuousClock.Instant?) in
            guard openContinuation != nil else { return (nil, nil) }
            guard didBecomeReady, device.contentCatalogPercentCompleted == 100 else { return (nil, nil) }
            quietTimer = nil
            overallTimeoutItem?.cancel()
            overallTimeoutItem = nil
            catalogComplete = true
            let continuation = openContinuation
            openContinuation = nil
            return (continuation, sessionOpenStart)
        }
        once?.resume(returning: ContinuousClock.now - (start ?? .now))
    }

    private func failOpen(_ error: any Error) {
        let once = lock.withLock { () -> OnceContinuation<Duration>? in
            quietTimer?.cancel()
            quietTimer = nil
            overallTimeoutItem?.cancel()
            overallTimeoutItem = nil
            defer { openContinuation = nil }
            return openContinuation
        }
        once?.resume(throwing: error)
    }

    // MARK: ICCameraDeviceDelegate & ICDeviceDelegate

    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error {
            failOpen(error)
        } else {
            lock.withLock { evaluateCatalogueReadiness() }
        }
    }

    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        lock.withLock {
            didBecomeReady = true
            evaluateCatalogueReadiness()
        }
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        failOpen(error ?? ICCError("The phone's session closed before its catalogue was complete."))
        let (asked, removed) = lock.withLock { (closing, onRemoved) }
        if !asked { removed?() }
    }

    public func didRemove(_ device: ICDevice) {
        failOpen(DeviceError.deviceGone)
        lock.withLock { onRemoved }?()
    }

    public func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        if let error { failOpen(error) }
    }

    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            evaluateCatalogueReadiness(itemsAdded: true)
            return onCatalogueChanged
        }
        notify?()
    }

    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        lock.withLock { onCatalogueChanged }?()
    }

    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        lock.withLock { onCatalogueChanged }?()
    }

    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}

/// Protects a continuation so it is resumed exactly once (completion, timeout or removal).
public final class OnceContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var plain: CheckedContinuation<T, Never>?

    public init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    public init(_ continuation: CheckedContinuation<T, Never>) {
        plain = continuation
    }

    public func resume(returning value: sending T) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        plain?.resume(returning: value)
        continuation = nil
        plain = nil
    }

    /// Ignored for a non-throwing continuation.
    public func resume(throwing error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Reads a byte range of a file with `requestReadData(atOffset:length:)` (no timeout of its own).
public func iccReadData(from file: ICCameraFile, offset: off_t, length: off_t) async throws -> Data {
    try await withCheckedThrowingContinuation { cont in
        let once = OnceContinuation(cont)
        file.requestReadData(atOffset: offset, length: length) { data, error in
            if let error {
                once.resume(throwing: error)
            } else if let data {
                once.resume(returning: data)
            } else {
                once.resume(throwing: ICCError("Read returned neither data nor error at offset \(offset)."))
            }
        }
    }
}

extension ICCameraItem {
    /// The item's folders and name, walking up its parent folders (`["DCIM", "Camera", "x.jpg"]`).
    public var catalogueComponents: [String] {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name) }
        var parent = parentFolder
        while let folder = parent {
            if let name = folder.name, !name.isEmpty { parts.append(name) }
            parent = folder.parentFolder
        }
        return parts.reversed()
    }

    /// `catalogueComponents` joined with slashes.
    public var cataloguePath: String { catalogueComponents.joined(separator: "/") }
}

extension ICCameraDevice {
    /// Every file once: the folder tree in `contents`, plus anything only in the flat
    /// `mediaFiles` list (in spike 1 the Fold7 gave everything there).
    public var allCameraFiles: [ICCameraFile] {
        var result: [ICCameraFile] = []
        var seen = Set<ObjectIdentifier>()

        func collect(_ items: [ICCameraItem]) {
            for item in items {
                if let file = item as? ICCameraFile {
                    if seen.insert(ObjectIdentifier(file)).inserted { result.append(file) }
                } else if let folder = item as? ICCameraFolder, let contents = folder.contents {
                    collect(contents)
                }
            }
        }

        collect(contents ?? [])
        collect(mediaFiles ?? [])
        return result
    }
}
