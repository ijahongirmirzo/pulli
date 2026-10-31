import DeviceAPI
import Foundation
@testable import HelperCore
import MockDevice
import PulliProtocol
import Testing

/// The phone drive over real HTTP (URLSession), against the simulated phone. Set
/// PULLI_MOUNT_TEST=1 to also mount it with macOS's own WebDAV client and use it like Finder.
@Suite(.serialized) struct PhoneDriveTests {
    static func phone() -> MockDevice {
        let device = MockDevice(serial: "DRIVE1")
        device.addFile("DCIM/Camera/a.jpg", size: 300_000)
        device.addFile("DCIM/Camera/clip.mp4", size: 5_000_000)
        device.addFile("Download/doc.pdf", size: 50_000)
        return device
    }

    private func request(_ url: URL, _ method: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Int, Data, [AnyHashable: Any]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    private func start(_ harness: Harness, _ device: MockDevice) async throws -> URL {
        _ = try await harness.wait("phone ready") { $0.devices[device.key.description]?.state == .ready }
        guard case .drive(let url) = try await harness.client.send(.startDrive(deviceID: device.key.description)) else { throw PulliError(.unknown, "no drive") }
        return URL(string: url)!
    }

    @Test func browsesAndReadsRanges() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)

        let (status, body, _) = try await request(root.appendingPathComponent("DCIM/Camera/"), "PROPFIND", headers: ["Depth": "1"])
        #expect(status == 207)
        let xml = String(decoding: body, as: UTF8.self)
        #expect(xml.contains("<D:displayname>a.jpg</D:displayname>"))
        #expect(xml.contains("<D:getcontentlength>5000000</D:getcontentlength>"))
        #expect(xml.contains("<D:collection/>"))

        let expected = try #require(device.expectedContent("DCIM/Camera/clip.mp4"))
        let (partial, bytes, headers) = try await request(root.appendingPathComponent("DCIM/Camera/clip.mp4"), "GET", headers: ["Range": "bytes=1000-1999"])
        #expect(partial == 206)
        #expect(bytes == expected[1000..<2000])
        #expect(headers["Content-Range"] as? String == "bytes 1000-1999/5000000")
        let (whole, all, _) = try await request(root.appendingPathComponent("DCIM/Camera/a.jpg"), "GET")
        #expect(whole == 200)
        #expect(all == device.expectedContent("DCIM/Camera/a.jpg"))

