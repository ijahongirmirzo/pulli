public import DeviceAPI
public import Foundation
public import GRDB

public enum JobStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case queued
    case inProgress = "in_progress"
    case finalizing
    case done
    case skipped
    case needsAttention = "needs_attention"
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .done, .skipped, .cancelled: true
        case .queued, .inProgress, .finalizing, .needsAttention: false
        }
    }
}

/// What to do when a file with the same name already exists at the destination.
public enum DuplicatePolicy: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// Skip if same size and date, otherwise keep both (brief: the default).
    case auto
    case skip
    case overwrite
    case keepBoth = "keep_both"
}

public enum BatchState: String, Codable, Sendable, DatabaseValueConvertible {
    case scanning, active, completed, cancelled
    /// Paused by the user; survives helper restarts until resumed.
    case paused
}

/// One copy request: a selection of files and folders from one storage into one destination.
public struct BatchRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "batch"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var uuid: String
    public var deviceKey: String
    public var storageId: Int64
    public var destinationRoot: String
    public var duplicatePolicy: DuplicatePolicy
    public var caseSensitive: Bool
    public var state: BatchState
    /// Selected source paths, one per line, sorted: identifies "the same copy" when re-run.
    public var selection: String
    public var createdAt: Int64
    public var updatedAt: Int64
    public var finishedAt: Int64?
    /// How files are laid out in the destination: nil keeps the phone's folders;
    /// `year_month` puts each file in YYYY/MM by its date (migration v2).
    public var organize: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var storageID: StorageID { StorageID(truncatingIfNeeded: storageId) }

    public static let organizeByYearMonth = "year_month"
}

/// A folder to scan. Scanning commits a folder's children and its `done` state in one
/// transaction, so an interrupted scan simply lists the folder again.
public struct FolderRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "folder"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum ScanState: String, Codable, Sendable, DatabaseValueConvertible {
        case pending, done, failed
    }

    public var id: Int64?
    public var batchId: Int64
    public var parentId: Int64?
    /// Path on the phone. Empty for the batch's virtual root, which holds individually selected files.
    public var sourcePath: String
    /// Path below the batch's destination root. Empty for the root.
    public var destinationPath: String
    public var scanState: ScanState
    public var scanError: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// One file to copy. Disconnects, stalls and backoff are never written here: a job is only ever
/// "paused" at runtime, which is what keeps paused from turning into failed.
public struct JobRecord: Codable, Sendable, Hashable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "job"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public var id: Int64?
    public var uuid: String
    public var batchId: Int64
    public var folderId: Int64
    public var deviceKey: String
    public var storageId: Int64
    public var sourcePath: String
    public var sourceSize: Int64
    public var sourceMtimeWall: Int64
    public var destinationDirectory: String
    public var destinationName: String
    public var status: JobStatus
    public var readStrategy: String?
    /// Bytes of the `.part` file known to be durable. Block aligned, or equal to `sourceSize`.
    public var committedOffset: Int64
    /// `ChainDigest.chain` at `committedOffset`.
    public var digestState: Data?
    public var digestFinal: Data?
    public var syncLevel: String?
    public var attempts: Int
    public var restarts: Int
    public var lastError: String?
    public var createdAt: Int64
    public var updatedAt: Int64

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var partName: String { destinationName + ".part" }
    public var destinationURL: URL { URL(fileURLWithPath: destinationDirectory).appendingPathComponent(destinationName) }
    public var partURL: URL { URL(fileURLWithPath: destinationDirectory).appendingPathComponent(partName) }
    public var storageID: StorageID { StorageID(truncatingIfNeeded: storageId) }
}

public struct EventRecord: Codable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "event"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Level: Int, Codable, Sendable {
        case info = 1, notice = 2, warning = 3, error = 4
    }

    public var id: Int64?
    public var ts: Int64
    public var level: Level
    public var kind: String
    public var batchId: Int64?
    public var jobId: Int64?
    public var message: String

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Counts and bytes of a batch, by job status.
public struct BatchTotals: Sendable, Equatable {
    public var filesTotal = 0
    public var filesDone = 0
    public var filesSkipped = 0
    public var filesNeedingAttention = 0
    public var filesCancelled = 0
    public var bytesTotal: UInt64 = 0
    /// Bytes of finished or skipped files, plus committed bytes of unfinished ones.
    public var bytesDone: UInt64 = 0

