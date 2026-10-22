import DeviceAPI
import Foundation
import PulliProtocol
import TransferCore
import USBKit

/// Runs every batch: one at a time per phone, phones in parallel. Turns the engine's events into
/// the snapshots the app and the menu bar show.
actor TransferService {
    struct Runtime {
        var record: BatchRecord
        var deviceName: String
        var totals: BatchTotals
        var phase: BatchPhase
        var current: FileSnapshot?
        var currentJob: JobRecord?
        var recent: [FileSnapshot]
        var bytesDone: UInt64
        var rateCalculator = TransferRateCalculator()
        var rate: Double { rateCalculator.rate }
    }

    private let journal: Journal
    private let sink: any FileSink
    private let hub: DeviceHub
    private let publish: @Sendable (HelperEvent) -> Void
    private var settings: HelperSettings
    private let timeZone: TimeZone
    private var runtimes: [Int64: Runtime] = [:]
    private var queues: [DeviceKey: [Int64]] = [:]
    private var running: [DeviceKey: (batchID: Int64, task: Task<Void, Never>)] = [:]
    private var dirty: Set<Int64> = []
    private var ticker: Task<Void, Never>?
    private let power = PowerAssertion()
    /// Timestamps of recent failed reads per phone, to detect struggling links.
    private var readFailures: [DeviceKey: [ContinuousClock.Instant]] = [:]
    /// Open chunk suggestions by device ID.
    private var suggestions: [String: ChunkSuggestion] = [:]
    /// Declined chunk sizes by device ID, remembered until the engine restarts.
    private var declinedChunkSizes: [String: Set<Int>] = [:]
    /// Test hook: how long supervisors wait between polls.
    private let pollInterval: Duration

    init(journal: Journal, sink: any FileSink, hub: DeviceHub, settings: HelperSettings, timeZone: TimeZone,
         pollInterval: Duration = .seconds(1), publish: @escaping @Sendable (HelperEvent) -> Void) {
        self.journal = journal
        self.sink = sink
        self.hub = hub
        self.settings = settings
        self.timeZone = timeZone
        self.pollInterval = pollInterval
        self.publish = publish
    }

    // MARK: Lifecycle

    /// Loads every batch from the journal and restarts unfinished ones (after a crash or reboot).
    func start() throws {
        for record in try journal.allBatches() {
            let totals = try journal.totals(batchID: record.id!)
            let recent = try journal.recentlyFinishedJobs(batchID: record.id!, limit: BatchSnapshot.recentLimit).map(Self.fileSnapshot)
            let phase: BatchPhase = switch record.state {
            case .completed: .completed
            case .cancelled: .cancelled
            case .paused: .paused(.byUser)
            case .scanning, .active: .paused(.queued)
            }
            runtimes[record.id!] = Runtime(record: record, deviceName: Self.deviceName(record.deviceKey), totals: totals, phase: phase,
                                           recent: recent, bytesDone: totals.bytesDone)
            if record.state == .scanning || record.state == .active { enqueue(record) }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.flushDirty()
            }
        }
    }

    func stop() async {
        ticker?.cancel()
        for (_, run) in running { run.task.cancel() }
        for (_, run) in running { await run.task.value }
        running.removeAll()
        power.release()
    }

    func update(settings: HelperSettings) {
        self.settings = settings
        updatePowerAssertion()
    }

    var snapshots: [BatchSnapshot] {
        runtimes.keys.sorted().compactMap(snapshot(for:))
    }

    // MARK: Commands

    func create(_ request: CreateBatchRequest, key: DeviceKey) async throws -> Int64 {
        let session = try await hub.open(key)
        defer { Task { await session.close() } }
        var items: [BatchItem] = []
        for path in request.paths.map({ RemotePath($0) }) {
            guard let entry = try await session.stat(path, storage: request.storageID) else {
                throw PulliError(.notFound, "\(path) is not on the phone")
            }
            items.append(BatchItem(entry, at: path))
        }
        let destination = URL(fileURLWithPath: (request.destinationPath as NSString).expandingTildeInPath).standardizedFileURL
        let policy = DuplicatePolicy(rawValue: request.duplicatePolicy ?? settings.duplicatePolicy) ?? .auto
        let caseSensitive = (try? Self.existingAncestor(of: destination).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
        let record = try journal.createBatch(deviceKey: key, storageID: request.storageID, destinationRoot: destination,
                                             items: items, duplicatePolicy: policy, caseSensitive: caseSensitive,
                                             organize: request.organize ?? settings.organize)
        runtimes[record.id!] = Runtime(record: record, deviceName: session.info.displayName, totals: try journal.totals(batchID: record.id!),
                                       phase: .paused(.queued), recent: [], bytesDone: 0)
        enqueue(record)
        publishNow(record.id!)
        return record.id!
    }

    func control(_ id: Int64, _ command: BatchCommand) async throws {
        guard var runtime = runtimes[id] else { throw PulliError(.notFound, "no batch \(id)") }
        let key = try Self.key(runtime.record)
        switch command {
        case .pause:
            try journal.setBatchState(id, .paused)
            await stopIfRunning(id, key: key)
            queues[key]?.removeAll { $0 == id }
            runtime = runtimes[id] ?? runtime
            runtime.phase = .paused(.byUser)
            runtime.rateCalculator.pause()
            runtimes[id] = runtime
        case .resume:
            guard runtime.phase != .completed else { return }
            try journal.resumeBatch(id)
            try journal.setBatchState(id, .active)
            runtime.record = try journal.batch(id)
            runtime.phase = .paused(.queued)
            runtime.rateCalculator.reset()
            runtimes[id] = runtime
            enqueue(runtime.record)
        case .cancel(let discard):
            await stopIfRunning(id, key: key)
            queues[key]?.removeAll { $0 == id }
            try BatchControl.cancel(batchID: id, journal: journal, sink: sink, discardParts: discard)
            runtime = runtimes[id] ?? runtime
            runtime.phase = .cancelled
            runtime.totals = try journal.totals(batchID: id)
            runtime.current = nil
            runtimes[id] = runtime
        case .retryNeedsAttention:
            _ = try journal.retryAttention(batchID: id)
            runtime.record = try journal.batch(id)
            runtime.totals = try journal.totals(batchID: id)
            if runtime.record.state == .active {
                runtime.phase = .paused(.queued)
                runtimes[id] = runtime
                enqueue(runtime.record)
            } else {
                runtimes[id] = runtime
            }
        case .remove:
            guard running[key]?.batchID != id else { throw PulliError(.invalidRequest, "pause or cancel the copy first") }
            queues[key]?.removeAll { $0 == id }
            try journal.deleteBatch(id)
            runtimes[id] = nil
            publish(.batchRemoved(id: id))
            return
        }
        publishNow(id)
        pump(key)
    }

    func attention(_ id: Int64) throws -> [AttentionItem] {
        try journal.attentionJobs(batchID: id).map { AttentionItem(jobID: $0.id!, path: $0.sourcePath, reason: $0.lastError ?? "Unknown problem") }
    }

    /// Clear History: forgets finished copies (never one that is running) and the device log.
    func clearHistory() async throws {
        var finished: [Int64] = []
        for (id, runtime) in runtimes {
            let isRunning = (try? Self.key(runtime.record)).flatMap { running[$0]?.batchID == id } ?? false
            if !isRunning && (runtime.record.state == .completed || runtime.record.state == .cancelled || runtime.phase == .completed || runtime.phase == .cancelled) {
                finished.append(id)
            }
        }
        for id in finished {
            guard let runtime = runtimes[id] else { continue }
            if let key = try? Self.key(runtime.record) {
                queues[key]?.removeAll { $0 == id }
            }
            try journal.deleteBatch(id)
            runtimes[id] = nil
            publish(.batchRemoved(id: id))
        }
        try journal.clearHistory()
    }

    // MARK: Scheduling

    private func enqueue(_ record: BatchRecord) {
        guard let key = try? Self.key(record) else { return }
        if !(queues[key]?.contains(record.id!) ?? false), running[key]?.batchID != record.id {
            queues[key, default: []].append(record.id!)
        }
        pump(key)
    }

    private func pump(_ key: DeviceKey) {
        guard running[key] == nil, var queue = queues[key], !queue.isEmpty else { return }
        let id = queue.removeFirst()
        queues[key] = queue
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id, key: key)
        }
        running[key] = (id, task)
        updatePowerAssertion()
    }

    private func stopIfRunning(_ id: Int64, key: DeviceKey) async {
        guard let run = running[key], run.batchID == id else { return }
        run.task.cancel()
        await run.task.value
    }

    private func run(_ id: Int64, key: DeviceKey) async {
        var configuration = TransferConfiguration()
        configuration.chunkBytes = max(1, min(64, settings.chunkMiB(for: key.description))) << 20
        configuration.destinationTimeZone = timeZone
        var supervisor = TransferSupervisor(connector: hub, journal: journal, sink: sink, configuration: configuration)
        supervisor.pollInterval = pollInterval
        if pollInterval < .milliseconds(50) {
            supervisor.sleep = { try await Task.sleep(for: $0 > .milliseconds(20) ? .milliseconds(20) : $0) }
        }

        setPhase(id, runtimes[id]?.record.state == .scanning ? .scanning : .copying)
        // Events are applied in order through one stream: "file finished" must never overtake
        // "file started".
        let (events, eventSink) = AsyncStream<SupervisorEvent>.makeStream()
        let consumer = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.apply(event, to: id)
            }
        }
        defer { eventSink.finish() }
        do {
            let totals = try await supervisor.run(batchID: id) { eventSink.yield($0) }
            eventSink.finish()
            await consumer.value
            if let runtime = runtimes[id], runtime.rate > 0 {
                await recordRate(runtime.rate, key: key)
            }
            if var runtime = runtimes[id] {
                runtime.totals = totals
                runtime.bytesDone = totals.bytesDone
                runtime.record = (try? journal.batch(id)) ?? runtime.record
                runtime.current = nil
                runtime.rateCalculator.reset()
                runtimes[id] = runtime
            }
            setPhase(id, .completed)
        } catch is CancellationError {
            // Paused or cancelled by the user; `control` sets the phase.
        } catch {
            try? journal.log(.error, kind: "batch_stopped", batchID: id, message: "\(error)")
            setPhase(id, .paused(.unknown))
        }
        running[key] = nil
        updatePowerAssertion()
        pump(key)
    }

    // MARK: Events → runtime

    private func apply(_ event: SupervisorEvent, to id: Int64) async {
        guard var runtime = runtimes[id] else { return }
        // Events can arrive after a pause or cancel; they must not undo it.
        if case .paused(.byUser) = runtime.phase { return }
        if runtime.phase == .cancelled || runtime.phase == .completed { return }

        switch event {
        case .connected(let info):
            runtime.deviceName = info.displayName
            if case .paused = runtime.phase { runtime.phase = runtime.record.state == .scanning ? .scanning : .copying }
            runtime.rateCalculator.reset()
        case .waiting(let reason):
            runtime.phase = .paused(Self.pauseReason(reason))
            runtime.rateCalculator.pause()
        case .batch(.scanning(_, _, let files, _)):
            runtime.phase = .scanning
            runtime.totals.filesTotal = max(runtime.totals.filesTotal, files)
        case .batch(.fileStarted(let job)):
            if runtime.phase == .scanning { runtime.record.state = .active }
            runtime.phase = .copying
            runtime.currentJob = job
            runtime.current = FileSnapshot(jobID: job.id!, name: RemotePath(job.sourcePath).name, sizeBytes: UInt64(job.sourceSize),
                                           bytesDone: UInt64(job.committedOffset), state: .copying)
        case .batch(.progress(let progress)):
            runtime.phase = .copying
            runtime.totals = progress.totals
            runtime.bytesDone = progress.bytesDone
            runtime.current?.bytesDone = progress.file.bytesReceived
            runtime.rateCalculator.apply(progress: progress)
        case .batch(.fileFinished(let job, _)), .batch(.fileNeedsAttention(let job, _)):
            if let started = runtime.currentJob, started.id == job.id {
                runtime.totals.replace(started, with: job)
            }
            runtime.bytesDone = runtime.totals.bytesDone
            runtime.recent.insert(Self.fileSnapshot(job), at: 0)
            runtime.recent = Array(runtime.recent.prefix(BatchSnapshot.recentLimit))
            runtime.current = nil
            runtime.currentJob = nil
        case .batch(.readFailed):
            if let key = try? Self.key(runtime.record) {
                await recordReadFailure(for: key)
            }
        case .finished(let totals):
            runtime.totals = totals
            runtime.bytesDone = totals.bytesDone
        }
        let phaseChanged = runtimes[id]?.phase != runtime.phase
        runtimes[id] = runtime
        if phaseChanged { publishNow(id) } else { dirty.insert(id) }
    }

    // MARK: Chunk suggestions

    /// Records a failed read for this phone and suggests a smaller chunk if failures persist.
    private func recordReadFailure(for key: DeviceKey) async {
        let now = ContinuousClock.now
        let cutoff = now - .seconds(600)
        var failures = (readFailures[key] ?? []).filter { $0 >= cutoff }
        failures.append(now)
        readFailures[key] = failures

        let deviceID = key.description
        let current = settings.chunkMiB(for: deviceID)
        guard failures.count >= 3,
              current >= 4,
              suggestions[deviceID] == nil,
              !(declinedChunkSizes[deviceID]?.contains(current) ?? false) else {
            return
        }

        let suggested = max(1, current / 4)
        let suggestion = ChunkSuggestion(deviceID: deviceID, currentMiB: current, suggestedMiB: suggested, failures: failures.count)
        suggestions[deviceID] = suggestion

        if var snapshot = await hub.snapshot(forID: deviceID) {
            snapshot.chunkSuggestion = suggestion
            publish(.deviceChanged(snapshot))
        }
    }

    func chunkSuggestion(for deviceID: String) -> ChunkSuggestion? {
        suggestions[deviceID]
    }

    func clearSuggestion(for deviceID: String) {
        suggestions[deviceID] = nil
    }

    func rememberDecline(for deviceID: String, size: Int) {
        suggestions[deviceID] = nil
        declinedChunkSizes[deviceID, default: []].insert(size)
    }

    /// Restarts the active run for a phone so that updated chunk size settings apply immediately.
    func restartRunningBatch(for key: DeviceKey) async {
        guard let run = running[key] else { return }
        let id = run.batchID
        if !(queues[key]?.contains(id) ?? false) {
            queues[key, default: []].insert(id, at: 0)
        }
        await stopIfRunning(id, key: key)
    }

    private func setPhase(_ id: Int64, _ phase: BatchPhase) {
        guard var runtime = runtimes[id] else { return }
        runtime.phase = phase
        if phase == .completed { runtime.record.finishedAt = Int64(Date().timeIntervalSince1970 * 1000) }
        runtimes[id] = runtime
        publishNow(id)
    }

    private func publishNow(_ id: Int64) {
        dirty.remove(id)
        if let snapshot = snapshot(for: id) { publish(.batchChanged(snapshot)) }
    }

    private func flushDirty() {
        let ids = dirty
        dirty.removeAll()
        for id in ids { if let snapshot = snapshot(for: id) { publish(.batchChanged(snapshot)) } }
    }

    /// Remembers how fast this phone copied on its current link, for future time estimates.
    private func recordRate(_ rate: Double, key: DeviceKey) async {
        guard let link = await hub.snapshot(forID: key.description)?.link else { return }
        let name = MeasuredRates.key(key, link)
        let previous = (try? journal.setting(name)).flatMap(Double.init)
        let blended = previous.map { $0 * 0.5 + rate * 0.5 } ?? rate
        try? journal.setSetting(name, String(blended))
    }

    private func updatePowerAssertion() {
        if settings.keepMacAwake, !running.isEmpty {
            power.hold(reason: "Pulli is copying files from your phone")
        } else {
            power.release()
        }
    }

    private func snapshot(for id: Int64) -> BatchSnapshot? {
        guard let runtime = runtimes[id] else { return nil }
        let record = runtime.record
        let remaining = runtime.phase == .copying ? runtime.rateCalculator.secondsRemaining(bytesDone: runtime.bytesDone, bytesTotal: runtime.totals.bytesTotal) : nil
        let title = record.selection.split(separator: "\n").map { RemotePath(String($0)).name }.joined(separator: ", ")
        return BatchSnapshot(
            id: id, deviceID: record.deviceKey, deviceName: runtime.deviceName, title: title,
            destinationPath: record.destinationRoot, phase: runtime.phase,
            filesTotal: runtime.totals.filesTotal, filesDone: runtime.totals.filesDone, filesSkipped: runtime.totals.filesSkipped,
            filesNeedingAttention: runtime.totals.filesNeedingAttention, bytesTotal: runtime.totals.bytesTotal,
            bytesDone: runtime.bytesDone, bytesPerSecond: runtime.rate,
            secondsRemaining: remaining,
            current: runtime.current, recent: runtime.recent,
            createdAt: Date(timeIntervalSince1970: TimeInterval(record.createdAt) / 1000),
            finishedAt: record.finishedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        )
    }

    // MARK: Helpers

    static func pauseReason(_ reason: WaitReason) -> PauseReason {
        switch reason {
        case .disconnected: .phoneDisconnected
        case .locked: .phoneLocked
        case .notInFileTransferMode: .notInFileTransferMode
        case .heldBy(let holder): .heldBy(appName: CameraClientApps.sanitizedHolderName(holder.name))
        case .destination(.noSpace): .destinationFull
        case .destination(let error): .destinationUnavailable(detail: error.description)
        case .retrying(let after, let detail): .retrying(secondsLeft: Int(after.components.seconds), detail: detail)
        }
    }

    static func fileSnapshot(_ job: JobRecord) -> FileSnapshot {
        let state: FileSnapshot.FileState = switch job.status {
        case .done: .done
        case .skipped: .skipped
        case .needsAttention: .needsAttention
        case .cancelled: .cancelled
        case .inProgress, .finalizing: .copying
        case .queued: .waiting
        }
        return FileSnapshot(jobID: job.id!, name: RemotePath(job.sourcePath).name, sizeBytes: UInt64(job.sourceSize),
                            bytesDone: job.status == .done ? UInt64(job.sourceSize) : UInt64(job.committedOffset), state: state)
    }

    static func key(_ record: BatchRecord) throws -> DeviceKey {
        guard let key = DeviceKey(parsing: record.deviceKey) else {
            throw PulliError(.internalError, "unreadable device key \(record.deviceKey)")
        }
        return key
    }

    static func deviceName(_ key: String) -> String {
        "Phone \(key.split(separator: ":").last.map(String.init) ?? "")"
    }

    static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }
}
