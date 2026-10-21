public import DeviceAPI
import Foundation
public import PulliProtocol
import WorkerIPC

// `DeviceCandidate` and `DeviceWatcher` live in DeviceAPI, so phone backends need not depend on
// HelperCore.

/// The helper's view of phones: what is attached, what state each is in, and shared sessions.
///
/// A phone is only opened while something needs it (the app is open, or a copy wants it).
/// Otherwise a helper that runs at login would take every Android phone plugged into the Mac away
/// from Photos and other apps, even when the user is not using Pulli.
public actor DeviceHub: DeviceConnector {
    struct Entry {
        var candidate: DeviceCandidate
        var session: (any DeviceSession)?
        var info: DeviceInfo?
        var storages: [StorageInfo] = []
        var state: DeviceState = .connecting
        var leases = 0
        var lastUsed = ContinuousClock.now
        var nextAttempt = ContinuousClock.now
        var failures = 0
        /// When the current session last started: a session that stays "locked" is renewed.
        var openedAt = ContinuousClock.now
        /// Renewals while it stayed locked: each waits twice as long (up to a minute), as every
        /// open starts a worker process.
        var lockedRenewals = 0
        /// Incremented when the device reports that its catalogue or contents changed.
        var contentRevision: UInt64 = 0
        /// Progress while opening (0...100 percent), e.g. ImageCaptureCore catalogue loading.
        var catalogueProgress: Int? = nil
    }

    private let connector: any DeviceConnector
    private let watcher: any DeviceWatcher
    private var entries: [DeviceKey: Entry] = [:]
    private var uiWantsDevices = false
    private var onChange: (@Sendable (DeviceSnapshot) -> Void)?
    private var onRemove: (@Sendable (String) -> Void)?
    private var pollTask: Task<Void, Never>?
    /// Opens in flight, shared by everyone who asks for the same phone meanwhile.
    private var opening: [DeviceKey: Task<Result<(any DeviceSession, [StorageInfo]), DeviceError>, Never>] = [:]
    private let idleClose: Duration
    private let pollInterval: Duration
    /// How long a session may stay "locked" (no storage) before it is renewed.
    private let lockedRenewal: Duration

    /// Measured copy speed for a phone on a link, from earlier copies (bytes per second).
    private let measuredRate: @Sendable (DeviceKey, LinkSpeed) -> Double?
    /// Told about failures to open a phone (first failure, and when giving up), for the log.
    private let reportFailure: @Sendable (String, DeviceError) -> Void

    public init(connector: any DeviceConnector, watcher: any DeviceWatcher,
                pollInterval: Duration = .seconds(1), idleClose: Duration = .seconds(30), lockedRenewal: Duration = .seconds(10),
                measuredRate: @escaping @Sendable (DeviceKey, LinkSpeed) -> Double? = { _, _ in nil },
                reportFailure: @escaping @Sendable (String, DeviceError) -> Void = { _, _ in }) {
        self.connector = connector
        self.reportFailure = reportFailure
        self.watcher = watcher
        self.measuredRate = measuredRate
        self.pollInterval = pollInterval
        self.idleClose = idleClose
        self.lockedRenewal = lockedRenewal
        (connector as? any DeviceOpeningProgress)?.setProgressHandler { [weak self] key, percent in
            Task { [weak self] in
                await self?.handleOpeningProgress(key: key, percent: percent)
            }
        }
    }

    public func observe(onChange: @escaping @Sendable (DeviceSnapshot) -> Void, onRemove: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
        self.onRemove = onRemove
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        for key in entries.keys {
            await entries[key]?.session?.close()
            entries[key]?.session = nil
        }
    }

    /// Whether the app is showing phones (then attached phones are opened to show their state).
    public func setUIActive(_ active: Bool) async {
        uiWantsDevices = active
        await poll()
    }

    public var snapshots: [DeviceSnapshot] {
        entries.keys.sorted { $0.description < $1.description }.compactMap(snapshot(for:))
    }

    public func snapshot(forID id: String) -> DeviceSnapshot? {
        entries.first { $0.key.description == id }.flatMap { snapshot(for: $0.key) }
    }

    public func key(forID id: String) -> DeviceKey? {
        entries.keys.first { $0.description == id }
    }

    // MARK: DeviceConnector (for transfers and browsing)

    /// A lease on the phone's shared session, opening it if needed.
    public func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        guard entries[key] != nil else { throw .deviceGone }
        let session = try await ensureOpen(key, force: true)
        entries[key]?.leases += 1
        entries[key]?.lastUsed = .now
        return LeasedSession(session, hub: self, key: key)
    }

    func release(_ key: DeviceKey, session: any DeviceSession, failed: Bool) async {
        guard var entry = entries[key] else { return }
        entry.leases = max(0, entry.leases - 1)
        entry.lastUsed = .now
        if failed, let current = entry.session, current === session {
            // The next user gets a fresh session: the supervisor's recovery depends on it.
            entry.session = nil
            entries[key] = entry
            await current.close()
            await refreshState(key)
            return
        }
        entries[key] = entry
    }

    // MARK: Polling

    func poll() async {
        let attached = await watcher.currentDevices()
        var seen: Set<DeviceKey> = []
        for candidate in attached {
            guard let key = candidate.key else { continue }
            seen.insert(key)
            let isNew = entries[key] == nil
            if isNew {
                entries[key] = Entry(candidate: candidate)
                if let initial = snapshot(for: key) {
                    onChange?(initial)
                }
            } else if let previous = entries[key]?.candidate {
                entries[key]?.candidate = candidate
                // The phone came back on the bus: a new USB address (it switched USB mode, say
                // from charging to file transfer, or was replugged). Earlier failures are moot:
                // try now, not after the backoff (it reached 16 s, and the phone sat unseen).
                if candidate.usb.address != previous.usb.address || candidate.usb.productID != previous.usb.productID
                    || candidate.hasFileTransferInterface != previous.hasFileTransferInterface {
                    entries[key]?.failures = 0
                    entries[key]?.nextAttempt = .now
                }
            }
            await refreshState(key, isNew: isNew)
        }
        for key in entries.keys where !seen.contains(key) {
            if let session = entries[key]?.session { await session.close() }
            entries[key] = nil
            onRemove?(key.description)
        }
    }

    private func refreshState(_ key: DeviceKey, isNew: Bool = false) async {
        guard var entry = entries[key] else { return }
        // A phone that just appeared is always announced, even if nothing else changed.
        let before = isNew ? nil : snapshot(for: key)

        if !entry.candidate.hasFileTransferInterface {
            if let session = entry.session { await session.close() }
            entry.session = nil
            entry.state = .notInFileTransferMode
        } else if let app = entry.candidate.heldByApp, entry.session == nil {
            entry.state = .heldBy(appName: app)
        } else if entry.session == nil, uiWantsDevices || entry.leases > 0, ContinuousClock.now >= entry.nextAttempt {
            entry.state = .connecting
            entries[key] = entry
            if !isNew, let initial = snapshot(for: key), initial != before {
                onChange?(initial)
            }
            _ = try? await ensureOpen(key, force: false)
            guard let updated = entries[key] else { return }
            entry = updated
        } else if let session = entry.session {
            if entry.leases == 0, !uiWantsDevices, ContinuousClock.now - entry.lastUsed > idleClose {
                // Nobody needs the phone: give it back to macOS and other apps.
                entry.session = nil
                entry.info = nil
                entry.state = .connecting
                await session.close()
            } else if entry.candidate.heldBySystemCamera {
                // Regression (2026-10-14, Galaxy Z Fold7): macOS relaunched its camera service a
                // second after the worker started and it took the phone; every storage check then
                // failed, read as "no storage", and Pulli showed "locked" for good. A fresh open
                // releases the service and claims the phone again.
                entry.session = nil
                entry.state = .connecting
                entry.nextAttempt = .now
                await session.close()
            } else if entry.state == .locked {
                // Poll only while locked, to notice the unlock; a ready phone is left alone.
                let storages = (try? await session.storages()) ?? entry.storages
                entry.storages = storages
                entry.state = storages.isEmpty ? .locked : .ready
                if !storages.isEmpty { entry.lockedRenewals = 0 }
                let wait = min(lockedRenewal * (1 << min(entry.lockedRenewals, 3)), max(lockedRenewal, .seconds(60)))
                if storages.isEmpty, entry.leases == 0, ContinuousClock.now - entry.openedAt > wait {
                    // Still nothing after a while: start a fresh session. Some phones show their
                    // files only to a session opened after "Allow", and a session that silently
                    // lost the phone recovers this way too.
                    entry.session = nil
                    entry.nextAttempt = .now
                    entry.lockedRenewals += 1
                    await session.close()
                }
            }
        }
        entries[key] = entry
        if let after = snapshot(for: key), after != before {
            onChange?(after)
        }
    }

    /// Opens the phone's session if it has none. `force` ignores the retry backoff (a transfer asked).
    ///
    /// Opening a real phone takes seconds (releasing ptpcamerad, claiming the interface), and the
    /// poll loop, `setUIActive` and transfers can all ask meanwhile: every caller shares the one
    /// attempt in flight. A second worker would find the phone held by the first.
    private func ensureOpen(_ key: DeviceKey, force: Bool) async throws(DeviceError) -> any DeviceSession {
        guard let current = entries[key] else { throw .deviceGone }
        if let session = current.session { return session }
        if let pending = opening[key] { return try await pending.value.get().0 }
        if !force, ContinuousClock.now < current.nextAttempt { throw .transient("waiting before retrying") }

        let attempt = Task { [connector] () -> Result<(any DeviceSession, [StorageInfo]), DeviceError> in
            do throws(DeviceError) {
                let session = try await connector.open(key)
                let storages = (try? await session.storages()) ?? []
                return .success((session, storages))
            } catch {
                return .failure(error)
            }
        }
        opening[key] = attempt
        let result = await attempt.value
        opening[key] = nil

        // Re-read the entry: leases and the candidate may have changed while opening.
        switch result {
        case .success(let (session, storages)):
            guard var entry = entries[key] else {
                await session.close()
                throw .deviceGone
            }
            entry.session = session
            entry.openedAt = .now
            entry.info = session.info
            entry.storages = storages
            entry.state = storages.isEmpty ? .locked : .ready
            entry.catalogueProgress = nil
            entry.failures = 0
            entry.lastUsed = .now
            entries[key] = entry
            session.onContentChanged = { [weak self, key] in
                Task { [weak self] in
                    await self?.handleContentChanged(for: key)
                }
            }
            if let snapshot = snapshot(for: key) { onChange?(snapshot) }
            return session
        case .failure(let error):
            guard var entry = entries[key] else { throw error }
            entry.catalogueProgress = nil
            if case .deviceGone = error {
                // It dropped off the bus while opening (switching USB mode, or unplugged). It comes
                // back with a new address and is tried again then: nothing to wait out or log.
                entry.nextAttempt = .now + .milliseconds(500)
                entries[key] = entry
                throw error
            }
            entry.failures += 1
            entry.nextAttempt = .now + .seconds(min(30, 1 << min(entry.failures, 5)))
            switch error {
            case .noMTPInterface: entry.state = .notInFileTransferMode
#if PULLI_APP_STORE
            case .noStorage: entry.state = .notInFileTransferMode
#else
            case .noStorage: entry.state = .locked
#endif
            // One of Pulli's own workers holds the phone: wait for this engine's to let go, stop a
            // leftover, or say which other copy of Pulli has it.
            case .contended(holder: .process(let pid, let name)) where OwnWorkers.isOwnWorker(name):
                switch OwnWorkers.owner(of: pid) {
                case .thisEngine:
                    entry.state = .connecting
                    entry.nextAttempt = .now + .seconds(1)
                case .orphan:
                    OwnWorkers.stopLeftover(pid)
                    entry.state = .connecting
                    entry.nextAttempt = .now + .seconds(1)
                    entry.failures = 0
                case .backgroundHelper:
                    entry.state = .heldBy(appName: "Pulli's background helper")
                case .otherPulli:
                    entry.state = .heldBy(appName: "Another copy of Pulli")
                }
            case .contended(let holder):
                entry.state = .heldBy(appName: CameraClientApps.sanitizedHolderName(holder.name))
            case .deviceGone: break
            // Pulli's own installation is broken: replugging the phone would not help.
            case .unsupported(let detail) where detail.contains("worker"): entry.state = .unknown
            default: entry.state = entry.failures >= 5 ? .needsReplug : .connecting
            }
            if entry.failures == 1 || entry.failures == 5 {
                reportFailure(entry.info?.displayName ?? entry.candidate.usb.productName ?? "the phone", error)
            }
            entries[key] = entry
            if let snapshot = snapshot(for: key) { onChange?(snapshot) }
            throw error
        }
    }

    func handleContentChanged(for key: DeviceKey) {
        guard var entry = entries[key], entry.state == .ready else { return }
        entry.contentRevision &+= 1
        entries[key] = entry
        if let snapshot = snapshot(for: key) {
            onChange?(snapshot)
        }
    }

    func handleOpeningProgress(key: DeviceKey, percent: Int) {
        guard var entry = entries[key], entry.state == .connecting else { return }
        guard entry.catalogueProgress != percent else { return }
        entry.catalogueProgress = percent
        entries[key] = entry
        if let snapshot = snapshot(for: key) {
            onChange?(snapshot)
        }
    }

    private func snapshot(for key: DeviceKey) -> DeviceSnapshot? {
        guard let entry = entries[key] else { return nil }
        let usb = entry.candidate.usb
        let link: LinkSpeed = switch usb.linkGeneration {
        case .usb1: .usb1
        case .usb2: .usb2
        case .usb3: .usb3
        case .unknown: .unknown
        }
        return DeviceSnapshot(
            id: key.description,
            name: entry.info?.displayName ?? usb.productName ?? "Android phone",
            model: entry.info?.model,
            manufacturer: entry.info?.manufacturer ?? usb.vendorName,
            link: link,
            linkBitsPerSecond: usb.linkSpeedBitsPerSecond,
            state: entry.state,
            storages: entry.storages.map { StorageSnapshot(id: $0.id, name: $0.description, capacityBytes: $0.capacityBytes, freeBytes: $0.freeBytes) },
            resumable: entry.info.map { $0.readStrategy != .whole } ?? true,
            cable: CableAdvisor.advice(link: link, throughHub: usb.throughHub, model: entry.info?.model,
                                       measured: { measuredRate(key, $0) }),
            contentRevision: entry.contentRevision,
            catalogueProgress: entry.catalogueProgress
        )
    }
}

