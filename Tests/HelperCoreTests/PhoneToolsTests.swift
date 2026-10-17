import DeviceAPI
import Foundation
@testable import HelperCore
import MockDevice
import PulliClient
import PulliProtocol
import Synchronization
import Testing
import TransferCore

/// Collects progress events (storage scans, uploads, verification) from the client.
private final class ProgressLog: Sendable {
    private let events = Mutex<[HelperEvent]>([])
    func append(_ event: HelperEvent) { events.withLock { $0.append(event) } }
    var all: [HelperEvent] { events.withLock { $0 } }
}

@Suite(.serialized) struct PhoneToolsTests {
    static func phone() -> MockDevice {
        let device = MockDevice(serial: "TOOLS1")
        device.addFile("DCIM/Camera/a.jpg", size: 300_000)
        device.addFile("DCIM/Camera/b.mp4", size: 2_000_000)
        device.addFile("Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/w1.jpg", size: 120_000)
        device.addFile("Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video/w2.mp4", size: 900_000)
        device.addFile("Download/doc.pdf", size: 50_000)
        return device
    }

    private func waitFor<T>(_ log: ProgressLog, _ what: String, _ pick: (HelperEvent) -> T?) async throws -> T {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if let found = log.all.lazy.compactMap(pick).first { return found }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what)")
        throw CancellationError()
    }

    @Test func measuresWholeFolderTrees() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.wait("phone") { $0.devices[device.key.description] != nil }
        let reply = try await harness.client.send(.measure(deviceID: device.key.description, storageID: device.defaultStorage,
                                                           paths: ["/Android/media/com.whatsapp", "/Telegram"]))
        guard case .measured(let results) = reply else { throw PulliError(.unknown, "\(reply)") }
        #expect(results[0] == FolderMeasure(path: "/Android/media/com.whatsapp", exists: true, files: 2, bytes: 1_020_000))
        #expect(results[1].exists == false)
    }

    @Test func mapsTheStorage() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        let log = ProgressLog()
        await harness.client.setProgressHandler { log.append($0) }
        _ = try await harness.wait("phone") { $0.devices[device.key.description] != nil }
        _ = try await harness.client.send(.scanStorage(deviceID: device.key.description, storageID: device.defaultStorage, scanID: UUID()))
        let scan = try await waitFor(log, "a finished scan") { event -> StorageScan? in
            if case .storageScan(let scan) = event, scan.done { return scan } else { return nil }
        }
        #expect(scan.error == nil)
        #expect(scan.root.bytes == 3_370_000)
        #expect(scan.root.files == 5)
        #expect(scan.root.children.first?.name == "DCIM")
        let android = try #require(scan.root.children.first { $0.name == "Android" })
        #expect(android.videos == 900_000)
        #expect(android.images == 120_000)
    }

    @Test func fetchesAFileForQuickLook() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.wait("phone") { $0.devices[device.key.description] != nil }
        let target = harness.root.appendingPathComponent("QuickLook/a.jpg")
        _ = try await harness.client.send(.fetchFile(deviceID: device.key.description, storageID: device.defaultStorage,
                                                     path: "/DCIM/Camera/a.jpg", destination: target.path))
        #expect(try Data(contentsOf: target) == device.expectedContent("DCIM/Camera/a.jpg"))
    }

    @Test func findsFilesAlreadyOnTheMacUnderOtherNames() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        _ = try await harness.wait("phone") { $0.devices[device.key.description] != nil }
        let library = harness.root.appendingPathComponent("Library/2026")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try #require(device.expectedContent("DCIM/Camera/b.mp4")).write(to: library.appendingPathComponent("IMG_4411.mp4"))
        // Same size, different bytes: not a duplicate.
        try Data(repeating: 7, count: 300_000).write(to: library.appendingPathComponent("other.jpg"))

        let reply = try await harness.client.send(.findDuplicates(deviceID: device.key.description, storageID: device.defaultStorage,
                                                                  paths: ["/DCIM/Camera/a.jpg", "/DCIM/Camera/b.mp4"],
                                                                  macFolders: [harness.root.appendingPathComponent("Library").path]))
        guard case .duplicates(let matches) = reply else { throw PulliError(.unknown, "\(reply)") }
        #expect(matches.map(\.path) == ["/DCIM/Camera/b.mp4"])
        #expect(matches.first?.macPath.hasSuffix("IMG_4411.mp4") == true)
    }

    @Test func sendsFilesAndFoldersFromTheMac() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        let log = ProgressLog()
        await harness.client.setProgressHandler { log.append($0) }
        _ = try await harness.wait("phone") { $0.devices[device.key.description] != nil }
        let trip = harness.root.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: trip.appendingPathComponent("Day 1"), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: trip.appendingPathComponent("Day 1/one.jpg"))
        try Data(count: 2_000).write(to: trip.appendingPathComponent("two.jpg"))
        let loose = harness.root.appendingPathComponent("notes.txt")
        try Data(count: 10).write(to: loose)

        _ = try await harness.client.send(.upload(deviceID: device.key.description, storageID: device.defaultStorage,
                                                  localPaths: [trip.path, loose.path], destination: "/Download", uploadID: UUID()))
        let done = try await waitFor(log, "a finished upload") { event -> UploadProgress? in
            if case .upload(let progress) = event, progress.done { return progress } else { return nil }
        }
        #expect(done.error == nil, "\(done.error ?? "")")
        #expect(done.filesDone == 3)
        #expect(done.bytesDone == 3_010)
        #expect(device.file("Download/Trip/Day 1/one.jpg")?.size == 1_000)
        #expect(device.file("Download/Trip/two.jpg")?.size == 2_000)
        #expect(device.file("Download/notes.txt")?.size == 10)
    }

    /// Owner request (2026-09-27): free up space only after every copy is checked against the
    /// phone, and only the files that were identical.
    @Test func freesUpOnlyVerifiedIdenticalFiles() async throws {
        let device = Self.phone()
        let harness = try await Harness(devices: [device])
        let log = ProgressLog()
        await harness.client.setProgressHandler { log.append($0) }
        _ = try await harness.wait("phone") { $0.devices[device.key.description] != nil }
        let id = try await harness.copy(device, ["/DCIM/Camera", "/Download/doc.pdf"])
        _ = try await harness.wait("copied") { $0.batches[id]?.phase == .completed }

        // Deleting before checking is refused.
        await #expect(throws: PulliError.self) { _ = try await harness.client.send(.deleteVerified(batchID: id)) }

        // One Mac copy is damaged after copying: it must stay on the phone.
        let jobs = try harness.journal.jobs(batchID: id)
        let damaged = try #require(jobs.first { $0.sourcePath.hasSuffix("a.jpg") })
        var bytes = try Data(contentsOf: damaged.destinationURL)
        bytes[1_000] ^= 0xFF
        try bytes.write(to: damaged.destinationURL)

        _ = try await harness.client.send(.verify(batchID: id, verifyID: UUID()))
        let checked = try await waitFor(log, "a finished check") { event -> VerifyProgress? in
            if case .verification(let progress) = event, progress.done { return progress } else { return nil }
        }
        #expect(checked.identical == 2)
        #expect(checked.problems.map(\.name) == ["a.jpg"])
        #expect(checked.problems.first?.result == .different)

        guard case .deleted(let summary) = try await harness.client.send(.deleteVerified(batchID: id)) else { throw PulliError(.unknown, "no summary") }
        #expect(summary.deleted == 2)
        #expect(summary.bytesFreed == 2_050_000)
        #expect(device.file("DCIM/Camera/b.mp4") == nil)
        #expect(device.file("Download/doc.pdf") == nil)
        #expect(device.file("DCIM/Camera/a.jpg") != nil, "the damaged copy's original stays")
        #expect(device.file("Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/w1.jpg") != nil, "nothing outside the copy is touched")

        // A second delete without a new check does nothing.
        await #expect(throws: PulliError.self) { _ = try await harness.client.send(.deleteVerified(batchID: id)) }
    }
}
