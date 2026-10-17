public import Foundation
import Synchronization

/// Records finished small files in groups instead of one journal transaction (and one folder
/// sync) per file (docs/DECISIONS.md, D-014).
///
/// A small file is renamed into place right away; its folder sync and its journal "done" row are
/// deferred to the next `flush`. If the process dies before that, the file is already there with
/// our job tag, and the next run recognises it as done; nothing is copied twice or lost.
public final class SmallFileCompletions: Sendable {
    struct Entry {
        var jobID: Int64
        var name: String
        var digest: Data
    }

    private let state = Mutex<(entries: [Entry], directories: Set<String>, oldest: ContinuousClock.Instant?)>(([], [], nil))
    public let maxFiles: Int
    public let maxDelay: Duration

    public init(maxFiles: Int = 128, maxDelay: Duration = .milliseconds(500)) {
        self.maxFiles = maxFiles
        self.maxDelay = maxDelay
    }

    func add(jobID: Int64, name: String, digest: Data, directory: String) {
        state.withLock { state in
            state.entries.append(Entry(jobID: jobID, name: name, digest: digest))
            state.directories.insert(directory)
            state.oldest = state.oldest ?? .now
        }
    }

    public var isDue: Bool {
        state.withLock { state in
            state.entries.count >= maxFiles || (state.oldest.map { ContinuousClock.now - $0 >= maxDelay } ?? false)
        }
    }

    public var isEmpty: Bool { state.withLock { $0.entries.isEmpty } }

    /// Makes the renames durable (one sync per folder), then records every file as done in one
    /// transaction. On failure the entries stay queued for the next attempt.
    public func flush(journal: Journal, sink: any FileSink, sync: SyncRequest) throws {
        let (entries, directories) = state.withLock { ($0.entries, $0.directories) }
        guard !entries.isEmpty else { return }
        for directory in directories.sorted() {
            try sink.syncDirectory(URL(fileURLWithPath: directory), sync)
        }
        try journal.markDone(entries.map { ($0.jobID, $0.name, $0.digest) })
        state.withLock { state in
            state.entries.removeFirst(entries.count)
            state.directories.subtract(directories)
            state.oldest = state.entries.isEmpty ? nil : .now
        }
    }
}
