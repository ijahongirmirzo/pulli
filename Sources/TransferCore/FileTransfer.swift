public import DeviceAPI
public import Foundation

public struct TransferConfiguration: Sendable {
    /// Bytes requested per device read. 8 MiB measured fastest on a Galaxy Z Fold7 (31.8 MB/s on
    /// USB 2, vs 25.7 MB/s at 64 MiB) and keeps each uncancellable call under 0.3 s
    /// (docs/device-matrix.md).
    public var chunkBytes: Int = 8 << 20
    /// Commit (sync + journal) at least this often by volume...
    public var commitBytes: UInt64 = 32 << 20
    /// ...and by time, so a slow USB 2 link still commits every few seconds.
    public var commitInterval: Duration = .seconds(2)
    /// Bytes re-read from the phone before resuming, to prove the `.part` still matches.
    public var tailGuardBytes: UInt64 = 1 << 20
    /// Zone used to turn the phone's wall-clock mtime into a real date for the copied file.
    public var destinationTimeZone: TimeZone = .current
    public var duplicatePolicy: DuplicatePolicy = .auto
    /// Files smaller than this are copied in one go with no intermediate commits.
    public var smallFileThreshold: UInt64 = ChainDigest.blockSize
    /// Sync strength for small files. `.ordered` is enough when the journal is on the same volume
    /// as the destination; the supervisor chooses (docs/DECISIONS.md, D-006).
    public var smallFileSync: SyncRequest = .durable

    public init() {}
}

public struct TransferProgress: Sendable {
    public enum Phase: String, Sendable {
        case locating, verifyingTail, reading, finalizing
    }

    public var phase: Phase
    public var bytesReceived: UInt64
    public var bytesCommitted: UInt64
    public var totalBytes: UInt64
    public var resumedFrom: UInt64
}

public enum TransferOutcome: Sendable, Equatable {
    case completed(URL, digest: Data)
    /// Not copied: the destination already has this file (duplicate policy).
    case alreadyPresent(URL)
}

/// Errors that belong to the file rather than to the device or the destination.
public enum TransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case sourceMissing(String)
    case sourceIsFolder(String)
    /// Changed while being read (it ended early). The job restarts.
    case sourceChanged(String)
    /// The device cannot read this file resumably (see `ReadStrategy`).
    case notResumable(String)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .sourceMissing(let path): "no longer on the phone: \(path)"
        case .sourceIsFolder(let path): "is a folder: \(path)"
        case .sourceChanged(let detail): "changed on the phone: \(detail)"
        case .notResumable(let detail): "cannot be read resumably: \(detail)"
        case .verificationFailed(let detail): "verification failed: \(detail)"
        }
    }
}

/// Copies one file from a device into `<name>.part`, committing progress to the journal, and
/// finishes with an atomic rename. Can be interrupted at any point and run again to resume.
///
/// Commit invariants (docs/DECISIONS.md, D-006):
/// 1. The journal's offset is written only after the bytes below it were synced to disk.
/// 2. Offsets are `ChainDigest.blockSize` aligned (or the file size) and only move forward, except
///    through `Journal.restart` / `correctOffset`, which log why.
/// 3. Resume truncates the `.part` to R = floor(min(journal, disk) / block) * block, then re-reads the
///    tail from the phone and compares it before writing anything new.
/// 4. Finalise: sync, check size, set date and job tag, sync, journal `finalizing`, rename, sync the
///    folder, journal `done`. Small files skip the intermediate journal writes: a crash before
///    `done` leaves either a `.part` (copied again) or a tagged final file (recognised as ours).
public struct FileTransfer: Sendable {
    public let session: any DeviceSession
    public let journal: Journal
    public let sink: any FileSink
    public let configuration: TransferConfiguration
    /// When set, finished small files are recorded in groups (see `SmallFileCompletions`).
    public let completions: SmallFileCompletions?

