import DeviceAPI
import Foundation
@testable import ICCKit
import ImageCaptureCore
import Synchronization
import Testing
import TransferCore

private func item(_ id: Int, _ path: String, size: UInt64 = 100, mtime: Int64 = 1_760_000_000) -> ICCCatalogueItem {
    ICCCatalogueItem(id: id, components: path.split(separator: "/").map(String.init), size: size, modifiedWallClock: mtime)
}

private func names(_ index: ICCFolderIndex, _ folder: RemotePath) -> [String] {
    index.folders[folder]?.map { $0.isFolder ? $0.name + "/" : $0.name } ?? []
}

@Suite struct FolderSynthesisTests {
    @Test func nestedPathsBecomeFolders() {
        let index = ICCFolderIndex([
            item(1, "DCIM/Camera/20260901_090000.jpg"),
            item(2, "DCIM/Camera/20260901_183000.mp4"),
            item(3, "Pictures/Screenshots/Screenshot_1.png"),
            item(4, "Pictures/WhatsApp/Images/IMG-1.jpg"),
        ])
        #expect(names(index, .root) == ["DCIM/", "Pictures/"])
        #expect(names(index, "DCIM") == ["Camera/"])
        #expect(names(index, "DCIM/Camera") == ["20260901_090000.jpg", "20260901_183000.mp4"])
        #expect(names(index, "Pictures") == ["Screenshots/", "WhatsApp/"])
        #expect(names(index, "Pictures/WhatsApp") == ["Images/"])
        #expect(index.node(at: "Pictures/WhatsApp/Images/IMG-1.jpg") == .file(itemID: 4))
        #expect(index.node(at: "Pictures/WhatsApp") == .folder)
        #expect(index.node(at: .root) == .folder)
        #expect(index.node(at: "Pictures/Nothing") == nil)
        #expect(index.paths[3] == "Pictures/Screenshots/Screenshot_1.png")
    }

    @Test func rootFilesAndFoldersSortFoldersFirstInFinderOrder() {
        let index = ICCFolderIndex([
            item(1, "IMG_10.jpg"), item(2, "img_2.jpg"), item(3, "Zeta/a.jpg"), item(4, "DCIM/b.jpg"), item(5, "IMG_9.jpg"),
        ])
        #expect(names(index, .root) == ["DCIM/", "Zeta/", "img_2.jpg", "IMG_9.jpg", "IMG_10.jpg"])
        #expect(index.node(at: "IMG_10.jpg") == .file(itemID: 1))
    }

