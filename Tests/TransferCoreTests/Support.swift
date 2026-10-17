import CryptoKit
import DeviceAPI
import Foundation
import MockDevice
import Synchronization
import Testing
import TransferCore

/// A temporary destination folder and journal, removed when the test ends.
final class Workspace {
    let root: URL
    let destination: URL
    private var openJournal: Journal?

    var journal: Journal { openJournal! }
    var journalURL: URL { root.appendingPathComponent("journal.sqlite") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-tests-\(UUID().uuidString)")
        destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        openJournal = try Journal(url: root.appendingPathComponent("journal.sqlite"))
    }

    deinit {
        openJournal = nil
        try? FileManager.default.removeItem(at: root)
    }

    /// Closes and reopens the journal, as a restarted helper would. The old instance must be gone
    /// first: it holds the single-writer lock.
    func reopenJournal(replacingWith snapshot: URL? = nil) throws {
        openJournal = nil
        if let snapshot {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: journalURL.path + suffix)
            }
            try FileManager.default.copyItem(at: snapshot, to: journalURL)
        }
        openJournal = try Journal(url: journalURL)
    }

    /// A batch selecting these paths on the device's default storage.
    func batch(_ device: MockDevice, _ paths: [RemotePath], policy: DuplicatePolicy = .auto, organize: String? = nil) async throws -> BatchRecord {
        let session = try device.connect()
        var items: [BatchItem] = []
        for path in paths {
            let entry = try #require(try await session.stat(path, storage: device.defaultStorage), "\(path) not on device")
            items.append(BatchItem(entry, at: path))
        }
        return try journal.createBatch(deviceKey: device.key, storageID: device.defaultStorage, destinationRoot: destination,
                                       items: items, duplicatePolicy: policy, organize: organize)
    }

    /// The job for a single selected file.
    func job(for device: MockDevice, _ path: RemotePath, policy: DuplicatePolicy = .auto) async throws -> JobRecord {
        let batch = try await batch(device, [path], policy: policy)
        return try #require(try journal.jobs(batchID: batch.id!).first)
    }

    /// Every `.part` file left anywhere under the destination.
    func leftoverPartFiles() -> [String] {
        let enumerator = FileManager.default.enumerator(atPath: destination.path)
        return (enumerator?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".part") }
    }

    /// All regular files under the destination, as relative paths.
    func destinationFiles() -> Set<String> {
        let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isRegularFileKey])
        var result: Set<String> = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.insert(String(url.standardizedFileURL.path.dropFirst(destination.standardizedFileURL.path.count + 1)))
            }
        }
        return result
    }
}

enum TestConfig {
    /// Small commits so a 20 MiB file crosses several block boundaries.
    static var transfer: TransferConfiguration {
        var configuration = TransferConfiguration()
        configuration.chunkBytes = 1 << 20
        configuration.commitBytes = ChainDigest.blockSize
        configuration.commitInterval = .seconds(3600)
        configuration.tailGuardBytes = 256 << 10
        configuration.destinationTimeZone = TimeZone(identifier: "Europe/Berlin")!
        return configuration
    }
}

/// Counts calls across concurrency domains.
final class Counter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int {
        value.withLock { $0 += 1; return $0 }
    }

    var current: Int { value.withLock { $0 } }
}

/// Deterministic random numbers shared by a fault injector (the engine is sequential, so the
/// sequence of draws, and so the whole run, is reproducible from the seed).
final class SeededRandom: Sendable {
    private let state: Mutex<UInt64>

    init(seed: UInt64) {
        state = Mutex(seed &+ 0x9E37_79B9_7F4A_7C15)
    }

