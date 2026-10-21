import DeviceAPI
import Foundation
import MockDevice
import Testing
import TransferCore

@Suite struct FileTransferTests {
    let path = RemotePath("DCIM/Camera/VID_20260927.mp4")
    /// Not a multiple of the 4 MiB block, so the last block is partial.
    let size: UInt64 = 21 << 20 + 12_345

    @Test func copiesByteIdenticalWithDateAndNoPartLeft() async throws {
        let device = MockDevice()
        device.addFile(path, size: size, modifiedWallClock: 1_790_000_000)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)

        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
        #expect(!FileManager.default.fileExists(atPath: job.partURL.path))
        #expect(try workspace.journal.job(job.id!).status == .done)

        // 1_790_000_000 is 2026-09-21 13:46:40 on the phone's clock; placed in Berlin (UTC+2 in September).
        let modified = try #require(POSIXFileSink().attributes(of: url)?.modified)
        #expect(modified.timeIntervalSince1970 == 1_790_000_000 - 2 * 3600)
    }

    @Test func resumesAfterRepeatedDisconnectsWithoutStartingOver() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let reads = Counter()
        // Pull the cable on every 7th read, mid-chunk. Each session then gets the tail-guard read
        // plus 5 data reads: enough to cross one 4 MiB commit. (With every 5th read, no session
        // ever reaches a commit and no progress is possible - see D-006.)
        device.setFaultInjector { point in
            guard case .read = point else { return nil }
            return reads.increment() % 7 == 0 ? .disconnect : nil
        }
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let (outcome, reconnects) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)

        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(reconnects >= 4)
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
        // Resumed, not restarted: total bytes served stay well under twice the file size.
        #expect(device.bytesServed < size + UInt64(reconnects) * (ChainDigest.blockSize + (1 << 20)))
    }

    @Test func helperCrashMidTransferResumesFromCommittedOffset() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        // "Kill" the helper 10.5 MiB in: bytes past the last commit are on disk but not journalled.
        let sink = ScriptedSink()
        sink.crashAfterBytes = 10 << 20 + 512 << 10
        await #expect(throws: DestinationError.self) {
            _ = try await FileTransfer(session: try device.connect(), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
                .run(jobID: job.id!)
        }
        let committed = try workspace.journal.job(job.id!).committedOffset
        #expect(committed == 8 << 20, "last full block before the crash")

        // Restart the helper: fresh journal handle, fresh session, fresh object handles.
        try workspace.reopenJournal()
        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
    }

    @Test func trustsDiskWhenPartIsShorterThanJournal() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let sink = ScriptedSink()
        sink.crashAfterBytes = 17 << 20
        _ = try? await FileTransfer(session: try device.connect(), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
            .run(jobID: job.id!)
        #expect(try workspace.journal.job(job.id!).committedOffset == 16 << 20)

        // The disk lost data the journal thought was safe (e.g. a lying USB enclosure).
        let handle = try FileHandle(forWritingTo: job.partURL)
        try handle.truncate(atOffset: 6 << 20 + 100)
        try handle.close()

        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
        let events = try workspace.journal.events(forJob: job.id!).map(\.kind)
        #expect(events.contains("part_truncated"))
    }

    @Test func sourceChangedRestartsFromZeroAndLogsWhy() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let sink = ScriptedSink()
        sink.crashAfterBytes = 9 << 20
        _ = try? await FileTransfer(session: try device.connect(), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
            .run(jobID: job.id!)

        device.modifyFile(path) { file in
            file.size -= 1_000_000
            file.modifiedWallClock += 60
            file.seed &+= 1
        }

        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
        let record = try workspace.journal.job(job.id!)
        #expect(record.restarts == 1)
        #expect(try workspace.journal.events(forJob: job.id!).contains { $0.kind == "source_changed" })
    }

    @Test func tailGuardCatchesContentChangeWithSameSizeAndDate() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let sink = ScriptedSink()
        sink.crashAfterBytes = 13 << 20
        _ = try? await FileTransfer(session: try device.connect(), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
            .run(jobID: job.id!)

        // Same size, same date, different bytes: only the tail guard can notice.
        device.modifyFile(path) { $0.seed &+= 99 }

        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
        #expect(try workspace.journal.events(forJob: job.id!).contains { $0.kind == "guard_mismatch" })
    }

    @Test func shortReadsStillProduceExactCopy() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        // Like libmtp's Samsung workaround, but worse: reads come back at odd lengths.
        let reads = Counter()
        device.setFaultInjector { point in
            guard case .read(_, _, let length) = point else { return nil }
            return .shortRead(max(1, length - 1 - (reads.increment() % 7) * 1_013))
        }
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)
        guard case .completed(let url, let digest) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))

        var expected = ChainDigest()
        expected.update(device.expectedContent(path)!)
        #expect(digest == expected.finalized())
    }

    @Test func crashBetweenFinalizingAndRenameIsRecovered() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let sink = ScriptedSink()
        sink.crashOnNextRename = true
        await #expect(throws: DestinationError.self) {
            _ = try await FileTransfer(session: try device.connect(), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
                .run(jobID: job.id!)
        }
        #expect(try workspace.journal.job(job.id!).status == .finalizing)

        try workspace.reopenJournal()
        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
        #expect(device.bytesServed == size, "recovery must not re-read the file")
    }

    @Test func identicalDestinationIsSkippedAndDifferentOneIsKept() async throws {
        let device = MockDevice()
        device.addFile(path, size: 3 << 20, modifiedWallClock: 1_790_000_000)
        let workspace = try Workspace()

        let first = try await workspace.job(for: device, path)
        _ = try await transferWithReconnects(device, jobID: first.id!, workspace: workspace)

        // Same file again: already there.
        let second = try await workspace.job(for: device, path)
        let (again, _) = try await transferWithReconnects(device, jobID: second.id!, workspace: workspace)
        #expect(again == .alreadyPresent(second.destinationURL))

        // Different content under the same name: keep both.
        device.modifyFile(path) { $0.size += 10; $0.seed &+= 1 }
        let third = try await workspace.job(for: device, path)
        let (outcome, _) = try await transferWithReconnects(device, jobID: third.id!, workspace: workspace)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(url.lastPathComponent == "VID_20260927 (1).mp4")
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
    }

    @Test func diskFullPausesAndResumesWhenSpaceReturns() async throws {
        let device = MockDevice()
        device.addFile(path, size: size)
        let workspace = try Workspace()
        let job = try await workspace.job(for: device, path)

        let sink = ScriptedSink()
        sink.diskFullAfterBytes = 12 << 20
        await #expect(throws: DestinationError.noSpace) {
            _ = try await FileTransfer(session: try device.connect(), journal: workspace.journal, sink: sink, configuration: TestConfig.transfer)
                .run(jobID: job.id!)
        }
        let paused = try workspace.journal.job(job.id!)
        #expect(paused.status == .inProgress, "a full disk pauses the job, it does not fail it")
        #expect(paused.committedOffset == 12 << 20)

        sink.diskFullAfterBytes = nil
        let (outcome, _) = try await transferWithReconnects(device, jobID: job.id!, workspace: workspace, sink: sink)
        guard case .completed(let url, _) = outcome else { Issue.record("unexpected \(outcome)"); return }
        #expect(try sha256(of: url) == sha256(device.expectedContent(path)!))
    }

    @Test func phonesWithoutOffsetReadsCopyWholeFilesAndRestartAfterDisconnect() async throws {
        let device = MockDevice(readStrategy: .whole)
        device.addFile(path, size: size)
        let small = RemotePath("DCIM/Camera/small.jpg")
        device.addFile(small, size: 70_000)
        let reads = Counter()
        // One disconnect 12 chunks into the big file: the whole file must start over.
        device.setFaultInjector { point in
            guard case .read = point else { return nil }
            return reads.increment() == 12 ? .disconnect : nil
        }
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, [path, small])

        let totals = try await TransferSupervisor.mock(device, workspace: workspace).run(batchID: batch.id!)

        #expect(totals.filesDone == 2)
        try expectBatchMatchesDevice(workspace, device, batchID: batch.id!)
        let job = try #require(try workspace.journal.jobs(batchID: batch.id!).first { $0.sourcePath == path.description })
        #expect(job.readStrategy == "whole")
        #expect(device.bytesServed > size, "restarted from zero after the disconnect")
    }

    @Test func readsAboveFourGiBOnAndroidDevices() async throws {
        let device = MockDevice()
        let big = RemotePath("Movies/long.mp4")
        device.addFile(big, size: 6 << 30)
        let session = try device.connect()
        let entry = try #require(try await session.stat(big, storage: device.defaultStorage))
        let offset: UInt64 = 5 << 30 + 7
        let data = try await session.read(entry.ref, offset: offset, maxLength: 4096)
        #expect(data == MockContent.bytes(seed: device.file(big)!.seed, offset: offset, count: 4096))
    }

    @Test func staleHandlesAreRejectedAfterReconnect() async throws {
        let device = MockDevice()
        device.addFile(path, size: 1024)
        let first = try device.connect()
        let entry = try #require(try await first.stat(path, storage: device.defaultStorage))
        let second = try device.connect()
        await #expect(throws: DeviceError.staleHandle) {
            _ = try await second.read(entry.ref, offset: 0, maxLength: 16)
        }
        let fresh = try #require(try await second.stat(path, storage: device.defaultStorage))
        #expect(fresh.ref.handle != entry.ref.handle)
    }
}