    @Test func duplicatePathsAreKeptWithNumbers() {
        // Internal storage and SD card can both hold DCIM/Camera/IMG_0001.jpg.
        let index = ICCFolderIndex([
            item(1, "DCIM/Camera/IMG_0001.jpg", size: 10),
            item(2, "DCIM/Camera/IMG_0001.jpg", size: 20),
            item(3, "DCIM/Camera/IMG_0001.jpg", size: 30),
            item(4, "DCIM/Camera/.hidden", size: 1),
            item(5, "DCIM/Camera/.hidden", size: 2),
            item(6, "DCIM/Camera/README", size: 3),
            item(7, "DCIM/Camera/README", size: 4),
        ])
        #expect(names(index, "DCIM/Camera") == [".hidden", ".hidden (2)", "IMG_0001 (2).jpg", "IMG_0001 (3).jpg", "IMG_0001.jpg",
                                                 "README", "README (2)"])
        #expect(index.paths[1] == "DCIM/Camera/IMG_0001.jpg")
        #expect(index.paths[2] == "DCIM/Camera/IMG_0001 (2).jpg")
        #expect(index.paths[3] == "DCIM/Camera/IMG_0001 (3).jpg")
        #expect(index.items.count == 7)
    }

    @Test func fileNamedLikeAFolderKeepsBoth() {
        let index = ICCFolderIndex([item(1, "DCIM"), item(2, "DCIM/Camera/a.jpg")])
        #expect(names(index, .root) == ["DCIM/", "DCIM (2)"])
        #expect(index.node(at: "DCIM") == .folder)
        #expect(index.node(at: "DCIM (2)") == .file(itemID: 1))
    }

    @Test func oddNamesStayReachable() {
        let index = ICCFolderIndex([
            ICCCatalogueItem(id: 1, components: ["DCIM", "", "a/b.jpg"], size: 1, modifiedWallClock: 0),
            ICCCatalogueItem(id: 2, components: [], size: 1, modifiedWallClock: 0),
        ])
        #expect(index.node(at: "DCIM/a_b.jpg") == .file(itemID: 1))
        #expect(index.node(at: "Untitled") == .file(itemID: 2))
    }

    @Test func namesAreComparedByteForByte() {
        // NFC and NFD "é" are two different files on a phone.
        let index = ICCFolderIndex([item(1, "Pictures/caf\u{E9}.jpg"), item(2, "Pictures/cafe\u{301}.jpg")])
        #expect(index.folders["Pictures"]?.count == 2)
        #expect(index.node(at: RemotePath("Pictures/caf\u{E9}.jpg")) == .file(itemID: 1))
        #expect(index.node(at: RemotePath("Pictures/cafe\u{301}.jpg")) == .file(itemID: 2))
    }

    @Test func emptyCatalogue() {
        let index = ICCFolderIndex([])
        #expect(index.isEmpty)
        #expect(index.folders[.root] == [])
    }

    @Test func wallClockIsThePhonesLocalTime() {
        // 2026-09-17 08:19:27 in Berlin (CEST, UTC+2) is 06:19:27 UTC.
        let berlin = TimeZone(identifier: "Europe/Berlin")!
        let date = Date(timeIntervalSince1970: 1_789_625_967)
        #expect(ICCCatalogueItem.wallClock(date, timeZone: berlin) == 1_789_625_967 + 7_200)
        #expect(ICCCatalogueItem.wallClock(date, timeZone: TimeZone(identifier: "UTC")!) == 1_789_625_967)
        #expect(ICCCatalogueItem.wallClock(nil, timeZone: berlin) == 0)
    }
}

@Suite struct ICCIdentityTests {
    @Test func usbSerialGivesTheSameKeyAsLibmtp() {
        #expect(ICCIdentity.key(vendorID: 0x04e8, serial: "R5CY12ABCDE", persistentID: "0x00140000") ==
            DeviceKey(kind: .usb, vendorID: 0x04e8, serial: "R5CY12ABCDE"))
    }

    @Test func junkSerialFallsBackToPersistentID() {
        let key = ICCIdentity.key(vendorID: 0x17ef, serial: "0123456789ABCDEF", persistentID: "0x00140000")
        #expect(key == DeviceKey(kind: .imageCapture, vendorID: 0x17ef, serial: "0x00140000"))
        #expect(key.flatMap { DeviceKey(parsing: $0.description) } == key)
        #expect(ICCIdentity.key(vendorID: 0x17ef, serial: nil, persistentID: nil) == nil)
    }
}

@Suite struct ICCErrorMappingTests {
    private func ic(_ code: Int) -> NSError { NSError(domain: ICErrorDomain, code: code) }

    @Test func removalWins() {
        #expect(ICCErrorMapping.deviceError(ic(-9923), deviceRemoved: true) == .deviceGone)
    }

    @Test(arguments: [-21350, -21349, -21348, -9958])
    func connectionLossIsDeviceGone(_ code: Int) {
        #expect(ICCErrorMapping.deviceError(ic(code)) == .deviceGone)
    }

    @Test func timeoutsAndBusyAreTransient() {
        for code in [-9923, -9954, -9956, -21448] {
            guard case .transient = ICCErrorMapping.deviceError(ic(code)) else {
                Issue.record("\(code) should be transient")
                continue
            }
        }
        guard case .transient = ICCErrorMapping.deviceError(ICCError("Timed out waiting for the phone's catalogue")) else {
            Issue.record("our own timeout should be transient")
            return
        }
    }

    @Test func lockedIsNoStorage() {
        #expect(ICCErrorMapping.deviceError(ic(-9943)) == .noStorage)
    }