    public init(session: any DeviceSession, journal: Journal, sink: any FileSink, configuration: TransferConfiguration = .init(),
                completions: SmallFileCompletions? = nil) {
        self.completions = completions
        self.session = session
        self.journal = journal
        self.sink = sink
        self.configuration = configuration
    }

    static let block = ChainDigest.blockSize

    public func run(jobID: Int64, progress: @Sendable (TransferProgress) -> Void = { _ in }) async throws -> TransferOutcome {
        var job = try journal.job(jobID)
        let path = RemotePath(job.sourcePath)

        if job.status == .finalizing, let outcome = try recoverFinalizing(job) {
            return outcome
        }
        // Our own finished file, from a run that stopped before recording it.
        if sink.jobTag(of: job.destinationURL) == job.uuid {
            try journal.markDone(jobID: jobID, destinationName: job.destinationName, note: "completed before interruption")
            sink.remove(job.partURL)
            return .completed(job.destinationURL, digest: job.digestFinal ?? Data())
        }

        // Locate by path, and check the file is still the one we started copying (D-005).
        progress(TransferProgress(phase: .locating, bytesReceived: 0, bytesCommitted: UInt64(job.committedOffset), totalBytes: UInt64(job.sourceSize), resumedFrom: 0))
        guard let entry = try await session.stat(path, storage: job.storageID) else {
            throw TransferError.sourceMissing(job.sourcePath)
        }
        guard !entry.isFolder else { throw TransferError.sourceIsFolder(job.sourcePath) }
        if entry.size != UInt64(job.sourceSize) || entry.modifiedWallClock != job.sourceMtimeWall {
            let reason = "size \(job.sourceSize) → \(entry.size), mtime \(job.sourceMtimeWall) → \(entry.modifiedWallClock)"
            try journal.restart(jobID: jobID, sourceSize: entry.size, sourceMtimeWall: entry.modifiedWallClock, kind: "source_changed", reason: reason)
            job = try journal.job(jobID)
        }
        let size = entry.size
        let modified = destinationDate(for: entry.modifiedWallClock)
        let isSmall = size < configuration.smallFileThreshold
        let strategy = session.info.readStrategy
        // Phones (or sizes) without offset reads stream the whole file; an interruption restarts it.
        let wholeObject = !strategy.supportsResume(fileSize: size)

        // Duplicate policy, decided before any bytes move.
        if job.committedOffset == 0, let existing = sink.attributes(of: job.destinationURL) {
            let identical = existing.size == size && Int64(existing.modified.timeIntervalSince1970) == Int64(modified.timeIntervalSince1970)
            if configuration.duplicatePolicy == .skip || (configuration.duplicatePolicy == .auto && identical) {
                try journal.markDone(jobID: jobID, destinationName: job.destinationName, status: .skipped,
                                     note: identical ? "identical file already at destination" : "a file with this name already exists")
                return .alreadyPresent(job.destinationURL)
            }
        }

        try sink.createDirectory(URL(fileURLWithPath: job.destinationDirectory))
        let part = try sink.openPart(at: job.partURL)
        defer { part.close() }

        var offset: UInt64 = 0
        var digest = ChainDigest()
        if isSmall || wholeObject {
            try part.truncate(to: 0)
            if !isSmall { try journal.begin(jobID: jobID, readStrategy: ReadStrategy.whole.rawValue) }
        } else {
            try journal.begin(jobID: jobID, readStrategy: strategy.rawValue)
            (offset, digest) = try prepareResume(job: job, part: part)
            if offset > 0 {
                progress(TransferProgress(phase: .verifyingTail, bytesReceived: offset, bytesCommitted: offset, totalBytes: size, resumedFrom: offset))
                if try await !tailMatches(entry.ref, part: part, end: offset) {
                    try journal.restart(jobID: jobID, sourceSize: size, sourceMtimeWall: entry.modifiedWallClock, kind: "guard_mismatch",
                                        reason: "bytes before \(offset) differ between phone and .part; starting over")
                    try part.truncate(to: 0)
                    _ = try part.sync(.durable)
                    (offset, digest) = (0, ChainDigest())
                }
            }
        }
        let resumedFrom = offset

        // Copy.
        var committed = offset
        var lastCommit = ContinuousClock.now
        var syncLevel = SyncLevel.full
        var partNameDurable = false
        if wholeObject {
            for try await data in session.readWhole(entry.ref) {
                try Task.checkCancellation()
                guard offset + UInt64(data.count) <= size else {
                    throw TransferError.sourceChanged("longer than the \(size) bytes listed")
                }
                try part.write(data, at: offset)
                digest.update(data)
                offset += UInt64(data.count)
                progress(TransferProgress(phase: .reading, bytesReceived: offset, bytesCommitted: 0, totalBytes: size, resumedFrom: 0))
            }
            guard offset == size else {
                throw TransferError.sourceChanged("ended at \(offset) of \(size) bytes")
            }
        }
        while offset < size {
            try Task.checkCancellation()
            let want = Int(min(UInt64(configuration.chunkBytes), size - offset))
            let data = try await session.read(entry.ref, offset: offset, maxLength: want)
            guard !data.isEmpty else {
                throw TransferError.sourceChanged("ended at \(offset) of \(size) bytes")
            }
            try part.write(data, at: offset)
            digest.update(data)
            offset += UInt64(data.count)

            let due = offset - committed >= configuration.commitBytes || ContinuousClock.now - lastCommit >= configuration.commitInterval
            if !isSmall, due, digest.alignedOffset > committed {
                if !partNameDurable {
                    // A new .part's name is not durable until its folder is synced; without this a
                    // power loss could remove the file the journal is about to claim bytes in.
                    try sink.syncDirectory(URL(fileURLWithPath: job.destinationDirectory), .durable)
                    partNameDurable = true
                }
                syncLevel = weaker(syncLevel, try part.sync(.durable))
                try journal.commit(jobID: jobID, offset: digest.alignedOffset, chain: digest.chain, syncLevel: syncLevel)
                committed = digest.alignedOffset
                lastCommit = .now
            }
            progress(TransferProgress(phase: .reading, bytesReceived: offset, bytesCommitted: committed, totalBytes: size, resumedFrom: resumedFrom))
        }

        // Finalise.
        progress(TransferProgress(phase: .finalizing, bytesReceived: offset, bytesCommitted: committed, totalBytes: size, resumedFrom: resumedFrom))
        let request: SyncRequest = isSmall ? configuration.smallFileSync : .durable
        let onDisk = try part.size()
        guard onDisk == size else {
            throw TransferError.verificationFailed(".part is \(onDisk) bytes, expected \(size)")
        }
        try part.setModificationDate(modified)
        try part.setJobTag(job.uuid)
        syncLevel = weaker(syncLevel, try part.sync(request))
        let finalDigest = digest.finalized()
        if !isSmall {
            try journal.markFinalizing(jobID: jobID, digest: finalDigest, syncLevel: syncLevel)
        }
        part.close()

        let finalURL = try moveIntoPlace(job: try journal.job(jobID), digest: finalDigest, request: request,
                                         deferred: isSmall ? completions : nil)
        return .completed(finalURL, digest: finalDigest)
    }

