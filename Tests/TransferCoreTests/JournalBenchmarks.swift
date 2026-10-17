import DeviceAPI
import Foundation
import MockDevice
import Testing
import TransferCore

/// Journal cost for a 50,000-file folder (Phase 2 target: under 5 s in a release build).
/// Run with: `PULLI_BENCHMARKS=1 scripts/test.sh -c release --filter JournalBenchmarks`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULLI_BENCHMARKS"] != nil))
struct JournalBenchmarks {
    @Test func fiftyThousandFiles() async throws {
        let count = 50_000
        let device = MockDevice()
        for index in 0..<count {
            device.addFile(RemotePath("DCIM/Camera/IMG_\(index).jpg"), size: UInt64(2_000_000 + index))
        }
        let workspace = try Workspace()
        let batch = try await workspace.batch(device, ["DCIM"])
        let session = try device.connect()

        // Scan: two folders, 50,000 job rows.
        var clock = ContinuousClock.now
        while let folder = try workspace.journal.nextPendingFolder(batchID: batch.id!) {
            var entries: [RemoteEntry] = []
            for try await page in session.list(RemotePath(folder.sourcePath), storage: device.defaultStorage) { entries += page }
            _ = try workspace.journal.completeScan(of: folder, entries: entries)
        }
        let scan = ContinuousClock.now - clock

        // Per file, what the runner does with the journal: cursor read, job reads, grouped "done".
        clock = .now
        var totals = try workspace.journal.totals(batchID: batch.id!)
        var cursor: Int64 = 0
        var group: [(jobID: Int64, destinationName: String, digest: Data)] = []
        while let job = try workspace.journal.nextRunnableJob(batchID: batch.id!, after: cursor) {
            cursor = job.id!
            var current = try workspace.journal.job(job.id!)
            group.append((current.id!, current.destinationName, Data(count: 32)))
            current.status = .done
            totals.replace(job, with: current)
            if group.count == 128 {
                try workspace.journal.markDone(group)
                group.removeAll()
            }
        }
        try workspace.journal.markDone(group)
        let perFile = ContinuousClock.now - clock

        #expect(totals.filesDone == count)
        #expect(totals == (try workspace.journal.totals(batchID: batch.id!)))
        print("journal, \(count) files: scan \(scan), per-file bookkeeping \(perFile) (\(perFile / count) per file)")
    }
}