        let (outside, _, _) = try await request(URL(string: "http://127.0.0.1:\(root.port!)/wrongtoken/x/")!, "PROPFIND")
        #expect(outside == 404)
    }

    @Test func writesLikeFinderAndGuardsDeletes() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)
        let target = root.appendingPathComponent("Download/new.txt")

        // Finder: an empty PUT, a lock, the content, an unlock; and its own ._ file.
        #expect(try await request(target, "PUT", body: Data()).0 == 201)
        #expect(try await request(target, "LOCK", body: Data("<lockinfo/>".utf8)).0 == 200)
        #expect(try await request(target, "PUT", body: Data(repeating: 65, count: 12_345)).0 == 204)
        #expect(try await request(target, "UNLOCK").0 == 204)
        #expect(try await request(root.appendingPathComponent("Download/._new.txt"), "PUT", body: Data([1, 2, 3])).0 == 201)
        #expect(device.file("Download/new.txt")?.size == 12_345)
        #expect(device.file("Download/._new.txt") == nil, "Finder's own files never reach the phone")

        #expect(try await request(root.appendingPathComponent("Download/Trip/"), "MKCOL").0 == 201)
        #expect(try await request(root.appendingPathComponent("Download/Trip/one.jpg"), "PUT", body: Data(count: 10)).0 == 201)
        #expect(device.file("Download/Trip/one.jpg")?.size == 10)

        // The phone's own files cannot be deleted or renamed until the setting allows it.
        let doc = root.appendingPathComponent("Download/doc.pdf")
        #expect(try await request(doc, "DELETE").0 == 403)
        #expect(device.file("Download/doc.pdf") != nil)
        var settings = HelperSettings()
        settings.allowDriveChanges = true
        _ = try await harness.client.send(.setSettings(settings))
        #expect(try await request(doc, "MOVE", headers: ["Destination": root.appendingPathComponent("Download/report.pdf").absoluteString]).0 == 201)
        #expect(device.file("Download/report.pdf")?.size == 50_000)
        #expect(try await request(root.appendingPathComponent("Download/report.pdf"), "DELETE").0 == 204)
        #expect(device.file("Download/report.pdf") == nil)
    }

    /// Mounts the drive with macOS's WebDAV client (what Finder uses) and works with it as files.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULLI_MOUNT_TEST"] == "1"))
    func mountsWithTheSystemWebDAVClient() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)
        let mountPoint = harness.root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let mount = Process()
        mount.executableURL = URL(fileURLWithPath: "/sbin/mount_webdav")
        mount.arguments = ["-S", "-v", "Phone", root.absoluteString, mountPoint.path]
        try mount.run()
        mount.waitUntilExit()
        #expect(mount.terminationStatus == 0)
        defer {
            let unmount = Process()
            unmount.executableURL = URL(fileURLWithPath: "/sbin/umount")
            unmount.arguments = [mountPoint.path]
            try? unmount.run()
            unmount.waitUntilExit()
        }
        let camera = try FileManager.default.contentsOfDirectory(atPath: mountPoint.appendingPathComponent("DCIM/Camera").path).sorted()
        #expect(camera == ["a.jpg", "clip.mp4"])
        let read = try Data(contentsOf: mountPoint.appendingPathComponent("DCIM/Camera/a.jpg"))
        #expect(read == device.expectedContent("DCIM/Camera/a.jpg"))
        try Data(repeating: 66, count: 70_000).write(to: mountPoint.appendingPathComponent("Download/from-mac.bin"))
        try await Task.sleep(for: .seconds(2))
        #expect(device.file("Download/from-mac.bin")?.size == 70_000)
    }

    @Test func undatedItemOmitsModificationDateAndNeverEmitsEpoch() async throws {
        let device = MockDevice(serial: "UNDATED_TEST")
        device.addFolder("EmptyFolder")
        device.addFile("Undated.bin", size: 42, modifiedWallClock: 0)
        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)

        // PROPFIND on root listing the items
        let (status, body, _) = try await request(root, "PROPFIND", headers: ["Depth": "1"])
        #expect(status == 207)
        let xml = String(decoding: body, as: UTF8.self)
        #expect(!xml.contains("1970"))

        // PROPFIND on the empty folder: no getlastmodified and no epoch
        let (folderStatus, folderBody, _) = try await request(root.appendingPathComponent("EmptyFolder/"), "PROPFIND", headers: ["Depth": "0"])
        #expect(folderStatus == 207)
        let folderXml = String(decoding: folderBody, as: UTF8.self)
        #expect(!folderXml.contains("<D:getlastmodified>"))
        #expect(!folderXml.contains("1970"))

        // GET on the undated file: no Last-Modified header
        let (fileStatus, _, headers) = try await request(root.appendingPathComponent("Undated.bin"), "GET")
        #expect(fileStatus == 200)
        #expect(headers["Last-Modified"] == nil)
    }

    @Test func browsesAndRoutesWithMultipleStorages() async throws {
        let internalStorage = StorageInfo(id: 0x0001_0001, description: "Internal shared storage", volumeIdentifier: nil, capacityBytes: 256 << 30, freeBytes: 128 << 30)
        let sdStorage = StorageInfo(id: 0x0002_0001, description: "SD card", volumeIdentifier: nil, capacityBytes: 128 << 30, freeBytes: 64 << 30)
        let device = MockDevice(serial: "MULTI1", storages: [internalStorage, sdStorage])
        device.addFile("DCIM/Camera/internal.jpg", size: 100_000, storage: internalStorage.id)
        device.addFile("Music/tune.mp3", size: 500_000, storage: sdStorage.id)

        let harness = try await Harness(devices: [device])
        _ = try await harness.client.send(.setWatchingDevices(true))
        let root = try await start(harness, device)

        // Root PROPFIND lists the storages as folders.
        let (rootStatus, rootBody, _) = try await request(root, "PROPFIND", headers: ["Depth": "1"])
        #expect(rootStatus == 207)
        let rootXml = String(decoding: rootBody, as: UTF8.self)
        #expect(rootXml.contains("<D:displayname>Internal storage</D:displayname>"))
        #expect(rootXml.contains("<D:displayname>SD card</D:displayname>"))

        // PROPFIND on the SD card folder lists its root contents.
        let (sdStatus, sdBody, _) = try await request(root.appendingPathComponent("SD card/"), "PROPFIND", headers: ["Depth": "1"])
        #expect(sdStatus == 207)
        let sdXml = String(decoding: sdBody, as: UTF8.self)
        #expect(sdXml.contains("<D:displayname>Music</D:displayname>"))

        // GET reads from the target storage.
        let expectedTune = try #require(device.expectedContent("Music/tune.mp3", storage: sdStorage.id))
        let (getTuneStatus, tuneBytes, _) = try await request(root.appendingPathComponent("SD card/Music/tune.mp3"), "GET")
        #expect(getTuneStatus == 200)
        #expect(tuneBytes == expectedTune)

        // Uploading into a storage routes to that storage.
        let uploadTarget = root.appendingPathComponent("SD card/Music/new.txt")
        #expect(try await request(uploadTarget, "PUT", body: Data("hello".utf8)).0 == 201)
        #expect(device.file("Music/new.txt", storage: sdStorage.id)?.size == 5)
        #expect(device.file("Music/new.txt", storage: internalStorage.id) == nil)

        // Creating folders in the root is forbidden.
        #expect(try await request(root.appendingPathComponent("RootFolder/"), "MKCOL").0 == 403)
    }
}