/// A shared session handed out by `DeviceHub`. Closing it returns the lease; if any call failed,
/// the hub closes the underlying session so the next user reconnects cleanly.
final class LeasedSession: DeviceSession, @unchecked Sendable {
    let base: any DeviceSession
    private let hub: DeviceHub
    private let key: DeviceKey
    private let lock = NSLock()
    private var failed = false
    private var released = false

    init(_ base: any DeviceSession, hub: DeviceHub, key: DeviceKey) {
        self.base = base
        self.hub = hub
        self.key = key
    }

    var info: DeviceInfo { base.info }
    var epoch: SessionEpoch { base.epoch }

    var onContentChanged: (@Sendable () -> Void)? {
        get { base.onContentChanged }
        set { base.onContentChanged = newValue }
    }

    private func noting<T>(_ body: () async throws(DeviceError) -> T) async throws(DeviceError) -> T {
        do {
            return try await body()
        } catch {
            lock.withLock { failed = true }
            throw error
        }
    }

    func storages() async throws(DeviceError) -> [StorageInfo] {
        try await noting { () async throws(DeviceError) in try await base.storages() }
    }

    func list(_ folder: RemotePath, storage: StorageID) -> AsyncThrowingStream<[RemoteEntry], any Error> {
        base.list(folder, storage: storage)
    }

