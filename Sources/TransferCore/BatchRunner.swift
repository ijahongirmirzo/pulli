public import DeviceAPI
import Foundation

/// Progress and results a batch reports while it runs.
public enum BatchEvent: Sendable {
    case scanning(folder: String, foldersPending: Int, filesFound: Int, bytesFound: UInt64)
    case fileStarted(JobRecord)
    case progress(BatchProgress)
    case fileFinished(JobRecord, TransferOutcome)
    case fileNeedsAttention(JobRecord, reason: String)
    case readFailed(JobRecord, DeviceError)
}

public struct BatchProgress: Sendable {
    public var job: JobRecord
    public var file: TransferProgress
    public var totals: BatchTotals
    /// Batch bytes done including the current file's received (not only committed) bytes.
    public var bytesDone: UInt64
}

/// Runs one batch on one open session: scans selected folders, then copies every file.
///
/// A file that fails for good (deleted on the phone, access denied, keeps changing) is moved to
/// "needs attention" and the batch continues. Device and destination problems are thrown to the
/// caller (`TransferSupervisor`), which waits, reconnects and calls `run` again.
public struct BatchRunner: Sendable {
    public let session: any DeviceSession
    public let journal: Journal
    public let sink: any FileSink
    public let configuration: TransferConfiguration
    /// Consecutive failed attempts without progress before a file needs attention.
    public var maxAttempts = 8
    /// Times a file may change under us before it needs attention.
    public var maxRestarts = 3

    public init(session: any DeviceSession, journal: Journal, sink: any FileSink, configuration: TransferConfiguration) {
        self.session = session
        self.journal = journal
        self.sink = sink
        self.configuration = configuration
    }

    public func run(batchID: Int64, events: @Sendable (BatchEvent) -> Void = { _ in }) async throws -> BatchTotals {
        var batch = try journal.batch(batchID)
        if batch.state == .scanning {
            try await scan(batch, events: events)
            batch = try journal.batch(batchID)
        }

        var configuration = configuration
        configuration.duplicatePolicy = batch.duplicatePolicy
        var totals = try journal.totals(batchID: batchID)
        let completions = SmallFileCompletions()
        let flushSync = configuration.smallFileSync

        // Jobs run in id order behind a cursor, so a small file whose "done" is still deferred is
        // not picked up again. A pass that ends goes round once more from the start, for files
        // that restarted behind the cursor.
        var cursor: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let job = try journal.nextRunnableJob(batchID: batchID, after: cursor) else {
                    try completions.flush(journal: journal, sink: sink, sync: flushSync)
                    if cursor == 0 { break }
                    cursor = 0
                    continue
                }
                cursor = job.id!
                if job.attempts >= maxAttempts {
                    try giveUp(job, "failed \(job.attempts) times in a row: \(job.lastError ?? "unknown error")", events: events)
                    totals.replace(job, with: try journal.job(job.id!))
                    continue
                }

                events(.fileStarted(job))
                let before = totals
                do {
                    let transfer = FileTransfer(session: session, journal: journal, sink: sink, configuration: configuration,
                                                completions: completions)
                    let outcome = try await transfer.run(jobID: job.id!) { file in
                        events(.progress(BatchProgress(job: job, file: file, totals: before,
                                                       bytesDone: before.bytesDone - UInt64(job.committedOffset) + file.bytesReceived)))
                    }
                    var after = try journal.job(job.id!)
                    if case .completed = outcome, after.status != .done {
                        // Recorded at the next flush; count it now.
                        after.status = .done
                        after.committedOffset = after.sourceSize
                    }
                    totals.replace(job, with: after)
                    events(.fileFinished(after, outcome))
                } catch let error as DeviceError {
                    switch error {
                    case .rejected, .notFound, .unsupported:
                        try giveUp(job, error.description, events: events)
                    case .transient, .staleHandle:
                        events(.readFailed(job, error))
                        try journal.recordFailure(jobID: job.id!, message: error.description, countsAsAttempt: true)
                        throw error
                    case .deviceGone, .noStorage, .noMTPInterface, .contended:
                        throw error
                    }
                    totals.replace(job, with: try journal.job(job.id!))
                } catch let error as TransferError {
                    switch error {
                    case .sourceChanged where job.restarts < maxRestarts:
                        try journal.restart(jobID: job.id!, sourceSize: UInt64(job.sourceSize), sourceMtimeWall: job.sourceMtimeWall,
                                            kind: "source_changed", reason: error.description)
                    default:
                        try giveUp(job, error.description, events: events)
                    }
                    totals.replace(job, with: try journal.job(job.id!))
                }
                if completions.isDue {
                    try completions.flush(journal: journal, sink: sink, sync: flushSync)
                }
            }
        } catch {
            // Files already renamed into place get recorded even though the run stops here.
            try? completions.flush(journal: journal, sink: sink, sync: flushSync)
            throw error
        }

        try journal.setBatchState(batchID, .completed)
        return totals
    }

    private func scan(_ batch: BatchRecord, events: @Sendable (BatchEvent) -> Void) async throws {
        var found = (files: 0, bytes: UInt64(0))
        while let folder = try journal.nextPendingFolder(batchID: batch.id!) {
            try Task.checkCancellation()
            var entries: [RemoteEntry] = []
            do {
                for try await page in session.list(RemotePath(folder.sourcePath), storage: batch.storageID) {
                    entries += page
                    events(.scanning(folder: folder.sourcePath, foldersPending: 0, filesFound: found.files + entries.count, bytesFound: found.bytes))
                }
            } catch DeviceError.notFound {
                try journal.failScan(of: folder, message: "folder no longer exists on the phone")
                continue
            } catch DeviceError.rejected(let detail) {
                try journal.failScan(of: folder, message: detail)
                continue
            }
            // A listing cut short by cancellation must not be recorded as the folder's contents.
            try Task.checkCancellation()
            let counts = try journal.completeScan(of: folder, entries: entries)
            found.files += counts.files
            found.bytes += counts.bytes
        }
    }

    private func giveUp(_ job: JobRecord, _ reason: String, events: @Sendable (BatchEvent) -> Void) throws {
        try journal.recordFailure(jobID: job.id!, message: reason, countsAsAttempt: false, permanent: true)
        // Keep a .part only if it holds committed bytes a retry could resume from.
        if try journal.job(job.id!).committedOffset == 0 {
            sink.remove(job.partURL)
        }
        events(.fileNeedsAttention(try journal.job(job.id!), reason: reason))
    }
}