    @Test func refusalsAreNotRetried() {
        #expect(ICCErrorMapping.deviceError(ic(-21450)) == .rejected("object no longer exists"))
        guard case .rejected = ICCErrorMapping.deviceError(ic(-21343)) else { Issue.record("not authorised"); return }
        guard case .unsupported = ICCErrorMapping.deviceError(ic(-21446)) else { Issue.record("too large"); return }
    }

    @Test func otherErrorsPassThroughOrAreTransient() {
        #expect(ICCErrorMapping.deviceError(DeviceError.staleHandle) == .staleHandle)
        guard case .transient = ICCErrorMapping.deviceError(NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))) else {
            Issue.record("unknown errors should be retried"); return
        }
        #expect(ICCErrorMapping.deviceError(CancellationError()) == .transient("cancelled"))
    }
}

// MARK: - A fake camera shaped like ImageCaptureCore: a flat catalogue and ranged reads

/// Answers reads asynchronously like Image Capture. A "cable pull" removes the phone and leaves
/// the read in flight unanswered, as Image Capture may.
final class FakeCamera: ICCCameraBackend, @unchecked Sendable {
    struct File {
        var components: [String]
        var content: Data
        var modified: Date
    }

    struct Read: Sendable {
        var id: Int
        var offset: UInt64
        var length: Int
        var plug: Int
    }

    private let lock = NSLock()
    private var files: [Int: File]
    private var removed: (@Sendable () -> Void)?
    private var catalogueChanged: (@Sendable () -> Void)?
    private var plugged = true
    var pluggedIn: Bool { lock.withLock { plugged } }
    /// Pull the cable once this many bytes were served since the last plug.
    var pullAfterBytes: UInt64?
    /// Never answer reads (a stalled phone).
    var silent = false
    private var servedSincePlug: UInt64 = 0
    private var plugCount = 1
    private var readLog: [Read] = []

    private var isReady = true
    private var percent = 100
    private var complete = true
    private var quietPeriod: Duration = .milliseconds(50)
    private var quietTask: Task<Void, Never>?
    private var completionContinuations: [CheckedContinuation<Void, any Error>] = []

    var plugs: Int { lock.withLock { plugCount } }
    var reads: [Read] { lock.withLock { readLog } }
    var isCatalogueComplete: Bool { lock.withLock { complete } }

    init(_ files: [String: Data], modified: Date = Date(timeIntervalSince1970: 1_789_625_967),
         isReady: Bool = true, percent: Int = 100, complete: Bool = true, quietPeriod: Duration = .milliseconds(50)) {
        var table: [Int: File] = [:]
        for (offset, (path, content)) in files.sorted(by: { $0.key < $1.key }).enumerated() {
            table[offset + 1] = File(components: path.split(separator: "/").map(String.init), content: content, modified: modified)
        }
        self.files = table
        self.isReady = isReady
        self.percent = percent
        self.complete = complete
        self.quietPeriod = quietPeriod
    }

    func waitForCatalogue(timeout: Duration) async throws {
        let (already, plugged) = lock.withLock { (complete, self.plugged) }
        guard plugged else { throw DeviceError.deviceGone }
        if already { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                    let registered = self.lock.withLock { () -> Bool in
                        if self.complete { return false }
                        self.completionContinuations.append(cont)
                        return true
                    }
                    if !registered { cont.resume(returning: ()) }
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                self.lock.withLock {
                    self.complete = true
                    let waiters = self.completionContinuations
                    self.completionContinuations.removeAll()
                    for waiter in waiters { waiter.resume(returning: ()) }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    func setReady(_ ready: Bool) {
        lock.withLock {
            isReady = ready
            evaluateCompleteness()
        }
    }

    func setPercent(_ newPercent: Int) {
        lock.withLock {
            percent = newPercent
            evaluateCompleteness()
        }
    }

    func addBatch(_ newFiles: [String: Data], percent newPercent: Int? = nil, modified: Date = Date(timeIntervalSince1970: 1_789_625_967)) {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            for (path, content) in newFiles.sorted(by: { $0.key < $1.key }) {
                let id = files.count + 1
                files[id] = File(components: path.split(separator: "/").map(String.init), content: content, modified: modified)
            }
            if let newPercent {
                percent = newPercent
            }
            evaluateCompleteness(itemsAdded: true)
            return catalogueChanged
        }
        notify?()
    }

    private func evaluateCompleteness(itemsAdded: Bool = false) {
        guard !complete else { return }
        quietTask?.cancel()
        quietTask = nil
        guard isReady && percent == 100 else { return }

        let period = quietPeriod
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: period)
            guard !Task.isCancelled, let self else { return }
            self.lock.withLock {
                guard self.isReady && self.percent == 100 && !self.complete else { return }
                self.complete = true
                let waiters = self.completionContinuations
                self.completionContinuations.removeAll()
                for waiter in waiters { waiter.resume(returning: ()) }
            }
        }
    }

