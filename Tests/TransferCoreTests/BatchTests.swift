import DeviceAPI
import Foundation
import MockDevice
import Synchronization
import Testing
import TransferCore

@Suite struct BatchTests {
    /// A small phone: nested folders, big and small files, a hidden folder.
    static func samplePhone() -> MockDevice {
        let device = MockDevice()
        device.addFile("DCIM/Camera/IMG_0001.jpg", size: 3_456_789)
        device.addFile("DCIM/Camera/VID_0002.mp4", size: 9 << 20 + 77)
        device.addFile("DCIM/Camera/IMG_0003.jpg", size: 0)
        device.addFile("DCIM/Screenshots/Screenshot_1.png", size: 250_000)
        device.addFile("DCIM/.thumbnails/1.jpg", size: 4_000)
        device.addFile("Download/report.pdf", size: 1_234_567)
        device.addFile("Download/other.zip", size: 10_000)
        return device
    }

    @Test func copiesWholeFoldersWithTheirStructure() async throws {
        let device = Self.samplePhone()
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM", "Download/report.pdf"])
        let events = EventLog()

        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!) { events.append($0) }

        #expect(totals.filesTotal == 6)
        #expect(totals.filesDone == 6)
        #expect(workspace.destinationFiles() == [
            "DCIM/Camera/IMG_0001.jpg", "DCIM/Camera/VID_0002.mp4", "DCIM/Camera/IMG_0003.jpg",
            "DCIM/Screenshots/Screenshot_1.png", "DCIM/.thumbnails/1.jpg", "report.pdf",
        ])
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
        #expect(try workspace.journal.batch(batch.id!).state == .completed)
    }

    /// Owner request (2026-09-27): copies organised into year and month folders by date.
    @Test func organisesFilesByYearAndMonth() async throws {
        let device = MockDevice()
        device.addFile("DCIM/Camera/a.jpg", size: 1_000, modifiedWallClock: 1_789_000_000)   // 2026-09-10
        device.addFile("DCIM/Camera/b.jpg", size: 2_000, modifiedWallClock: 1_785_000_000)   // 2026-07-25
        device.addFile("DCIM/Screenshots/c.png", size: 3_000, modifiedWallClock: 1_789_100_000)
        device.addFile("Download/d.pdf", size: 4_000, modifiedWallClock: 0)
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM", "Download/d.pdf"], organize: BatchRecord.organizeByYearMonth)

        _ = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)

        #expect(workspace.destinationFiles() == ["2026/09/a.jpg", "2026/07/b.jpg", "2026/09/c.png", "Unknown date/d.pdf"])
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
    }

    @Test func namesThatCannotCoexistOnMacOSAreRenamedAndRecorded() async throws {
        let device = MockDevice()
        device.addFile("Pictures/IMG.jpg", size: 100)
        device.addFile("Pictures/img.jpg", size: 200)
        device.addFile("Pictures/Caf\u{E9}.txt", size: 300)          // NFC é
        device.addFile("Pictures/Cafe\u{301}.txt", size: 400)        // NFD é
        device.addFile("Pictures/bad\u{1}name.txt", size: 500)
        device.addFile(RemotePath("Pictures/" + String(repeating: "ж", count: 200) + ".jpg"), size: 600)
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["Pictures"])

        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)

        #expect(totals.filesDone == 6)
        #expect(workspace.destinationFiles().count == 6)
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
        let reasons = Set(try workspace.journal.nameMappings(batchID: batch.id!).map(\.reason))
        #expect(reasons == ["case_collision", "unicode_norm", "invalid_chars", "too_long"])
    }

    @Test func thousandsOfSmallFilesInOneFolder() async throws {
        let device = MockDevice()
        let count = 3_000
        for index in 0..<count {
            device.addFile(RemotePath("DCIM/Camera/IMG_\(String(format: "%05d", index)).jpg"), size: UInt64(1_000 + index * 7 % 50_000))
        }
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM"])

        let start = ContinuousClock.now
        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)
        let elapsed = ContinuousClock.now - start

        #expect(totals.filesDone == count)
        #expect(workspace.destinationFiles().count == count)
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
        print("\(count) small files in \(elapsed)")
        #expect(elapsed < .seconds(60))
    }

    @Test func filesThatFailForGoodNeedAttentionAndTheRestContinue() async throws {
        let device = Self.samplePhone()
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM", "Download/report.pdf", "Download/other.zip"])
        // One file deleted on the phone after it was selected; one that cannot be read.
        device.removeFile("Download/other.zip")
        device.setFaultInjector { point in
            if case .read(let path, _, _) = point, path == "DCIM/Screenshots/Screenshot_1.png" { return .rejected }
            return nil
        }
        let events = EventLog()

        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!) { events.append($0) }

        #expect(totals.filesDone == 5)
        #expect(totals.filesNeedingAttention == 2)
        #expect(Set(events.needsAttention) == ["/Download/other.zip", "/DCIM/Screenshots/Screenshot_1.png"])
        let attention = try workspace.journal.attentionJobs(batchID: batch.id!)
        #expect(attention.allSatisfy { $0.lastError != nil })
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)

        // "Try again" after the problem is fixed.
        device.setFaultInjector(nil)
        #expect(try workspace.journal.retryAttention(batchID: batch.id!) == 2)
        let retried = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)
        #expect(retried.filesDone == 6)
        #expect(retried.filesNeedingAttention == 1, "the deleted file is still gone")
    }

    @Test func waitsWhileThePhoneIsLockedOrChargingOnly() async throws {
        let device = Self.samplePhone()
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["Download"])
        device.setMode(.chargingOnly)
        let polls = Counter()
        let events = EventLog()

        let supervisor = TransferSupervisor.mock(device, workspace: workspace) {
            switch polls.increment() {
            case 3:
                device.setMode(.fileTransfer)   // user picks "File transfer"…
                device.setLocked(true)          // …but the phone is locked
            case 6:
                device.setLocked(false)
            default: break
            }
        }
        let totals = try await supervisor.run(batchID: batch.id!) { events.append($0) }

        #expect(totals.filesDone == 2)
        #expect(events.waits.contains(.notInFileTransferMode))
        #expect(events.waits.contains(.locked))
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
    }

    @Test func fullDestinationPausesAndResumesWhenSpaceReturns() async throws {
        let device = Self.samplePhone()
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM"])
        let sink = ScriptedSink()
        sink.diskFullAfterBytes = 5 << 20
        let polls = Counter()
        let events = EventLog()

        let supervisor = TransferSupervisor.mock(device, workspace: workspace, sink: sink) {
            if polls.increment() == 3 { sink.diskFullAfterBytes = nil }   // user frees space
        }
        let totals = try await supervisor.run(batchID: batch.id!) { events.append($0) }

        #expect(totals.filesDone == 5)
        #expect(events.waits.contains(.destination(.noSpace)))
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
    }

    @Test func runningTheSameCopyAgainOnlyCopiesNewFiles() async throws {
        let device = Self.samplePhone()
        let workspace = try Workspace()
        let first = try await workspace.batch(device, ["DCIM"])
        _ = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: first.id!)

        device.addFile("DCIM/Camera/IMG_0004.jpg", size: 777_777)
        let servedBefore = device.bytesServed
        let second = try await workspace.batch(device, ["DCIM"])
        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: second.id!)

        #expect(totals.filesDone == 1)
        #expect(totals.filesSkipped == 5)
        #expect(device.bytesServed - servedBefore == 777_777)
        try expectBatchMatchesDevice(workspace, device, batchID: second.id!)
    }

    @Test(arguments: [DuplicatePolicy.skip, .overwrite, .keepBoth])
    func duplicatePolicies(_ policy: DuplicatePolicy) async throws {
        let device = MockDevice()
        device.addFile("Download/a.txt", size: 1_000)
        let workspace = try Workspace()
        let existing = workspace.destination.appendingPathComponent("a.txt")
        try Data("already here".utf8).write(to: existing)

        let batch = try await workspace.batch(device, ["Download/a.txt"], policy: policy)
        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)

        let expected = device.expectedContent("Download/a.txt")!
        switch policy {
        case .skip:
            #expect(totals.filesSkipped == 1)
            #expect(try Data(contentsOf: existing) == Data("already here".utf8))
        case .overwrite:
            #expect(try Data(contentsOf: existing) == expected)
            #expect(workspace.destinationFiles() == ["a.txt"])
        case .keepBoth, .auto:
            #expect(try Data(contentsOf: existing) == Data("already here".utf8))
            #expect(try Data(contentsOf: workspace.destination.appendingPathComponent("a (1).txt")) == expected)
        }
    }

    @Test func flakyLinkStillMakesProgress() async throws {
        // Disconnects every 7th read: with 32 MiB commits no session would ever commit. The
        // supervisor must notice and commit at every 4 MiB block (D-006).
        let device = MockDevice()
        device.addFile("Movies/long.mp4", size: 40 << 20)
        let reads = Counter()
        device.setFaultInjector { point in
            guard case .read = point else { return nil }
            return reads.increment() % 7 == 0 ? .disconnect : nil
        }
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["Movies"])
        var configuration = TestConfig.transfer
        configuration.commitBytes = 32 << 20

        let totals = try await TransferSupervisor.mock(device, workspace: workspace, configuration: configuration).run(batchID: batch.id!)

        #expect(totals.filesDone == 1)
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
    }

    @Test func interruptedScanIsRepeatedWithoutDuplicates() async throws {
        let device = Self.samplePhone()
        let listings = Counter()
        device.setFaultInjector { point in
            if case .list(let path) = point, path == "DCIM/Camera", listings.increment() <= 2 { return .disconnect }
            return nil
        }
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM"])

        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)

        #expect(totals.filesTotal == 5)
        #expect(totals.filesDone == 5)
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
    }

    /// Random disconnects, transient errors, short reads, failed opens and helper crashes, from
    /// many seeds. Every run must end with every file byte-identical and no `.part` left behind.
    /// `PULLI_FAULT_SEEDS=1000 scripts/test.sh` runs the full matrix.
    @Test(arguments: 0..<(Int(ProcessInfo.processInfo.environment["PULLI_FAULT_SEEDS"] ?? "") ?? 24))
    func faultMatrix(seed: Int) async throws {
        let random = SeededRandom(seed: UInt64(seed))
        let device = MockDevice()
        for index in 0..<random.int(3...12) {
            let folder = ["DCIM/Camera", "DCIM/Screenshots", "Download", "Music/Albums/One"][random.int(0...3)]
            let size: UInt64 = random.chance(0.3) ? UInt64(random.int(4 << 20 ... 14 << 20)) : UInt64(random.int(0...600_000))
            device.addFile(RemotePath("\(folder)/file_\(index).bin"), size: size)
        }
        let workspace = try Workspace()
        let topLevel = Set(device.allFiles().keys.map { $0.components[0] }).sorted().map { RemotePath($0) }
        let batch = try await workspace.batch(device, topLevel)
        device.setFaultInjector { point in
            switch point {
            case .open: return random.chance(0.05) ? .transient : nil
            case .list, .stat: return random.chance(0.03) ? .disconnect : nil
            case .read(_, _, let length):
                if random.chance(0.04) { return .disconnect }
                if random.chance(0.03) { return .transient }
                if random.chance(0.15) { return .shortRead(max(1, length - random.int(1...4096))) }
                return nil
            }
        }


        // Crash the "helper" a few times at random moments, restarting with a fresh journal handle.
        for _ in 0..<random.int(0...3) {
            let stopAfter = random.int(1...40)
            do {
                let seen = Counter()
                let supervisor = TransferSupervisor.mock(device, workspace: workspace)
                let task = Task {
                    try await supervisor.run(batchID: batch.id!) { event in
                        if case .batch(.progress) = event, seen.increment() == stopAfter {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    }
                }
                _ = await task.result
            }
            // The crashed "helper" is gone; the next one opens the journal afresh.
            try workspace.reopenJournal()
        }

        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)
        #expect(totals.filesNeedingAttention == 0, "seed \(seed)")
        #expect(totals == (try workspace.journal.totals(batchID: batch.id!)), "running totals match the journal (seed \(seed))")
        #expect(totals.filesDone + totals.filesSkipped == totals.filesTotal, "seed \(seed)")
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
    }

    @Test func clearHistoryRemovesCompletedBatchesAndReclaimsJournalBytes() async throws {
        let device = MockDevice()
        let privateName = "PRIVATE_NAME_123.jpg"
        device.addFile(RemotePath("DCIM/\(privateName)"), size: 100)
        device.addFile(RemotePath("DCIM/kept.jpg"), size: 200)

        let workspace = try Workspace()
        let batchToClear = try await workspace.batch(device, [RemotePath("DCIM/\(privateName)")])
        let keptBatch = try await workspace.batch(device, [RemotePath("DCIM/kept.jpg")])

        try workspace.journal.log(.notice, kind: "device", message: "Device event with \(privateName)")
        try workspace.journal.log(.notice, kind: "file", batchID: batchToClear.id, message: "Started \(privateName)")
        try workspace.journal.log(.notice, kind: "file", batchID: keptBatch.id, message: "Started kept.jpg")

        let needle = Data(privateName.utf8)
        let mainURL = workspace.journalURL
        let walURL = URL(fileURLWithPath: workspace.journalURL.path + "-wal")

        let mainBefore = (try? Data(contentsOf: mainURL)) ?? Data()
        let walBefore = (try? Data(contentsOf: walURL)) ?? Data()
        #expect(mainBefore.range(of: needle) != nil || walBefore.range(of: needle) != nil)

        // Only finished copies go: the kept copy is still active and a paused one must survive too.
        device.addFile(RemotePath("DCIM/paused.jpg"), size: 300)
        let pausedBatch = try await workspace.batch(device, [RemotePath("DCIM/paused.jpg")])
        try workspace.journal.setBatchState(pausedBatch.id!, .paused)
        try workspace.journal.setBatchState(batchToClear.id!, .completed)
        try workspace.journal.setSetting("rate:usb:04e8:\(privateName):usb2", "29000000")
        try workspace.journal.setSetting("settings", "{}")
        try workspace.journal.clearHistory()
        #expect(try workspace.journal.setting("rate:usb:04e8:\(privateName):usb2") == nil)
        #expect(try workspace.journal.setting("settings") == "{}")
        #expect(try workspace.journal.batch(pausedBatch.id!).state == .paused)

        #expect(try workspace.journal.batch(keptBatch.id!).id == keptBatch.id!)
        let keptJobs = try workspace.journal.jobs(batchID: keptBatch.id!)
        #expect(keptJobs.count == 1)
        #expect(keptJobs.first?.sourcePath == "/DCIM/kept.jpg")
        let keptEvents = try workspace.journal.events(afterID: nil, limit: 100).filter { $0.batchId == keptBatch.id }
        #expect(!keptEvents.isEmpty)

        #expect(throws: JournalError.self) {
            try workspace.journal.batch(batchToClear.id!)
        }
        let allBatches = try workspace.journal.allBatches()
        #expect(Set(allBatches.map(\.id)) == [keptBatch.id, pausedBatch.id])
        let remainingEvents = try workspace.journal.events(afterID: nil, limit: 100)
        #expect(remainingEvents.allSatisfy { $0.batchId == keptBatch.id || $0.batchId == pausedBatch.id })

        let mainAfter = (try? Data(contentsOf: mainURL)) ?? Data()
        let walAfter = (try? Data(contentsOf: walURL)) ?? Data()
        #expect(mainAfter.range(of: needle) == nil)
        #expect(walAfter.range(of: needle) == nil)
    }
}