@Suite struct ChainDigestTests {
    @Test func independentOfChunking() {
        let data = MockContent.bytes(seed: 7, offset: 0, count: 9 << 20 + 333)
        var whole = ChainDigest()
        whole.update(data)

        var pieces = ChainDigest()
        var position = 0
        var step = 1
        while position < data.count {
            let end = min(data.count, position + step)
            pieces.update(data.subdata(in: position..<end))
            position = end
            step = step * 3 % 1_048_573 + 17
        }
        #expect(pieces.finalized() == whole.finalized())
    }

    @Test func resumesFromAlignedChain() {
        let data = MockContent.bytes(seed: 3, offset: 0, count: 12 << 20 + 5)
        var full = ChainDigest()
        full.update(data)

        var head = ChainDigest()
        head.update(data.prefix(8 << 20))
        var resumed = ChainDigest(resumingAt: head.alignedOffset, chain: head.chain)
        resumed.update(data.suffix(from: 8 << 20))
        #expect(resumed.finalized() == full.finalized())
    }
}

@Suite struct JournalTests {
    @Test func commitCannotMoveBackwards() async throws {
        let workspace = try Workspace()
        let device = MockDevice()
        device.addFile("a", size: 100 << 20)
        let job = try await workspace.job(for: device, "a")
        try workspace.journal.commit(jobID: job.id!, offset: 8 << 20, chain: Data(count: 32), syncLevel: .full)
        #expect(throws: JournalError.self) {
            try workspace.journal.commit(jobID: job.id!, offset: 4 << 20, chain: Data(count: 32), syncLevel: .full)
        }
    }

    @Test func secondWriterIsRefused() throws {
        let workspace = try Workspace()
        #expect(throws: JournalError.self) {
            _ = try Journal(url: workspace.journalURL)
        }
    }
}