@Suite struct StorageRouterTests {
    @Test func singleStorageRouting() {
        let router = StorageRouter(singleStorageID: 0x10001)
        #expect(!router.isMultiStorage)
        #expect(router.resolve("/") == .root(storageID: 0x10001))
        #expect(router.resolve("/DCIM/Camera") == .item(storageID: 0x10001, remotePath: "/DCIM/Camera", storageFolderName: nil))
        #expect(router.drivePath(storageID: 0x10001, remotePath: "/DCIM/Camera") == "/DCIM/Camera")
    }

    @Test func multiStorageRoutingAndUniqueNames() {
        let s1 = StorageSnapshot(id: 0x10001, name: "Phone", capacityBytes: 100, freeBytes: 50)
        let s2 = StorageSnapshot(id: 0x20001, name: "SD card", capacityBytes: 200, freeBytes: 150)
        let s3 = StorageSnapshot(id: 0x30001, name: "SD card", capacityBytes: 200, freeBytes: 150)
        let router = StorageRouter(storages: [s1, s2, s3])

        #expect(router.isMultiStorage)
        #expect(router.storages.map(\.folderName) == ["Internal storage", "SD card", "SD card 2"])

        #expect(router.resolve("/") == .root(storageID: nil))
        #expect(router.resolve("/Internal storage") == .storageRoot(storage: router.storages[0]))
        #expect(router.resolve("/SD card") == .storageRoot(storage: router.storages[1]))
        #expect(router.resolve("/SD card 2") == .storageRoot(storage: router.storages[2]))
        #expect(router.resolve("/SD card/Music/tune.mp3") == .item(storageID: 0x20001, remotePath: "/Music/tune.mp3", storageFolderName: "SD card"))
        #expect(router.resolve("/SD card 2/Audio") == .item(storageID: 0x30001, remotePath: "/Audio", storageFolderName: "SD card 2"))
        #expect(router.resolve("/Unknown/path") == .notFound)

        #expect(router.drivePath(storageID: 0x20001, remotePath: "/Music/tune.mp3") == "/SD card/Music/tune.mp3")
        #expect(router.drivePath(storageID: 0x10001, remotePath: "/") == "/Internal storage")
    }
}