    /// Where to resume, trusting the disk over the journal (brief: "trust the disk and resume
    /// from the disk size rounded down to the last full chunk").
    private func prepareResume(job: JobRecord, part: any PartFile) throws -> (UInt64, ChainDigest) {
        let journalOffset = UInt64(job.committedOffset)
        let diskSize = try part.size()
        let resume = min(journalOffset, diskSize) / Self.block * Self.block

        try part.truncate(to: resume)
        _ = try part.sync(.durable)

        if resume == journalOffset, let chain = job.digestState, chain.count == 32 {
            return (resume, ChainDigest(resumingAt: resume, chain: chain))
        }
        // The chain value is for a different offset: rebuild it from the bytes on disk.
        var digest = ChainDigest()
        var position: UInt64 = 0
        while position < resume {
            let count = Int(min(Self.block, resume - position))
            digest.update(try part.read(at: position, count: count))
            position += UInt64(count)
        }
        if resume != journalOffset {
            try journal.correctOffset(jobID: job.id!, to: resume, chain: resume == 0 ? nil : digest.chain,
                                      reason: ".part holds \(diskSize) bytes, journal claimed \(journalOffset); resuming at \(resume)")
        }
        return (resume, digest)
    }

    /// Re-reads the bytes just before `end` from the phone and compares them with the `.part`.
    private func tailMatches(_ ref: ObjectRef, part: any PartFile, end: UInt64) async throws -> Bool {
        let length = min(configuration.tailGuardBytes, end)
        var position = end - length
        while position < end {
            let phone = try await session.read(ref, offset: position, maxLength: Int(end - position))
            guard !phone.isEmpty else { return false }
            let disk = try part.read(at: position, count: phone.count)
            guard disk == phone else { return false }
            position += UInt64(phone.count)
        }
        return true
    }

