public import DeviceAPI
public import Foundation
import ImageCaptureCore
import Synchronization

/// Lists the phones ImageCaptureCore sees on USB, for the engine's `DeviceHub`. Opens nothing.
public struct ICCDeviceWatcher: DeviceWatcher {
    public let browser: ICCDeviceBrowser

    public init(browser: ICCDeviceBrowser = .shared) {
        self.browser = browser
    }

    public func currentDevices() async -> [DeviceCandidate] {
        browser.start()
        // Image Capture shares the phone between apps (Photos may have it open too), so it is
        // never "held"; whether it shows any files is only known once a session is open.
        return browser.phones.compactMap { camera in
            camera.key.map { DeviceCandidate(key: $0, usb: camera.usb, hasFileTransferInterface: true, heldByApp: nil) }
        }
    }
}

/// Opens `ICCSession`s through ImageCaptureCore, which goes through macOS's camera service
/// instead of stopping it, so it works inside the App Sandbox (docs/APP_STORE.md).
public final class ICCDeviceConnector: DeviceConnector {
    public let browser: ICCDeviceBrowser
    /// The Mac's time zone, for the phone's wall-clock dates (pulli-cli runs in UTC for libmtp).
    public let timeZone: TimeZone
    public let catalogueTimeout: TimeInterval
    public let callTimeout: Duration

    private static let epochs = Mutex<UInt64>(0)
    /// The open session per phone: a new open closes it first, as Image Capture allows one
    /// session per device and process.
    private let live = Mutex<[DeviceKey: WeakSession]>([:])

    public init(browser: ICCDeviceBrowser = .shared, timeZone: TimeZone = .current, catalogueTimeout: TimeInterval = 120,
                callTimeout: Duration = .seconds(30)) {
        self.browser = browser
        self.timeZone = timeZone
        self.catalogueTimeout = catalogueTimeout
        self.callTimeout = callTimeout
    }

    /// Throws `.noStorage` when the catalogue is empty: the phone is in "File transfer" mode
    /// (show `ICCGuidance.chooseTransferringImages`), locked, or has no photos.
    public func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        await browser.waitForEnumeration(timeout: .seconds(5))
        guard let camera = browser.camera(for: key) else { throw .deviceGone }
        if let previous = live.withLock({ $0.removeValue(forKey: key)?.session }) { await previous.close() }

        let backend = ImageCaptureCamera(camera.device)
        do {
            _ = try await backend.session.open(catalogTimeout: catalogueTimeout)
        } catch {
            await backend.close()
            let removed = browser.camera(for: key) == nil
            throw ICCErrorMapping.deviceError(error, deviceRemoved: removed)
        }

        let epoch = Self.epochs.withLock { $0 += 1; return $0 }
        let info = DeviceInfo(key: key, usb: camera.usb, manufacturer: nil, model: camera.name, friendlyName: nil,
                              mtpSerial: camera.device.serialNumberString, readStrategy: .partial64)
        let session = ICCSession(backend: backend, info: info, epoch: SessionEpoch(rawValue: epoch), timeZone: timeZone,
                                 callTimeout: callTimeout)
        try await Self.requireMedia(session)
        live.withLock { $0[key] = WeakSession(session) }
        return session
    }

    /// A session whose catalogue is empty is closed: in "File transfer" mode Image Capture sees
    /// the phone but no files, and only a fresh session after switching mode would show them.
    static func requireMedia(_ session: ICCSession) async throws(DeviceError) {
        let storages: [StorageInfo]
        do throws(DeviceError) {
            storages = try await session.storages()
        } catch {
            await session.close()
            throw error
        }
        if storages.isEmpty {
            await session.close()
            throw .noStorage
        }
    }
}

private struct WeakSession: Sendable {
    weak var session: ICCSession?
    init(_ session: ICCSession) { self.session = session }
}

/// `ICCCameraBackend` over a real `ICCameraDevice`.
final class ImageCaptureCamera: ICCCameraBackend, @unchecked Sendable {
    let device: ICCameraDevice
    let session: ICCCameraSession
    private let lock = NSLock()
    /// Item IDs by object, so an item keeps its ID when the catalogue is read again.
    private var ids: [ObjectIdentifier: Int] = [:]
    private var files: [Int: ICCameraFile] = [:]

    init(_ device: ICCameraDevice) {
        self.device = device
        session = ICCCameraSession(device: device)
    }

    func catalogue() -> [ICCCatalogueEntry] {
        let all = device.allCameraFiles
        return lock.withLock {
            all.map { file in
                let id = ids[ObjectIdentifier(file)] ?? {
                    let id = ids.count + 1
                    ids[ObjectIdentifier(file)] = id
                    return id
                }()
                files[id] = file
                return ICCCatalogueEntry(id: id, components: file.catalogueComponents, size: UInt64(max(0, file.fileSize)),
                                         modified: file.fileModificationDate ?? file.modificationDate ?? file.fileCreationDate ?? file.creationDate)
            }
        }
    }

    func read(_ id: Int, offset: UInt64, length: Int, completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        guard let file = lock.withLock({ files[id] }) else {
            completion(nil, DeviceError.rejected("object no longer exists"))
            return
        }
        file.requestReadData(atOffset: off_t(offset), length: off_t(length)) { data, error in completion(data, error) }
    }

    func thumbnail(_ id: Int, completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        guard let file = lock.withLock({ files[id] }) else {
            completion(nil, nil)
            return
        }
        file.requestThumbnailData(options: nil) { data, error in completion(data, error) }
    }

    func waitForCatalogue(timeout: Duration) async throws {
        _ = try await session.open(catalogTimeout: timeout.timeInterval)
    }

    func setHandlers(removed: @escaping @Sendable () -> Void, catalogueChanged: @escaping @Sendable () -> Void) {
        session.setHandlers(removed: removed, catalogueChanged: catalogueChanged)
    }

    func close() async {
        await session.close()
    }
}