    public var filesRemaining: Int { filesTotal - filesDone - filesSkipped - filesNeedingAttention - filesCancelled }

    /// Updates the totals for one job's change of state, without re-querying the whole batch
    /// (which would make a 50,000-file batch quadratic).
    public mutating func replace(_ old: JobRecord, with new: JobRecord) {
        account(old, sign: -1)
        account(new, sign: 1)
    }

    private mutating func account(_ job: JobRecord, sign: Int) {
        let size = UInt64(job.sourceSize)
        func adjust(_ value: inout UInt64, _ amount: UInt64) {
            value = sign > 0 ? value + amount : value - min(value, amount)
        }
        filesTotal += sign
        adjust(&bytesTotal, size)
        switch job.status {
        case .done:
            filesDone += sign
            adjust(&bytesDone, size)
        case .skipped:
            filesSkipped += sign
            adjust(&bytesDone, size)
        case .needsAttention:
            filesNeedingAttention += sign
        case .cancelled:
            filesCancelled += sign
        case .queued, .inProgress, .finalizing:
            adjust(&bytesDone, UInt64(job.committedOffset))
        }
    }
}

/// A selected item when creating a batch.
public struct BatchItem: Sendable, Hashable {
    public var path: RemotePath
    public var isFolder: Bool
    public var size: UInt64
    public var modifiedWallClock: Int64

    public init(path: RemotePath, isFolder: Bool, size: UInt64 = 0, modifiedWallClock: Int64 = 0) {
        self.path = path
        self.isFolder = isFolder
        self.size = size
        self.modifiedWallClock = modifiedWallClock
    }

    public init(_ entry: RemoteEntry, at path: RemotePath) {
        self.init(path: path, isFolder: entry.isFolder, size: entry.size, modifiedWallClock: entry.modifiedWallClock)
    }
}

public enum JournalError: Error, Sendable, CustomStringConvertible {
    case locked(String)
    case notFound(String)
    /// A write would break a commit invariant. Indicates a bug; the engine must stop.
    case invariantViolation(String)

    public var description: String {
        switch self {
        case .locked(let path): "journal \(path) is in use by another Pulli process"
        case .notFound(let what): "\(what) not found in the journal"
        case .invariantViolation(let detail): "journal invariant violated: \(detail)"
        }
    }
}

/// The durable record of every transfer. Single writer per file, enforced with `flock`.
public final class Journal: Sendable {
    public let url: URL
    let pool: DatabasePool
    private let lockDescriptor: Int32