    func content(_ path: String) -> Data? {
        lock.withLock {
            files.values.first { $0.components.joined(separator: "/") == path }?.content
        }
    }

    func catalogue() -> [ICCCatalogueEntry] {
        lock.withLock {
            files.sorted { $0.key < $1.key }.map {
                ICCCatalogueEntry(id: $0.key, components: $0.value.components, size: UInt64($0.value.content.count), modified: $0.value.modified)
            }
        }
    }

    func read(_ id: Int, offset: UInt64, length: Int, completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        let (outcome, notify) = lock.withLock { () -> (Result<Data, NSError>?, (@Sendable () -> Void)?) in
            readLog.append(Read(id: id, offset: offset, length: length, plug: plugCount))
            guard plugged else { return (.failure(NSError(domain: ICErrorDomain, code: -21348)), nil) }
            if silent { return (nil, nil) }
            if let limit = pullAfterBytes, servedSincePlug >= limit {
                plugged = false
                return (nil, removed)
            }
            guard let file = files[id] else { return (.failure(NSError(domain: ICErrorDomain, code: -21450)), nil) }
            let start = Int(min(offset, UInt64(file.content.count)))
            let end = min(start + length, file.content.count)
            servedSincePlug += UInt64(end - start)
            return (.success(file.content.subdata(in: start..<end)), nil)
        }
        notify?()
        guard let outcome else { return }
        DispatchQueue.global().async {
            switch outcome {
            case .success(let data): completion(data, nil)
            case .failure(let error): completion(nil, error)
            }
        }
    }

    func thumbnail(_ id: Int, completion: @escaping @Sendable (Data?, (any Error)?) -> Void) {
        completion(nil, NSError(domain: ICErrorDomain, code: -21000))
    }

    func setHandlers(removed: @escaping @Sendable () -> Void, catalogueChanged: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.removed = removed
            self.catalogueChanged = catalogueChanged
        }
    }

    func plug() {
        lock.withLock {
            guard !plugged else { return }
            plugged = true
            pullAfterBytes = nil
            servedSincePlug = 0
            plugCount += 1
        }
    }

    func close() async {
        quietTask?.cancel()
        quietTask = nil
    }
}

/// Opens `ICCSession`s on the fake, as `ICCDeviceConnector` does on a real phone.
final class FakeConnector: DeviceConnector {
    let camera: FakeCamera
    let key = DeviceKey(kind: .usb, vendorID: 0x04e8, serial: "R5CYFAKE0001")
    let catalogueTimeout: TimeInterval
    private let epochs = Mutex<UInt64>(0)

    init(camera: FakeCamera, catalogueTimeout: TimeInterval = 5) {
        self.camera = camera
        self.catalogueTimeout = catalogueTimeout
    }

    func session() -> ICCSession {
        let usb = USBDeviceSummary(vendorID: 0x04e8, productID: 0x6860, vendorName: nil, productName: "Galaxy Z Fold7", usbSerial: key.serial,
                                   locationID: 0, address: 0, linkSpeedBitsPerSecond: nil)
        let info = DeviceInfo(key: key, usb: usb, manufacturer: nil, model: "Galaxy Z Fold7", friendlyName: nil, mtpSerial: nil,
                              readStrategy: .partial64)
        let epoch = epochs.withLock { $0 += 1; return $0 }
        return ICCSession(backend: camera, info: info, epoch: SessionEpoch(rawValue: epoch), timeZone: TimeZone(identifier: "Europe/Berlin")!,
                          callTimeout: .seconds(5))
    }

    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        guard key == self.key, camera.pluggedIn else { throw .deviceGone }
        do {
            try await camera.waitForCatalogue(timeout: .seconds(catalogueTimeout))
        } catch let error as DeviceError {
            throw error
        } catch {
            throw ICCErrorMapping.deviceError(error, deviceRemoved: !camera.pluggedIn)
        }
        let session = session()
        try await ICCDeviceConnector.requireMedia(session)
        return session
    }
}