    /// Renames the `.part` into place per the duplicate policy and records completion.
    private func moveIntoPlace(job: JobRecord, digest: Data?, request: SyncRequest, deferred: SmallFileCompletions? = nil) throws -> URL {
        let directory = URL(fileURLWithPath: job.destinationDirectory)
        var name = job.destinationName
        var number = 1
        while true {
            let target = directory.appendingPathComponent(name)
            do {
                if configuration.duplicatePolicy == .overwrite {
                    try sink.renameReplacing(job.partURL, to: target)
                } else {
                    try sink.renameExclusive(job.partURL, to: target)
                }
                if let deferred {
                    deferred.add(jobID: job.id!, name: name, digest: digest ?? Data(), directory: directory.path)
                } else {
                    try sink.syncDirectory(directory, request)
                    try journal.markDone(jobID: job.id!, destinationName: name, digest: digest)
                }
                return target
            } catch DestinationError.alreadyExists {
                // Keep both: another file took the name, possibly while we were copying.
                name = NameMapper.numbered(job.destinationName, number)
                number += 1
            }
        }
    }

    /// Completes a job interrupted between "finalizing" and "done".
    private func recoverFinalizing(_ job: JobRecord) throws -> TransferOutcome? {
        if sink.attributes(of: job.partURL) != nil {
            return .completed(try moveIntoPlace(job: job, digest: nil, request: .durable), digest: job.digestFinal ?? Data())
        }
        if sink.jobTag(of: job.destinationURL) == job.uuid
            || sink.attributes(of: job.destinationURL)?.size == UInt64(job.sourceSize) {
            try journal.markDone(jobID: job.id!, destinationName: job.destinationName, note: "rename had completed before interruption")
            return .completed(job.destinationURL, digest: job.digestFinal ?? Data())
        }
        try journal.restart(jobID: job.id!, sourceSize: UInt64(job.sourceSize), sourceMtimeWall: job.sourceMtimeWall,
                            kind: "finalize_lost", reason: "neither .part nor final file found after finalizing; starting over")
        return nil
    }

    /// The phone's wall-clock time, placed in the destination's time zone.
    func destinationDate(for wallClock: Int64) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let fields = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(wallClock)))
        var local = Calendar(identifier: .gregorian)
        local.timeZone = configuration.destinationTimeZone
        return local.date(from: fields) ?? Date(timeIntervalSince1970: TimeInterval(wallClock))
    }

    private func weaker(_ a: SyncLevel, _ b: SyncLevel) -> SyncLevel {
        let rank: [SyncLevel: Int] = [.fsync: 0, .barrier: 1, .full: 2]
        return rank[a]! <= rank[b]! ? a : b
    }
}
