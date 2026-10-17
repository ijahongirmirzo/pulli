import DeviceAPI
import Foundation
import MockDevice
import Testing
import TransferCore

private let seedCount = Int(ProcessInfo.processInfo.environment["PULLI_FAULT_SEEDS"] ?? "") ?? 24

/// A random phone for durability scenarios: some multi-block files, many small ones, nested.
private func randomPhone(_ random: SeededRandom) -> MockDevice {
    let device = MockDevice()
    for index in 0..<random.int(4...14) {
        let folder = ["DCIM/Camera", "DCIM/Camera/Burst", "Download", "Documents/Work"][random.int(0...3)]
        let size: UInt64 = random.chance(0.35) ? UInt64(random.int(4 << 20 ... 13 << 20)) : UInt64(random.int(0...400_000))
        device.addFile(RemotePath("\(folder)/f\(index).bin"), size: size)
    }
    return device
}

private func topLevelFolders(_ device: MockDevice) -> [RemotePath] {
    Set(device.allFiles().keys.map { $0.components[0] }).sorted().map { RemotePath($0) }
}

/// A supervisor that stops (like a dead process) once `stop()` says so.
private func stoppableSupervisor(_ device: MockDevice, _ workspace: Workspace, sink: any FileSink,
                                 stop: @escaping @Sendable () -> Bool) -> TransferSupervisor {
    var supervisor = TransferSupervisor(connector: MockConnector(device), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
    supervisor.sleep = { _ in
        if stop() { throw CancellationError() }
        if !device.isPluggedIn { device.plug() }
        await Task.yield()
    }
    return supervisor
}

@Suite struct DurabilityTests {
    /// Power fails at a random moment, several times per run. After each reboot, the journal must
    /// not claim anything that did not survive (invariant 1), and the final result must be exact.
    @Test(arguments: 0..<seedCount)
    func powerLossNeverLosesCommittedData(seed: Int) async throws {
        let random = SeededRandom(seed: UInt64(seed) &+ 1_000)
        let device = randomPhone(random)
        let workspace = try Workspace()
        let volume = SimulatedVolume(existing: workspace.destination)
        let batch = try await workspace.batch(device, topLevelFolders(device))

        for _ in 0..<random.int(1...4) {
            volume.powerFail(afterOperations: random.int(3...300))
            do {
                let supervisor = stoppableSupervisor(device, workspace, sink: volume) { volume.powerFailed }
                _ = try? await supervisor.run(batchID: batch.id!)
            }
            volume.powerCycle { extra in random.chance(0.5) ? random.int(0...extra) : 0 }
            try workspace.reopenJournal()
            try expectJournalMatchesVolume(workspace, volume, device, batchID: batch.id!, seed: seed)
        }

        let totals = try await stoppableSupervisor(device, workspace, sink: volume) { false }.run(batchID: batch.id!)
        #expect(totals.filesDone + totals.filesSkipped == totals.filesTotal, "seed \(seed)")
        try expectVolumeMatchesDevice(workspace, volume, device, batchID: batch.id!, seed: seed)
    }

    /// The journal loses its most recent transactions (e.g. a disk that acknowledged but did not
    /// persist them), while the files on disk are further along. Recovery must still end exact,
    /// without duplicate copies.
    @Test(arguments: 0..<seedCount)
    func journalRollbackIsRecovered(seed: Int) async throws {
        let random = SeededRandom(seed: UInt64(seed) &+ 2_000)
        let device = randomPhone(random)
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, topLevelFolders(device))
        let snapshot = workspace.root.appendingPathComponent("snapshot.sqlite")

        let snapshotAt = random.int(1...30)
        let stopAt = snapshotAt + random.int(1...60)
        do {
            let seen = Counter()
            let journal = workspace.journal
            let supervisor = TransferSupervisor.mock(device, workspace: workspace)
            let task = Task {
                try await supervisor.run(batchID: batch.id!) { event in
                    guard case .batch(let batchEvent) = event else { return }
                    switch batchEvent {
                    case .progress, .fileFinished:
                        let count = seen.increment()
                        if count == snapshotAt { try? journal.backup(to: snapshot) }
                        if count == stopAt { withUnsafeCurrentTask { $0?.cancel() } }
                    default: break
                    }
                }
            }
            _ = await task.result
        }
        guard FileManager.default.fileExists(atPath: snapshot.path) else { return }   // finished before the snapshot

        try workspace.restoreJournal(from: snapshot)
        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)

        #expect(totals.filesDone + totals.filesSkipped == totals.filesTotal, "seed \(seed)")
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
        let expected = Set(try workspace.journal.jobs(batchID: batch.id!).map { relative($0.destinationURL, to: workspace.destination) })
        #expect(workspace.destinationFiles() == expected, "no duplicate copies (seed \(seed))")
    }

    @Test func twoPhonesAtOnce() async throws {
        let first = MockDevice(serial: "PHONE-A")
        let second = MockDevice(serial: "PHONE-B")
        for index in 0..<6 {
            first.addFile(RemotePath("DCIM/Camera/a\(index).jpg"), size: UInt64(300_000 * (index + 1)))
            second.addFile(RemotePath("DCIM/Camera/b\(index).jpg"), size: UInt64(5 << 20 + index))
        }
        let workspace = try Workspace()
        let batchA = try await workspace.batch(first, ["DCIM"])
        let batchB = try await workspace.batch(second, ["DCIM"])
        let reads = Counter()
        second.setFaultInjector { point in
            if case .read = point, reads.increment() % 9 == 0 { return .disconnect }
            return nil
        }

        let supervisorA = TransferSupervisor.mock(first, workspace: workspace)
        let supervisorB = TransferSupervisor.mock(second, workspace: workspace)
        let (idA, idB) = (batchA.id!, batchB.id!)
        async let a = supervisorA.run(batchID: idA)
        async let b = supervisorB.run(batchID: idB)
        let (totalsA, totalsB) = try await (a, b)

        #expect(totalsA.filesDone == 6)
        #expect(totalsB.filesDone == 6)
        try expectBatchMatchesDevice(workspace, first, batchID: batchA.id!)
        try expectBatchMatchesDevice(workspace, second, batchID: batchB.id!)
    }

    @Test(arguments: [false, true])
    func cancelKeepsOrDiscardsPartialFiles(discard: Bool) async throws {
        let device = MockDevice()
        device.addFile("Movies/a.mp4", size: 12 << 20)
        device.addFile("Movies/b.mp4", size: 12 << 20)
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["Movies"])

        // Stop mid-way through the first file, as the user pressing Cancel would.
        do {
            let seen = Counter()
            let supervisor = TransferSupervisor.mock(device, workspace: workspace)
            let task = Task {
                try await supervisor.run(batchID: batch.id!) { event in
                    if case .batch(.progress) = event, seen.increment() == 9 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            _ = await task.result
        }
        try BatchControl.cancel(batchID: batch.id!, journal: workspace.journal, sink: POSIXFileSink(), discardParts: discard)
        let totals = try workspace.journal.totals(batchID: batch.id!)
        #expect(totals.filesCancelled == 2)
        #expect(workspace.leftoverPartFiles().isEmpty == discard)

        // Resuming continues from the kept progress (or from zero if discarded).
        let found = try #require(try workspace.journal.unfinishedBatch(
            deviceKey: device.key, storageID: device.defaultStorage, destinationRoot: workspace.destination, selection: ["Movies"]))
        #expect(found.id == batch.id)
        try workspace.journal.resumeBatch(batch.id!)
        let served = device.bytesServed
        let done = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)
        #expect(done.filesDone == 2)
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
        let reread = device.bytesServed - served
        if discard {
            #expect(reread >= 24 << 20)
        } else {
            #expect(reread < 24 << 20)
        }
    }

    // MARK: Checks

    /// After a reboot, every byte the journal claims must be on the volume (invariant 1).
    private func expectJournalMatchesVolume(_ workspace: Workspace, _ volume: SimulatedVolume, _ device: MockDevice,
                                            batchID: Int64, seed: Int) throws {
        for job in try workspace.journal.jobs(batchID: batchID) {
            let expected = try #require(device.expectedContent(RemotePath(job.sourcePath)))
            switch job.status {
            case .inProgress where job.committedOffset > 0:
                let part = volume.contents(of: job.partURL) ?? Data()
                #expect(part.count >= Int(job.committedOffset), "seed \(seed): \(job.sourcePath) .part lost committed bytes")
                #expect(part.prefix(Int(job.committedOffset)) == expected.prefix(Int(job.committedOffset)),
                        "seed \(seed): \(job.sourcePath) committed bytes differ")
            case .finalizing:
                let survivor = volume.contents(of: job.partURL) ?? volume.contents(of: job.destinationURL)
                #expect(survivor == expected, "seed \(seed): \(job.sourcePath) lost while finalizing")
            case .done:
                #expect(volume.contents(of: job.destinationURL) == expected, "seed \(seed): \(job.sourcePath) done but not on disk")
            default:
                break
            }
        }
    }

    private func expectVolumeMatchesDevice(_ workspace: Workspace, _ volume: SimulatedVolume, _ device: MockDevice,
                                           batchID: Int64, seed: Int) throws {
        var expectedFiles: Set<String> = []
        for job in try workspace.journal.jobs(batchID: batchID) {
            expectedFiles.insert(relative(job.destinationURL, to: workspace.destination))
            #expect(volume.contents(of: job.destinationURL) == device.expectedContent(RemotePath(job.sourcePath)),
                    "seed \(seed): \(job.sourcePath)")
        }
        #expect(volume.files(under: workspace.destination) == expectedFiles, "seed \(seed): unexpected or missing files")
    }
}

private func relative(_ url: URL, to root: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
}

extension Workspace {
    /// Replaces the journal with an older snapshot, as if its latest transactions were lost.
    func restoreJournal(from snapshot: URL) throws {
        try reopenJournal(replacingWith: snapshot)
    }
}