/// Deterministic bytes, different per file.
private func bytes(_ count: Int, seed: UInt8) -> Data {
    Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &+ $0 >> 9) })
}

@Suite struct ICCSessionTests {
    @Test func oneStorageWithSynthesisedFolders() async throws {
        let camera = FakeCamera(["DCIM/Camera/a.jpg": bytes(1000, seed: 1), "Pictures/Screenshots/s.png": bytes(10, seed: 2)])
        let connector = FakeConnector(camera: camera)
        let session = connector.session()
        let storages = try await session.storages()
        #expect(storages.map(\.description) == ["Photos and videos"])
        #expect(storages.first?.capacityBytes == nil)

        var root: [RemoteEntry] = []
        for try await page in session.list(.root, storage: ICCSession.storageID) { root += page }
        #expect(root.map(\.name) == ["DCIM", "Pictures"])
        #expect(root.allSatisfy { $0.isFolder })

        let entry = try #require(try await session.stat("DCIM/Camera/a.jpg", storage: ICCSession.storageID))
        #expect(entry.size == 1000)
        #expect(entry.modifiedWallClock == 1_789_625_967 + 7_200)
        #expect(try await session.stat("DCIM/Camera", storage: ICCSession.storageID)?.isFolder == true)
        #expect(try await session.stat("DCIM/Nope.jpg", storage: ICCSession.storageID) == nil)
        #expect(try await session.stat(.root, storage: ICCSession.storageID) == nil)

        // Ranged reads, short at the end, empty past it.
        #expect(try await session.read(entry.ref, offset: 990, maxLength: 64) == bytes(1000, seed: 1).subdata(in: 990..<1000))
        #expect(try await session.read(entry.ref, offset: 1000, maxLength: 64).isEmpty)
        // The same item keeps its handle; a handle from an earlier session is refused.
        #expect(try await session.stat("DCIM/Camera/a.jpg", storage: ICCSession.storageID)?.ref == entry.ref)
        let later = connector.session()
        await #expect(throws: DeviceError.staleHandle) { try await later.read(entry.ref, offset: 0, maxLength: 10) }

        await #expect(throws: DeviceError.self) {
            for try await _ in session.list("DCIM/Camera/a.jpg", storage: ICCSession.storageID) {}
        }
        #expect(try await session.thumbnail(entry.ref) == nil)
    }

    @Test func writingIsUnsupported() async throws {
        let camera = FakeCamera(["DCIM/Camera/a.jpg": bytes(10, seed: 1)])
        let session = FakeConnector(camera: camera).session()
        let entry = try #require(try await session.stat("DCIM/Camera/a.jpg", storage: ICCSession.storageID))
        func expectUnsupported(_ body: () async throws -> Void) async {
            do {
                try await body()
                Issue.record("should have thrown")
            } catch {
                guard case .unsupported? = error as? DeviceError else { Issue.record("\(error)"); return }
            }
        }
        await expectUnsupported { try await session.delete(entry.ref) }
        await expectUnsupported { try await session.rename(entry.ref, to: "b.jpg") }
        await expectUnsupported { _ = try await session.makeFolder("New", in: .root, storage: ICCSession.storageID) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-icc-upload-\(UUID().uuidString)")
        await expectUnsupported { _ = try await session.upload(file, as: "x", into: .root, storage: ICCSession.storageID) { _ in } }
    }

    @Test func emptyCatalogueMeansNoStorage() async throws {
        let camera = FakeCamera([:])
        let connector = FakeConnector(camera: camera)
        #expect(try await connector.session().storages().isEmpty)
        await #expect(throws: DeviceError.noStorage) { _ = try await connector.open(connector.key) }
        #expect(ICCGuidance.chooseTransferringImages.contains("Transferring images"))
    }

    @Test func removalFailsTheReadInFlightAndEverythingAfter() async throws {
        let camera = FakeCamera(["DCIM/Camera/v.mp4": bytes(1 << 20, seed: 3)])
        camera.pullAfterBytes = 0
        let session = FakeConnector(camera: camera).session()
        let entry = try #require(try await session.stat("DCIM/Camera/v.mp4", storage: ICCSession.storageID))
        await #expect(throws: DeviceError.deviceGone) { try await session.read(entry.ref, offset: 0, maxLength: 4096) }
        await #expect(throws: DeviceError.deviceGone) { try await session.storages() }
    }

    @Test func aSilentPhoneTimesOutAsTransient() async throws {
        let camera = FakeCamera(["DCIM/Camera/v.mp4": bytes(4096, seed: 3)])
        camera.silent = true
        let usb = USBDeviceSummary(vendorID: 1, productID: 1, vendorName: nil, productName: nil, usbSerial: nil, locationID: 0, address: 0,
                                   linkSpeedBitsPerSecond: nil)
        let info = DeviceInfo(key: DeviceKey(kind: .imageCapture, vendorID: 1, serial: "x"), usb: usb, manufacturer: nil, model: nil,
                              friendlyName: nil, mtpSerial: nil, readStrategy: .partial64)
        let session = ICCSession(backend: camera, info: info, epoch: SessionEpoch(rawValue: 900), callTimeout: .milliseconds(50))
        let entry = try #require(try await session.stat("DCIM/Camera/v.mp4", storage: ICCSession.storageID))
        do throws(DeviceError) {
            _ = try await session.read(entry.ref, offset: 0, maxLength: 4096)
            Issue.record("should have timed out")
        } catch {
            guard case .transient = error else { Issue.record("\(error)"); return }
        }
    }

    @Test func itemsArrivingInBatchesAfterReadyAreAllListed() async throws {
        let camera = FakeCamera([:], isReady: false, percent: 0, complete: false, quietPeriod: .milliseconds(40))
        let connector = FakeConnector(camera: camera, catalogueTimeout: 2)

        let openTask = Task {
            try await connector.open(connector.key)
        }

        // Ready signal arrived, but percent is still 0
        camera.setReady(true)
        #expect(!camera.isCatalogueComplete)

        // First batch arrives
        camera.addBatch(["DCIM/Camera/photo1.jpg": bytes(100, seed: 1)], percent: 30)
        #expect(!camera.isCatalogueComplete)

        // Second batch arrives
        camera.addBatch(["DCIM/Camera/photo2.jpg": bytes(200, seed: 2)], percent: 70)
        #expect(!camera.isCatalogueComplete)

        // Third batch arrives with screenshots and percent reaches 100
        camera.addBatch(["DCIM/Screenshots/shot1.png": bytes(300, seed: 3)], percent: 100)

        // Completes after the quiet period
        let session = try await openTask.value
        #expect(camera.isCatalogueComplete)

        var cameraFiles: [RemoteEntry] = []
        for try await page in session.list("DCIM/Camera", storage: ICCSession.storageID) {
            cameraFiles += page
        }
        #expect(cameraFiles.map(\.name) == ["photo1.jpg", "photo2.jpg"])

        var screenshotFiles: [RemoteEntry] = []
        for try await page in session.list("DCIM/Screenshots", storage: ICCSession.storageID) {
            screenshotFiles += page
        }
        #expect(screenshotFiles.map(\.name) == ["shot1.png"])
    }

    @Test func emptyCompleteCatalogueThrowsNoStorageAfterQuietPeriod() async throws {
        let camera = FakeCamera([:], isReady: true, percent: 100, complete: false, quietPeriod: .milliseconds(30))
        let connector = FakeConnector(camera: camera, catalogueTimeout: 2)

        #expect(!camera.isCatalogueComplete)
        await #expect(throws: DeviceError.noStorage) {
            _ = try await connector.open(connector.key)
        }
        #expect(camera.isCatalogueComplete)
    }

    @Test func percentStuckBelow100AnswersViaTimeoutPath() async throws {
        let camera = FakeCamera(["DCIM/Camera/stuck.jpg": bytes(100, seed: 4)], isReady: true, percent: 50, complete: false,
                                quietPeriod: .milliseconds(50))
        let connector = FakeConnector(camera: camera, catalogueTimeout: 0.1)

        let session = try await connector.open(connector.key)
        #expect(camera.isCatalogueComplete)

        let entry = try #require(try await session.stat("DCIM/Camera/stuck.jpg", storage: ICCSession.storageID))
        #expect(entry.size == 100)

        // When more items arrive later, catalogueChanged notifies and updates the listing
        let changed = Mutex(0)
        session.onContentChanged = { changed.withLock { $0 += 1 } }
        camera.addBatch(["DCIM/Camera/late.jpg": bytes(200, seed: 5)])
        #expect(changed.withLock { $0 } > 0)
        #expect(try await session.stat("DCIM/Camera/late.jpg", storage: ICCSession.storageID) != nil)
    }
}