@Suite struct NameMapperTests {
    @Test func sanitizesUnsafeNames() {
        #expect(NameMapper.sanitize("ok.jpg") == ("ok.jpg", nil))
        #expect(NameMapper.sanitize("a/b") == ("a_b", .invalidCharacters))
        #expect(NameMapper.sanitize("tab\there") == ("tab_here", .invalidCharacters))
        #expect(NameMapper.sanitize("..") == ("_..", .reserved))
        #expect(NameMapper.sanitize("") == ("unnamed", .invalidCharacters))
        let long = String(repeating: "é", count: 300) + ".jpeg"
        let (short, reason) = NameMapper.sanitize(long)
        #expect(reason == .tooLong)
        #expect(short.utf8.count <= NameMapper.maxNameBytes)
        #expect(short.hasSuffix(".jpeg"))
    }

    @Test func resolvesCollisionsPerFolder() {
        var scope = NameMapper.Scope(mapper: NameMapper(caseSensitive: false))
        #expect(scope.claim("IMG.jpg").name == "IMG.jpg")
        #expect(scope.claim("img.jpg") == ("img (1).jpg", NameMapper(caseSensitive: false).key("img (1).jpg"), .caseCollision))
        #expect(scope.claim("IMG.JPG").name == "IMG (2).JPG")
        #expect(scope.claim("Caf\u{E9}").name == "Caf\u{E9}")
        #expect(scope.claim("Cafe\u{301}").reason == .unicodeCollision)

        var sensitive = NameMapper.Scope(mapper: NameMapper(caseSensitive: true))
        #expect(sensitive.claim("IMG.jpg").reason == nil)
        #expect(sensitive.claim("img.jpg").reason == nil)
    }

    @Test func numbersKeepExtensionsAndDotfiles() {
        #expect(NameMapper.numbered("a.tar.gz", 1) == "a.tar (1).gz")
        #expect(NameMapper.numbered(".nomedia", 2) == ".nomedia (2)")
        #expect(NameMapper.numbered("README", 3) == "README (3)")
    }
}