    public static func defaultURL(fileName: String = "journal.sqlite") -> URL {
        DataFolder.current.appendingPathComponent(fileName)
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let lockPath = url.path + ".lock"
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw DestinationError(errno: errno, context: "open \(lockPath)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw JournalError.locked(url.path)
        }

        var configuration = Configuration()
        configuration.label = "pulli.journal"
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA fullfsync = ON")
            try db.execute(sql: "PRAGMA checkpoint_fullfsync = ON")
        }
        do {
            pool = try DatabasePool(path: url.path, configuration: configuration)
            try Self.migrator.migrate(pool)
        } catch {
            close(fd)
            throw error
        }
        self.url = url
        self.lockDescriptor = fd
    }

    deinit {
        close(lockDescriptor)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Pre-release only: while the schema is still being designed, a development journal whose
        // schema differs from this code is erased instead of migrated. Must be removed before the
        // first public build (docs/DECISIONS.md, D-013).
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                INSERT INTO meta (key, value) VALUES ('digest_algo', '\(ChainDigest.algorithm)');

                CREATE TABLE batch (
                  id INTEGER PRIMARY KEY,
                  uuid TEXT NOT NULL UNIQUE,
                  device_key TEXT NOT NULL,
                  storage_id INTEGER NOT NULL,
                  destination_root TEXT NOT NULL,
                  duplicate_policy TEXT NOT NULL CHECK (duplicate_policy IN ('auto','skip','overwrite','keep_both')),
                  case_sensitive INTEGER NOT NULL,
                  state TEXT NOT NULL CHECK (state IN ('scanning','active','completed','cancelled','paused')),
                  selection TEXT NOT NULL,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL,
                  finished_at INTEGER
                );
                CREATE INDEX batch_lookup ON batch(device_key, storage_id, destination_root) WHERE state IN ('scanning','active','cancelled');

                CREATE TABLE folder (
                  id INTEGER PRIMARY KEY,
                  batch_id INTEGER NOT NULL REFERENCES batch(id) ON DELETE CASCADE,
                  parent_id INTEGER REFERENCES folder(id),
                  source_path TEXT NOT NULL,
                  destination_path TEXT NOT NULL,
                  scan_state TEXT NOT NULL CHECK (scan_state IN ('pending','done','failed')),
                  scan_error TEXT,
                  UNIQUE (batch_id, source_path)
                );
                CREATE INDEX folder_pending ON folder(batch_id, id) WHERE scan_state = 'pending';

                CREATE TABLE job (
                  id INTEGER PRIMARY KEY,
                  uuid TEXT NOT NULL UNIQUE,
                  batch_id INTEGER NOT NULL REFERENCES batch(id) ON DELETE CASCADE,
                  folder_id INTEGER NOT NULL REFERENCES folder(id) ON DELETE CASCADE,
                  device_key TEXT NOT NULL,
                  storage_id INTEGER NOT NULL,
                  source_path TEXT NOT NULL,
                  source_size INTEGER NOT NULL,
                  source_mtime_wall INTEGER NOT NULL,
                  destination_directory TEXT NOT NULL,
                  destination_name TEXT NOT NULL,
                  status TEXT NOT NULL CHECK (status IN
                    ('queued','in_progress','finalizing','done','skipped','needs_attention','cancelled')),
                  read_strategy TEXT,
                  committed_offset INTEGER NOT NULL DEFAULT 0,
                  digest_state BLOB,
                  digest_final BLOB,
                  sync_level TEXT,
                  attempts INTEGER NOT NULL DEFAULT 0,
                  restarts INTEGER NOT NULL DEFAULT 0,
                  last_error TEXT,
                  created_at INTEGER NOT NULL,
                  updated_at INTEGER NOT NULL,
                  CHECK (committed_offset BETWEEN 0 AND source_size),
                  UNIQUE (batch_id, source_path)
                );
                CREATE INDEX job_runnable ON job(batch_id, id) WHERE status IN ('queued','in_progress','finalizing');
                CREATE INDEX job_status ON job(batch_id, status);

                CREATE TABLE name_mapping (
                  id INTEGER PRIMARY KEY,
                  batch_id INTEGER NOT NULL REFERENCES batch(id) ON DELETE CASCADE,
                  kind TEXT NOT NULL CHECK (kind IN ('file','folder')),
                  source_path TEXT NOT NULL,
                  destination_path TEXT NOT NULL,
                  reason TEXT NOT NULL
                );
                CREATE INDEX name_mapping_batch ON name_mapping(batch_id);

                CREATE TABLE event (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  ts INTEGER NOT NULL,
                  level INTEGER NOT NULL,
                  kind TEXT NOT NULL,
                  batch_id INTEGER REFERENCES batch(id) ON DELETE CASCADE,
                  job_id INTEGER REFERENCES job(id) ON DELETE CASCADE,
                  message TEXT NOT NULL
                );
                CREATE INDEX event_batch ON event(batch_id, id);
                CREATE INDEX event_job ON event(job_id, id);

                CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at INTEGER NOT NULL) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("v2 organise by date") { db in
            try db.execute(sql: "ALTER TABLE batch ADD COLUMN organize TEXT")
        }
        return migrator
    }

    // MARK: Batches

    /// Creates a batch. Selected folders are scanned later (`BatchScanner`); selected files become
    /// jobs right away, in a virtual root folder that maps to the destination root.
    public func createBatch(
        deviceKey: DeviceKey, storageID: StorageID, destinationRoot: URL, items: [BatchItem],
        duplicatePolicy: DuplicatePolicy = .auto, caseSensitive: Bool = false, organize: String? = nil
    ) throws -> BatchRecord {
        try pool.write { db in
            let now = Self.now()
            var batch = BatchRecord(
                id: nil, uuid: UUID().uuidString, deviceKey: deviceKey.description, storageId: Int64(storageID),
                destinationRoot: destinationRoot.path, duplicatePolicy: duplicatePolicy, caseSensitive: caseSensitive,
                state: items.contains(where: \.isFolder) ? .scanning : .active,
                selection: Self.selectionKey(items.map(\.path)), createdAt: now, updatedAt: now, finishedAt: nil,
                organize: organize
            )
            try batch.insert(db)
            var root = FolderRecord(id: nil, batchId: batch.id!, parentId: nil, sourcePath: "", destinationPath: "",
                                    scanState: .done, scanError: nil)
            try root.insert(db)

            var scope = NameMapper.Scope(mapper: NameMapper(caseSensitive: caseSensitive))
            for item in items {
                try Self.insertChild(db, batch: batch, parent: root, name: item.path.name, sourcePath: item.path,
                                     isFolder: item.isFolder, size: item.size, mtime: item.modifiedWallClock, scope: &scope, now: now)
            }
            return batch
        }
    }

    public func batch(_ id: Int64) throws -> BatchRecord {
        guard let batch = try pool.read({ db in try BatchRecord.fetchOne(db, key: id) }) else {
            throw JournalError.notFound("batch \(id)")
        }
        return batch
    }

    public func batches(limit: Int = 50) throws -> [BatchRecord] {
        try pool.read { db in try BatchRecord.order(Column("id").desc).limit(limit).fetchAll(db) }
    }

    /// Stops a batch. Unfinished files become `cancelled`; their `.part` files are kept so the batch
    /// can be resumed later, unless `discardingParts`, in which case their progress is reset and the
    /// caller deletes the returned jobs' `.part` files.
    @discardableResult
    public func cancelBatch(_ id: Int64, discardingParts: Bool) throws -> [JobRecord] {
        try pool.write { db in
            let unfinished = try JobRecord
                .filter(Column("batch_id") == id && ["queued", "in_progress", "finalizing"].contains(Column("status")))
                .fetchAll(db)
            try db.execute(sql: """
                UPDATE job SET status = 'cancelled', updated_at = ?,
                  committed_offset = CASE WHEN ? THEN 0 ELSE committed_offset END,
                  digest_state = CASE WHEN ? THEN NULL ELSE digest_state END
                WHERE batch_id = ? AND status IN ('queued','in_progress','finalizing')
                """, arguments: [Self.now(), discardingParts, discardingParts, id])
            try db.execute(sql: "UPDATE batch SET state = 'cancelled', updated_at = ?, finished_at = ? WHERE id = ?",
                           arguments: [Self.now(), Self.now(), id])
            try Self.insertEvent(db, level: .notice, kind: "batch_cancelled", batchID: id, jobID: nil,
                                 message: "\(unfinished.count) unfinished file(s)" + (discardingParts ? ", partial files discarded" : ", partial files kept"))
            return unfinished
        }
    }

    /// Puts a cancelled batch back to work, keeping whatever progress was committed.
    public func resumeBatch(_ id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE job SET status = 'queued', updated_at = ? WHERE batch_id = ? AND status = 'cancelled'",
                           arguments: [Self.now(), id])
            let scanning = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM folder WHERE batch_id = ? AND scan_state = 'pending')", arguments: [id])!
            try db.execute(sql: "UPDATE batch SET state = ?, finished_at = NULL, updated_at = ? WHERE id = ? AND state = 'cancelled'",
                           arguments: [scanning ? "scanning" : "active", Self.now(), id])
        }
    }

    /// Copies the journal to `url` (a consistent snapshot, safe while in use). For support
    /// diagnostics and for tests that simulate losing the journal's latest transactions.
    public func backup(to url: URL) throws {
        let target = try DatabaseQueue(path: url.path)
        try pool.backup(to: target)
    }

    /// The unfinished (or cancelled, resumable) batch copying the same selection to the same place.
    public func unfinishedBatch(deviceKey: DeviceKey, storageID: StorageID, destinationRoot: URL, selection: [RemotePath]) throws -> BatchRecord? {
        try pool.read { db in
            try BatchRecord
                .filter(Column("device_key") == deviceKey.description && Column("storage_id") == Int64(storageID)
                    && Column("destination_root") == destinationRoot.path && Column("selection") == Self.selectionKey(selection))
                .filter(["scanning", "active", "cancelled"].contains(Column("state")))
                .order(Column("id").desc)
                .fetchOne(db)
        }
    }

    public func setBatchState(_ id: Int64, _ state: BatchState) throws {
        try pool.write { db in
            let finished: Int64? = state == .completed || state == .cancelled ? Self.now() : nil
            try db.execute(sql: "UPDATE batch SET state = ?, updated_at = ?, finished_at = ? WHERE id = ?",
                           arguments: [state.rawValue, Self.now(), finished, id])
        }
    }

    public func totals(batchID: Int64) throws -> BatchTotals {
        try pool.read { db in
            var totals = BatchTotals()
            let rows = try Row.fetchAll(db, sql: """
                SELECT status, COUNT(*) AS files, SUM(source_size) AS bytes, SUM(committed_offset) AS committed
                FROM job WHERE batch_id = ? GROUP BY status
                """, arguments: [batchID])
            for row in rows {
                let files: Int = row["files"]
                let bytes = UInt64(row["bytes"] as Int64? ?? 0)
                let committed = UInt64(row["committed"] as Int64? ?? 0)
                totals.filesTotal += files
                totals.bytesTotal += bytes
                switch JobStatus(rawValue: row["status"]) {
                case .done?:
                    totals.filesDone += files
                    totals.bytesDone += bytes
                case .skipped?:
                    totals.filesSkipped += files
                    totals.bytesDone += bytes
                case .needsAttention?:
                    totals.filesNeedingAttention += files
                case .cancelled?:
                    totals.filesCancelled += files
                default:
                    totals.bytesDone += committed
                }
            }
            return totals
        }
    }

    /// Jobs that failed for good, with their last error, for the "needs attention" list.
    public func attentionJobs(batchID: Int64) throws -> [JobRecord] {
        try pool.read { db in
            try JobRecord.filter(Column("batch_id") == batchID && Column("status") == JobStatus.needsAttention.rawValue)
                .order(Column("id")).fetchAll(db)
        }
    }

    /// Puts failed files back in the queue (user action "Try again").
    public func retryAttention(batchID: Int64) throws -> Int {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET status = 'queued', attempts = 0, restarts = 0, updated_at = ?
                WHERE batch_id = ? AND status = 'needs_attention'
                """, arguments: [Self.now(), batchID])
            let changed = db.changesCount
            if changed > 0 {
                try db.execute(sql: "UPDATE batch SET state = 'active', finished_at = NULL WHERE id = ? AND state = 'completed'", arguments: [batchID])
            }
            return changed
        }
    }

    public func nameMappings(batchID: Int64) throws -> [(source: String, destination: String, reason: String)] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT source_path, destination_path, reason FROM name_mapping WHERE batch_id = ? ORDER BY id",
                             arguments: [batchID]).map { ($0["source_path"], $0["destination_path"], $0["reason"]) }
        }
    }

    /// Batches the helper should know about at start: everything not removed, newest last.
    public func allBatches() throws -> [BatchRecord] {
        try pool.read { db in try BatchRecord.order(Column("id")).fetchAll(db) }
    }

    /// Forgets a batch and its history. Files already copied stay where they are.
    public func deleteBatch(_ id: Int64) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM event WHERE batch_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM job WHERE batch_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM folder WHERE batch_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM name_mapping WHERE batch_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM batch WHERE id = ?", arguments: [id])
        }
    }

    /// Clear History (privacy): forgets finished copies and the device log, then rebuilds the
    /// file so deleted names do not linger in free pages or the WAL. Only batches marked
    /// completed or cancelled go: running, queued, scanning and paused copies keep everything
    /// they need to resume, whatever the caller's view of them.
    public func clearHistory() throws {
        try pool.write { db in
            let finished = "SELECT id FROM batch WHERE state IN ('completed', 'cancelled')"
            try db.execute(sql: "DELETE FROM event WHERE batch_id IS NULL OR batch_id IN (\(finished))")
            try db.execute(sql: "DELETE FROM job WHERE batch_id IN (\(finished))")
            try db.execute(sql: "DELETE FROM folder WHERE batch_id IN (\(finished))")
            try db.execute(sql: "DELETE FROM name_mapping WHERE batch_id IN (\(finished))")
            try db.execute(sql: "DELETE FROM batch WHERE state IN ('completed', 'cancelled')")
            // Measured copy speeds are keyed by each phone's USB serial; they are learnt again.
            try db.execute(sql: "DELETE FROM setting WHERE key LIKE 'rate:%'")
        }
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    /// Most recently finished files of a batch, newest first (the Copy screen's list).
    public func recentlyFinishedJobs(batchID: Int64, limit: Int) throws -> [JobRecord] {
        try pool.read { db in
            try JobRecord.filter(Column("batch_id") == batchID && ["done", "skipped", "needs_attention"].contains(Column("status")))
                .order(Column("updated_at").desc, Column("id").desc).limit(limit).fetchAll(db)
        }
    }

    /// Log entries after `afterID` (newest first when nil), for the log viewer.
    public func events(afterID: Int64?, limit: Int) throws -> [EventRecord] {
        try pool.read { db in
            if let afterID {
                return try EventRecord.filter(Column("id") > afterID).order(Column("id")).limit(limit).fetchAll(db)
            }
            return try EventRecord.order(Column("id").desc).limit(limit).fetchAll(db).reversed()
        }
    }

    // MARK: Settings

    public func setting(_ key: String) throws -> String? {
        try pool.read { db in try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) }
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO setting (key, value, updated_at) VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
                """, arguments: [key, value, Self.now()])
        }
    }

    // MARK: Scanning

    public func nextPendingFolder(batchID: Int64) throws -> FolderRecord? {
        try pool.read { db in
            try FolderRecord.filter(Column("batch_id") == batchID && Column("scan_state") == "pending").order(Column("id")).fetchOne(db)
        }
    }

    /// Records a folder's complete listing: child folders to scan, files to copy, renamed names,
    /// and the folder's `done` state, all in one transaction.
    public func completeScan(of folder: FolderRecord, entries: [RemoteEntry]) throws -> (folders: Int, files: Int, bytes: UInt64) {
        try pool.write { db in
            guard let batch = try BatchRecord.fetchOne(db, key: folder.batchId) else { throw JournalError.notFound("batch \(folder.batchId)") }
            let now = Self.now()
            var scope = NameMapper.Scope(mapper: NameMapper(caseSensitive: batch.caseSensitive))
            var counts = (folders: 0, files: 0, bytes: UInt64(0))
            // Stable order, so a re-scan after an interruption assigns the same names.
            for entry in entries.sorted(by: { $0.name.utf8.lexicographicallyPrecedes($1.name.utf8) }) {
                try Self.insertChild(db, batch: batch, parent: folder, name: entry.name,
                                     sourcePath: RemotePath(folder.sourcePath).appending(entry.name),
                                     isFolder: entry.isFolder, size: entry.size, mtime: entry.modifiedWallClock, scope: &scope, now: now)
                if entry.isFolder { counts.folders += 1 } else { counts.files += 1; counts.bytes += entry.size }
            }
            try db.execute(sql: "UPDATE folder SET scan_state = 'done', scan_error = NULL WHERE id = ?", arguments: [folder.id!])
            if try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM folder WHERE batch_id = ? AND scan_state = 'pending')", arguments: [batch.id!])! {
                try db.execute(sql: "UPDATE batch SET state = 'active', updated_at = ? WHERE id = ? AND state = 'scanning'", arguments: [now, batch.id!])
            }
            return counts
        }
    }

    public func failScan(of folder: FolderRecord, message: String) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE folder SET scan_state = 'failed', scan_error = ? WHERE id = ?", arguments: [message, folder.id!])
            try Self.insertEvent(db, level: .error, kind: "scan_failed", batchID: folder.batchId, jobID: nil,
                                 message: "\(folder.sourcePath): \(message)")
            if try !Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM folder WHERE batch_id = ? AND scan_state = 'pending')", arguments: [folder.batchId])! {
                try db.execute(sql: "UPDATE batch SET state = 'active' WHERE id = ? AND state = 'scanning'", arguments: [folder.batchId])
            }
        }
    }

    public func failedFolders(batchID: Int64) throws -> [FolderRecord] {
        try pool.read { db in
            try FolderRecord.filter(Column("batch_id") == batchID && Column("scan_state") == "failed").fetchAll(db)
        }
    }

    private static func insertChild(
        _ db: Database, batch: BatchRecord, parent: FolderRecord, name: String, sourcePath: RemotePath,
        isFolder: Bool, size: UInt64, mtime: Int64, scope: inout NameMapper.Scope, now: Int64
    ) throws {
        let claimed = scope.claim(name)
        let destinationPath = parent.destinationPath.isEmpty ? claimed.name : parent.destinationPath + "/" + claimed.name
        if let reason = claimed.reason {
            try db.execute(sql: """
                INSERT INTO name_mapping (batch_id, kind, source_path, destination_path, reason) VALUES (?, ?, ?, ?, ?)
                """, arguments: [batch.id!, isFolder ? "folder" : "file", sourcePath.description, destinationPath, reason.rawValue])
        }
        if isFolder {
            var folder = FolderRecord(id: nil, batchId: batch.id!, parentId: parent.id, sourcePath: sourcePath.description,
                                      destinationPath: destinationPath, scanState: .pending, scanError: nil)
            try folder.insert(db, onConflict: .ignore)
        } else {
            let relative = batch.organize == BatchRecord.organizeByYearMonth ? Self.yearMonthFolder(mtime) : parent.destinationPath
            let directory = URL(fileURLWithPath: batch.destinationRoot)
                .appendingPathComponent(relative, isDirectory: true).standardizedFileURL.path
            var job = JobRecord(
                id: nil, uuid: UUID().uuidString, batchId: batch.id!, folderId: parent.id!, deviceKey: batch.deviceKey,
                storageId: batch.storageId, sourcePath: sourcePath.description, sourceSize: Int64(size), sourceMtimeWall: mtime,
                destinationDirectory: directory, destinationName: claimed.name, status: .queued, readStrategy: nil,
                committedOffset: 0, digestState: nil, digestFinal: nil, syncLevel: nil, attempts: 0, restarts: 0,
                lastError: nil, createdAt: now, updatedAt: now
            )
            try job.insert(db, onConflict: .ignore)
        }
    }

    /// "2026/09" from the phone's wall-clock time (encoded as UTC), or "Unknown date".
    static func yearMonthFolder(_ wallClock: Int64) -> String {
        guard wallClock > 0 else { return "Unknown date" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month], from: Date(timeIntervalSince1970: TimeInterval(wallClock)))
        return String(format: "%04d/%02d", parts.year ?? 1970, parts.month ?? 1)
    }

    static func selectionKey(_ paths: [RemotePath]) -> String {
        paths.map(\.description).sorted().joined(separator: "\n")
    }

    // MARK: Jobs

    public func job(_ id: Int64) throws -> JobRecord {
        guard let job = try pool.read({ db in try JobRecord.fetchOne(db, key: id) }) else {
            throw JournalError.notFound("job \(id)")
        }
        return job
    }

    public func jobs(batchID: Int64) throws -> [JobRecord] {
        try pool.read { db in try JobRecord.filter(Column("batch_id") == batchID).order(Column("id")).fetchAll(db) }
    }

    /// The next job to run, in scan order (so files arrive folder by folder).
    public func nextRunnableJob(batchID: Int64) throws -> JobRecord? {
        try pool.read { db in
            try JobRecord.filter(Column("batch_id") == batchID && ["queued", "in_progress", "finalizing"].contains(Column("status")))
                .order(Column("id")).fetchOne(db)
        }
    }

    public func events(forJob id: Int64) throws -> [EventRecord] {
        try pool.read { db in
            try EventRecord.filter(Column("job_id") == id).order(Column("id")).fetchAll(db)
        }
    }

    public func events(forBatch id: Int64) throws -> [EventRecord] {
        try pool.read { db in
            try EventRecord.filter(Column("batch_id") == id).order(Column("id")).fetchAll(db)
        }
    }

    /// Records that `[0, offset)` of the `.part` file is durable. Call only after a successful sync.
    public func commit(jobID: Int64, offset: UInt64, chain: Data, syncLevel: SyncLevel) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET committed_offset = ?, digest_state = ?, sync_level = ?, attempts = 0,
                  status = 'in_progress', last_error = NULL, updated_at = ?
                WHERE id = ? AND committed_offset <= ? AND status IN ('queued','in_progress')
                """, arguments: [Int64(offset), chain, syncLevel.rawValue, Self.now(), jobID, Int64(offset)])
            guard db.changesCount == 1 else {
                throw JournalError.invariantViolation("commit of \(offset) for job \(jobID) would move the offset backwards")
            }
        }
    }

    /// Marks a job as started, recording how it will be read.
    public func begin(jobID: Int64, readStrategy: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET status = 'in_progress', read_strategy = ?, updated_at = ?
                WHERE id = ? AND status IN ('queued','in_progress')
                """, arguments: [readStrategy, Self.now(), jobID])
        }
    }

    /// Lowers the committed offset because the disk holds fewer bytes than the journal claimed.
    public func correctOffset(jobID: Int64, to offset: UInt64, chain: Data?, reason: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET committed_offset = ?, digest_state = ?, updated_at = ? WHERE id = ?
                """, arguments: [Int64(offset), chain, Self.now(), jobID])
            try Self.insertEvent(db, level: .warning, kind: "part_truncated", jobID: jobID, message: reason)
        }
    }

    /// Starts the file over from byte zero, with the source's current identity.
    public func restart(jobID: Int64, sourceSize: UInt64, sourceMtimeWall: Int64, kind: String, reason: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET committed_offset = 0, digest_state = NULL, digest_final = NULL,
                  source_size = ?, source_mtime_wall = ?, restarts = restarts + 1,
                  status = 'in_progress', updated_at = ?
                WHERE id = ?
                """, arguments: [Int64(sourceSize), sourceMtimeWall, Self.now(), jobID])
            try Self.insertEvent(db, level: .notice, kind: kind, jobID: jobID, message: reason)
        }
    }

    /// All bytes are durable in the `.part` file, with the right date; next is the rename.
    public func markFinalizing(jobID: Int64, digest: Data, syncLevel: SyncLevel) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET status = 'finalizing', committed_offset = source_size, digest_final = ?,
                  sync_level = ?, updated_at = ?
                WHERE id = ? AND status IN ('queued','in_progress','finalizing')
                """, arguments: [digest, syncLevel.rawValue, Self.now(), jobID])
            guard db.changesCount == 1 else {
                throw JournalError.invariantViolation("job \(jobID) cannot enter finalizing from its current state")
            }
        }
    }

    public func markDone(jobID: Int64, destinationName: String, digest: Data? = nil, status: JobStatus = .done, note: String? = nil) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET status = ?, destination_name = ?, digest_final = COALESCE(?, digest_final),
                  committed_offset = CASE WHEN ? = 'done' THEN source_size ELSE committed_offset END,
                  last_error = NULL, updated_at = ?
                WHERE id = ?
                """, arguments: [status.rawValue, destinationName, digest, status.rawValue, Self.now(), jobID])
            if let note {
                try Self.insertEvent(db, level: .info, kind: status.rawValue, jobID: jobID, message: note)
            }
        }
    }

    /// Records many finished files in one transaction (grouped small files).
    public func markDone(_ files: [(jobID: Int64, destinationName: String, digest: Data)]) throws {
        try pool.write { db in
            let now = Self.now()
            let statement = try db.makeStatement(sql: """
                UPDATE job SET status = 'done', destination_name = ?, digest_final = ?,
                  committed_offset = source_size, last_error = NULL, updated_at = ?
                WHERE id = ?
                """)
            for file in files {
                try statement.execute(arguments: [file.destinationName, file.digest, now, file.jobID])
            }
        }
    }

    /// The next runnable job after `cursor` in id order (so deferred completions are not rerun).
    public func nextRunnableJob(batchID: Int64, after cursor: Int64) throws -> JobRecord? {
        try pool.read { db in
            try JobRecord.filter(Column("batch_id") == batchID && Column("id") > cursor
                                 && ["queued", "in_progress", "finalizing"].contains(Column("status")))
                .order(Column("id")).fetchOne(db)
        }
    }

    /// Records a failed attempt. Device disconnects must not be recorded as attempts.
    public func recordFailure(jobID: Int64, message: String, countsAsAttempt: Bool, permanent: Bool = false) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE job SET attempts = attempts + ?, last_error = ?, updated_at = ?,
                  status = CASE WHEN ? THEN 'needs_attention' ELSE status END
                WHERE id = ?
                """, arguments: [countsAsAttempt ? 1 : 0, message, Self.now(), permanent, jobID])
            try Self.insertEvent(db, level: permanent ? .error : .warning, kind: permanent ? "needs_attention" : "failure",
                                 jobID: jobID, message: message)
        }
    }

    public func log(_ level: EventRecord.Level, kind: String, batchID: Int64? = nil, jobID: Int64? = nil, message: String) throws {
        try pool.write { db in
            try Self.insertEvent(db, level: level, kind: kind, batchID: batchID, jobID: jobID, message: message)
        }
    }

    private static func insertEvent(_ db: Database, level: EventRecord.Level, kind: String, batchID: Int64? = nil, jobID: Int64?, message: String) throws {
        var batch = batchID
        if batch == nil, let jobID {
            batch = try Int64.fetchOne(db, sql: "SELECT batch_id FROM job WHERE id = ?", arguments: [jobID])
        }
        var event = EventRecord(id: nil, ts: now(), level: level, kind: kind, batchId: batch, jobId: jobID, message: message)
        try event.insert(db)
    }

    static func now() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
