import DeviceAPI
import Foundation
@testable import HelperCore
import MockDevice
import PulliProtocol
import RemoteFiles
import Synchronization
import Testing

private struct MockWatcher: DeviceWatcher {
    let devices: [MockDevice]

    func currentDevices() async -> [DeviceCandidate] {
        devices.filter(\.isPluggedIn).map {
            DeviceCandidate(key: $0.key, usb: $0.usb, hasFileTransferInterface: $0.mode == .fileTransfer, heldByApp: nil)
        }
    }
}

private final class Harness: @unchecked Sendable {
    let root: URL
    let hub: DeviceHub
    let server: HTTPServer
    let drive: PhoneDrive
    let baseURL: URL

    init(device: MockDevice) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-rf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let watcher = MockWatcher(devices: [device])
        let connector = MockConnector(devices: [device])
        hub = DeviceHub(connector: connector, watcher: watcher, pollInterval: .milliseconds(10))
        await hub.start()
        await hub.setUIActive(true)

        // Wait until phone snapshot is ready
        let deadline = ContinuousClock.now + .seconds(10)
        var readySnapshot: DeviceSnapshot?
        while ContinuousClock.now < deadline {
            if let snap = await hub.snapshot(forID: device.key.description), !snap.storages.isEmpty {
                readySnapshot = snap
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let snapshot = readySnapshot, let storage = snapshot.storages.first else {
            throw RemoteFileError.unavailable("phone not ready")
        }

        let volume = snapshot.name.replacingOccurrences(of: "/", with: "-")
        drive = PhoneDrive(deviceID: device.key.description, storageID: storage.id, volume: volume, hub: hub) { false }
        await drive.refreshSpace()

        let d = drive
        server = try HTTPServer { request in await d.handle(request) }
        let port = try await server.start()
        let name = volume.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? volume
        let token = await drive.token
        baseURL = URL(string: "http://127.0.0.1:\(port)/\(token)/\(name)/")!
    }

    func stop() async {
        server.stop()
        await hub.stop()
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite(.serialized) struct WebDAVSourceIntegrationTests {
    static func phone() -> MockDevice {
        let device = MockDevice(serial: "DRIVE_INTEGRATION_TEST")
        device.addFile("DCIM/Camera/a.jpg", size: 300_000)
        device.addFile("DCIM/Camera/clip.mp4", size: 5_000_000)
        device.addFile("Download/doc.pdf", size: 50_000)
        return device
    }

    @Test func webDAVSourceOperationsAgainstPhoneDrive() async throws {
        let device = Self.phone()
        let harness = try await Harness(device: device)
        defer {
            Task { await harness.stop() }
        }

        let source = WebDAVSource(baseURL: harness.baseURL)

        // 1. list root and a folder
        let rootItems = try await source.list("/")
        #expect(rootItems.contains(where: { $0.path == "/DCIM" && $0.isFolder }))
        #expect(rootItems.contains(where: { $0.path == "/Download" && $0.isFolder }))

        let cameraItems = try await source.list("/DCIM/Camera")
        #expect(cameraItems.contains(where: { $0.path == "/DCIM/Camera/a.jpg" && !$0.isFolder && $0.size == 300_000 }))
        #expect(cameraItems.contains(where: { $0.path == "/DCIM/Camera/clip.mp4" && !$0.isFolder && $0.size == 5_000_000 }))

        // 2. item(at:)
        let photoItem = try await source.item(at: "/DCIM/Camera/a.jpg")
        #expect(photoItem.path == "/DCIM/Camera/a.jpg")
        #expect(photoItem.name == "a.jpg")
        #expect(photoItem.size == 300_000)
        #expect(!photoItem.isFolder)
        #expect(photoItem.contentType == "image/jpeg")
        #expect(photoItem.version != nil)

        let rootItem = try await source.item(at: "/")
        #expect(rootItem.isFolder)
        #expect(rootItem.path == "/")

        // 3. download a file and compare bytes with device.expectedContent
        let expectedBytes = try #require(device.expectedContent("DCIM/Camera/a.jpg"))
        let downloadDest = harness.root.appendingPathComponent("downloaded_a.jpg")
        let progressRecord = Mutex<(done: Int64, total: Int64?)>((0, nil))

        let downloadedItem = try await source.download("/DCIM/Camera/a.jpg", to: downloadDest) { done, total in
            progressRecord.withLock { $0 = (done, total) }
        }
        let progress = progressRecord.withLock { $0 }
        #expect(downloadedItem.size == 300_000)
        #expect(progress.done == 300_000)
        #expect(progress.total == 300_000)

        let fileData = try Data(contentsOf: downloadDest)
        #expect(fileData == expectedBytes)

        // 4. upload a new file and read it back
        let newFileLocal = harness.root.appendingPathComponent("new_file.bin")
        let uploadPayload = Data(repeating: 0x58, count: 12_345)
        try uploadPayload.write(to: newFileLocal)

        let uploadedItem = try await source.upload(newFileLocal, to: "/Download/new_file.bin")
        #expect(uploadedItem.size == 12_345)
        #expect(uploadedItem.path == "/Download/new_file.bin")

        let verifyItem = try await source.item(at: "/Download/new_file.bin")
        #expect(verifyItem.size == 12_345)

        // 5. makeFolder
        let folderItem = try await source.makeFolder("/Download/TripPhotos")
        #expect(folderItem.isFolder)
        #expect(folderItem.path == "/Download/TripPhotos")
        #expect(folderItem.name == "TripPhotos")

        // 6. move/rename of a file created through the drive
        let fileToMove = harness.root.appendingPathComponent("movable.txt")
        try Data("movable content".utf8).write(to: fileToMove)
        _ = try await source.upload(fileToMove, to: "/Download/before_move.txt")

        let movedItem = try await source.move("/Download/before_move.txt", to: "/Download/after_move.txt")
        #expect(movedItem.path == "/Download/after_move.txt")
        #expect(movedItem.name == "after_move.txt")

        let checkMoved = try await source.item(at: "/Download/after_move.txt")
        #expect(checkMoved.path == "/Download/after_move.txt")

        await #expect(throws: RemoteFileError.notFound("/Download/before_move.txt")) {
            try await source.item(at: "/Download/before_move.txt")
        }

        // 7. notFound for a missing path
        await #expect(throws: RemoteFileError.notFound("/Download/does_not_exist.bin")) {
            try await source.item(at: "/Download/does_not_exist.bin")
        }

        // 8. notAllowed for deleting an original (deleting is off by default)
        do {
            try await source.delete("/Download/doc.pdf")
            Issue.record("Expected delete to throw notAllowed")
        } catch let RemoteFileError.notAllowed(reason) {
            #expect(!reason.isEmpty)
        } catch {
            Issue.record("Unexpected error on delete: \(error)")
        }
    }
}