    func next() -> UInt64 {
        state.withLock { state in
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// True with probability `p`.
    func chance(_ p: Double) -> Bool {
        Double(next() >> 11) / Double(1 << 53) < p
    }

    func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
}

/// Collects supervisor events for assertions.
final class EventLog: Sendable {
    private let events = Mutex<[SupervisorEvent]>([])

    func append(_ event: SupervisorEvent) { events.withLock { $0.append(event) } }

    var waits: [WaitReason] {
        events.withLock { $0.compactMap { if case .waiting(let reason) = $0 { reason } else { nil } } }
    }

    var needsAttention: [String] {
        events.withLock {
            $0.compactMap { if case .batch(.fileNeedsAttention(let job, _)) = $0 { job.sourcePath } else { nil } }
        }
    }
}

extension TransferSupervisor {
    /// A supervisor over mock devices whose "waits" run instantly. `onSleep` runs at every wait,
    /// which is where tests fix the world (replug, unlock, free space). By default it replugs.
    static func mock(
        _ device: MockDevice, workspace: Workspace, sink: any FileSink = POSIXFileSink(),
        configuration: TransferConfiguration = TestConfig.transfer,
        onSleep: @escaping @Sendable () -> Void = {}
    ) -> TransferSupervisor {
        var supervisor = TransferSupervisor(connector: MockConnector(device), journal: workspace.journal, sink: sink, configuration: configuration)
        let sleeps = Counter()
        supervisor.sleep = { _ in
            if sleeps.increment() > 20_000 { throw CancellationError() }
            if !device.isPluggedIn { device.plug() }
            onSleep()
            await Task.yield()
        }
        return supervisor
    }
}

/// Runs a single file transfer like the supervisor does: on disconnect, replug and resume.
func transferWithReconnects(
    _ device: MockDevice, jobID: Int64, workspace: Workspace, sink: any FileSink = POSIXFileSink(),
    configuration: TransferConfiguration = TestConfig.transfer, maxReconnects: Int = 50
) async throws -> (outcome: TransferOutcome, reconnects: Int) {
    var reconnects = 0
    while true {
        let session = try device.connect()
        do {
            let transfer = FileTransfer(session: session, journal: workspace.journal, sink: sink, configuration: configuration)
            return (try await transfer.run(jobID: jobID), reconnects)
        } catch DeviceError.deviceGone {
            reconnects += 1
            guard reconnects <= maxReconnects else { throw DeviceError.deviceGone }
            device.plug()
        }
    }
}

/// Checks every finished job of a batch against the phone's current content.
func expectBatchMatchesDevice(_ workspace: Workspace, _ device: MockDevice, batchID: Int64,
                              sourceLocation: SourceLocation = #_sourceLocation) throws {
    for job in try workspace.journal.jobs(batchID: batchID) where job.status == .done || job.status == .skipped {
        let copied = try Data(contentsOf: job.destinationURL)
        let expected = try #require(device.expectedContent(RemotePath(job.sourcePath)), sourceLocation: sourceLocation)
        #expect(copied == expected, "\(job.sourcePath) → \(job.destinationURL.path)", sourceLocation: sourceLocation)
    }
    #expect(workspace.leftoverPartFiles().isEmpty, sourceLocation: sourceLocation)
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha256(of url: URL) throws -> String {
    sha256(try Data(contentsOf: url))
}

/// A destination that fails in scripted ways, wrapping the real POSIX sink.
final class ScriptedSink: FileSink, @unchecked Sendable {
    private let base = POSIXFileSink()
    private let lock = NSLock()
    /// Throw `.noSpace` once this many bytes were written through any part file.
    var diskFullAfterBytes: UInt64? {
        get { lock.withLock { _diskFullAfterBytes } }
        set { lock.withLock { _diskFullAfterBytes = newValue } }
    }
    private var _diskFullAfterBytes: UInt64?
    /// Simulate the helper dying (throw a non-destination error) after this many bytes.
    var crashAfterBytes: UInt64?
    /// Fail the next rename by "crashing".
    var crashOnNextRename = false
    private(set) var bytesWritten: UInt64 = 0

    func openPart(at url: URL) throws(DestinationError) -> any PartFile {
        ScriptedPart(base: try base.openPart(at: url), sink: self)
    }

    func attributes(of url: URL) -> (size: UInt64, modified: Date)? { base.attributes(of: url) }
    func jobTag(of url: URL) -> String? { base.jobTag(of: url) }

    func renameExclusive(_ source: URL, to destination: URL) throws(DestinationError) {
        try crashIfScripted()
        try base.renameExclusive(source, to: destination)
    }

    func renameReplacing(_ source: URL, to destination: URL) throws(DestinationError) {
        try crashIfScripted()
        try base.renameReplacing(source, to: destination)
    }

    private func crashIfScripted() throws(DestinationError) {
        let crash = lock.withLock { () -> Bool in
            defer { crashOnNextRename = false }
            return crashOnNextRename
        }
        if crash { throw .io(code: EINTR, context: "simulated crash before rename") }
    }

    func syncDirectory(_ url: URL, _ request: SyncRequest) throws(DestinationError) { try base.syncDirectory(url, request) }
    func createDirectory(_ url: URL) throws(DestinationError) { try base.createDirectory(url) }
    func remove(_ url: URL) { base.remove(url) }

    func availableCapacity(at url: URL) -> UInt64? {
        let full = lock.withLock { _diskFullAfterBytes.map { bytesWritten >= $0 } ?? false }
        return full ? 0 : base.availableCapacity(at: url)
    }

    func volumeID(of url: URL) -> UInt64? { base.volumeID(of: url) }

    func willWrite(_ count: Int) throws(DestinationError) {
        let (full, crash) = lock.withLock { () -> (Bool, Bool) in
            let after = bytesWritten + UInt64(count)
            if let limit = _diskFullAfterBytes, after > limit {
                bytesWritten = max(bytesWritten, limit)
                return (true, false)
            }
            if let limit = crashAfterBytes, after > limit { return (false, true) }
            bytesWritten = after
            return (false, false)
        }
        if full { throw .noSpace }
        if crash { throw .io(code: EINTR, context: "simulated crash") }
    }
}

final class ScriptedPart: PartFile {
    private let base: any PartFile
    private let sink: ScriptedSink

    init(base: any PartFile, sink: ScriptedSink) {
        self.base = base
        self.sink = sink
    }

    func size() throws(DestinationError) -> UInt64 { try base.size() }

    func write(_ data: Data, at offset: UInt64) throws(DestinationError) {
        try sink.willWrite(data.count)
        try base.write(data, at: offset)
    }

    func read(at offset: UInt64, count: Int) throws(DestinationError) -> Data { try base.read(at: offset, count: count) }
    func truncate(to length: UInt64) throws(DestinationError) { try base.truncate(to: length) }
    func sync(_ request: SyncRequest) throws(DestinationError) -> SyncLevel { try base.sync(request) }
    func setModificationDate(_ date: Date) throws(DestinationError) { try base.setModificationDate(date) }
    func setJobTag(_ tag: String) throws(DestinationError) { try base.setJobTag(tag) }
    func close() { base.close() }
}