    func stat(_ path: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry? {
        try await noting { () async throws(DeviceError) in try await base.stat(path, storage: storage) }
    }

    func read(_ ref: ObjectRef, offset: UInt64, maxLength: Int) async throws(DeviceError) -> Data {
        try await noting { () async throws(DeviceError) in try await base.read(ref, offset: offset, maxLength: maxLength) }
    }

    func readWhole(_ ref: ObjectRef) -> AsyncThrowingStream<Data, any Error> {
        base.readWhole(ref)
    }

    func delete(_ ref: ObjectRef) async throws(DeviceError) {
        try await noting { () async throws(DeviceError) in try await base.delete(ref) }
    }

    func rename(_ ref: ObjectRef, to name: String) async throws(DeviceError) {
        try await noting { () async throws(DeviceError) in try await base.rename(ref, to: name) }
    }

    func makeFolder(_ name: String, in parent: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry {
        try await noting { () async throws(DeviceError) in try await base.makeFolder(name, in: parent, storage: storage) }
    }

    func upload(_ file: URL, as name: String, into parent: RemotePath, storage: StorageID,
                progress: @escaping @Sendable (UInt64) -> Void) async throws(DeviceError) -> RemoteEntry {
        try await noting { () async throws(DeviceError) in try await base.upload(file, as: name, into: parent, storage: storage, progress: progress) }
    }

    /// A missing or refused thumbnail is not a session failure: it does not mark the lease failed.
    func thumbnail(_ ref: ObjectRef) async throws(DeviceError) -> Data? {
        try await base.thumbnail(ref)
    }

    func close() async {
        let (first, failed) = lock.withLock { () -> (Bool, Bool) in
            defer { released = true }
            return (!released, self.failed)
        }
        guard first else { return }
        await hub.release(key, session: base, failed: failed)
    }
}