// MARK: - The engine on ImageCaptureCore's shape

@Suite struct ICCTransferTests {
    @Test func supervisorCopiesAndResumesAfterACablePull() async throws {
        let video = bytes(13 << 20 + 12_345, seed: 7)
        let camera = FakeCamera([
            "DCIM/Camera/20260917_081927.mp4": video,
            "DCIM/Camera/20260917_081000.jpg": bytes(300_000, seed: 8),
            "Pictures/Screenshots/Screenshot_1.png": bytes(40_000, seed: 9),
            "Pictures/Screenshots/Screenshot_2.png": bytes(41_000, seed: 10),
        ])
        let connector = FakeConnector(camera: camera)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-icc-tests-\(UUID().uuidString)")
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try Journal(url: root.appendingPathComponent("journal.sqlite"))

        // Select folders, as `pulli-cli copy /DCIM /Pictures …` does.
        let first = try await connector.open(connector.key)
        var items: [BatchItem] = []
        for path in ["DCIM", "Pictures"] as [RemotePath] {
            items.append(BatchItem(try #require(try await first.stat(path, storage: ICCSession.storageID)), at: path))
        }
        let batch = try journal.createBatch(deviceKey: connector.key, storageID: ICCSession.storageID, destinationRoot: destination, items: items)

        var configuration = TransferConfiguration()
        configuration.chunkBytes = 1 << 20
        configuration.commitBytes = ChainDigest.blockSize
        configuration.commitInterval = .seconds(3600)
        configuration.tailGuardBytes = 256 << 10
        configuration.destinationTimeZone = TimeZone(identifier: "Europe/Berlin")!

        // The cable is pulled 9 MiB into the run; "waiting" plugs it back in.
        camera.pullAfterBytes = 9 << 20
        var supervisor = TransferSupervisor(connector: connector, journal: journal, sink: POSIXFileSink(), configuration: configuration)
        let sleeps = Mutex(0)
        supervisor.sleep = { _ in
            if sleeps.withLock({ $0 += 1; return $0 }) > 1_000 { throw CancellationError() }
            camera.plug()
            await Task.yield()
        }
        let totals = try await supervisor.run(batchID: batch.id!, session: first)

        #expect(totals.filesDone == 4)
        #expect(totals.filesNeedingAttention == 0)
        #expect(camera.plugs == 2)
        for job in try journal.jobs(batchID: batch.id!) {
            let copied = try Data(contentsOf: job.destinationURL)
            #expect(copied == camera.content(job.sourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))), "\(job.sourcePath)")
        }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("DCIM/Camera/20260917_081927.mp4").path))

        // Resumed from the last commit (4 or 8 MiB, less the tail check), not from the start.
        let videoID = try #require(camera.catalogue().first { $0.components.last == "20260917_081927.mp4" }?.id)
        let afterReplug = camera.reads.filter { $0.id == videoID && $0.plug == 2 }
        let firstOffset = try #require(afterReplug.map(\.offset).min())
        #expect(firstOffset >= (4 << 20) - (256 << 10))
        let videoBytesRead = camera.reads.filter { $0.id == videoID }.reduce(0) { $0 + UInt64($1.length) }
        #expect(videoBytesRead < UInt64(video.count) + (6 << 20))
    }
}
