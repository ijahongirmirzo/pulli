public import DeviceAPI
public import Foundation
public import PulliProtocol
public import TransferCore

/// The helper's core, independent of the transport: XPC in the real helper, a direct loopback in
/// tests and UI previews. Handles requests, and fans events out to subscribed clients.
public actor HelperEngine {
    public nonisolated let instanceID = UUID()
    public nonisolated let version: String

    private let journal: Journal
    private let sink: any FileSink
    private let hub: DeviceHub
    private var service: TransferService?
    private var settings: HelperSettings
    private let timeZone: TimeZone
    private let pollInterval: Duration

    private struct Client {
        var continuation: AsyncStream<SequencedEvent>.Continuation
        var subscribed = false
        var watchingDevices = false
    }

    private var clients: [UUID: Client] = [:]
    private var sequence: UInt64 = 0
    private var ring: [SequencedEvent] = []
    private static let ringCapacity = 2_048
    private var browses: [UUID: Task<Void, Never>] = [:]
    private let tools: PhoneTools
    /// Set by the helper process: quit after `prepareForUpdate` (the in-app engine leaves it nil).
    private var onUpdateRequested: (@Sendable () -> Void)?

    public func setUpdateHandler(_ handler: @escaping @Sendable () -> Void) {
        onUpdateRequested = handler
    }
    private let forwarder = EventForwarder()
    /// Phone drives being served, by device ID.
    private var drives: [String: (drive: PhoneDrive, server: HTTPServer, url: String)] = [:]

    public init(journal: Journal, sink: any FileSink, connector: any DeviceConnector, watcher: any DeviceWatcher,
                version: String, timeZone: TimeZone = .current, pollInterval: Duration = .seconds(1)) {
        self.journal = journal
        self.sink = sink
        self.version = version
        self.timeZone = timeZone
        self.pollInterval = pollInterval
        self.hub = DeviceHub(connector: connector, watcher: watcher, pollInterval: pollInterval, measuredRate: { [journal] key, link in
            (try? journal.setting(MeasuredRates.key(key, link))).flatMap(Double.init)
        }, reportFailure: { [journal] name, error in
            try? journal.log(.warning, kind: "device", message: "Could not open \(name): \(error.description)")
        })
        tools = PhoneTools(hub: hub, journal: journal) { [forwarder] event in forwarder.forward(event) }
        let loaded = (try? journal.setting("settings")).flatMap { try? JSONDecoder().decode(HelperSettings.self, from: Data($0.utf8)) } ?? HelperSettings()
        settings = loaded
        forwarder.engine = self
        driveChangesAllowed.value = loaded.allowDriveChanges ?? false
    }

    /// Read by the drives on every change request (so the setting applies at once).
    private nonisolated let driveChangesAllowed = AtomicFlag()

    /// Loads the journal, restarts unfinished copies and starts watching for phones.
    public func start() async throws {
        let service = TransferService(journal: journal, sink: sink, hub: hub, settings: settings, timeZone: timeZone,
                                      pollInterval: pollInterval) { [weak self] event in
            Task { await self?.publish(event) }
        }
        self.service = service
        await hub.observe(onChange: { [weak self] snapshot in
            Task {
                guard let self else { return }
                var snap = snapshot
                snap.chunkSuggestion = await self.service?.chunkSuggestion(for: snap.id)
                await self.publish(.deviceChanged(snap))
            }
        }, onRemove: { [weak self] id in
            Task {
                await self?.publish(.deviceRemoved(id: id))
                await self?.stopDrive(id)
            }
        })
        try await service.start()
        await hub.start()
    }

    public func stop(reason: String = "stopping") async {
        publish(.helperWillExit(reason: reason))
        for task in browses.values { task.cancel() }
        await service?.stop()
        await hub.stop()
        for client in clients.values { client.continuation.finish() }
        clients.removeAll()
    }

    // MARK: Clients

    /// A new connection. Events flow on the returned stream once the client subscribes.
    public func connect() -> (id: UUID, events: AsyncStream<SequencedEvent>) {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SequencedEvent>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
        clients[id] = Client(continuation: continuation)
        return (id, stream)
    }

    public func disconnect(_ id: UUID) async {
        clients.removeValue(forKey: id)?.continuation.finish()
        await updateWatching()
    }

    public func handle(_ request: ClientRequest, from client: UUID) async -> HelperReply {
        do {
            return try await perform(request, client: client)
        } catch let error as PulliError {
            return .error(error)
        } catch {
            return .error(PulliError(.internalError, "\(error)"))
        }
    }

    private func perform(_ request: ClientRequest, client: UUID) async throws -> HelperReply {
        switch request {
        case .hello(let hello):
            guard hello.major == PulliProtocolVersion.major else {
                throw PulliError(.versionMismatch, "helper speaks protocol \(PulliProtocolVersion.major), app \(hello.major)")
            }
            return .hello(HelperHello(helperVersion: version, instanceID: instanceID))

        case .subscribe(let since):
            clients[client]?.subscribed = true
            if let since, since.instanceID == instanceID, let first = ring.first?.sequence, since.sequence + 1 >= first {
                return .replay(ring.filter { ($0.sequence ?? 0) > since.sequence })
            }
            return .snapshot(await snapshot(), cursor: EventCursor(instanceID: instanceID, sequence: sequence))

        case .setWatchingDevices(let watching):
            clients[client]?.watchingDevices = watching
            await updateWatching()
            return .ok

        case .listFolder(let deviceID, let storageID, let path, let browseID):
            guard let key = await hub.key(forID: deviceID) else { throw PulliError(.deviceUnavailable, "the phone is not connected") }
            browses[browseID] = Task { [weak self] in await self?.browse(key: key, storage: storageID, path: path, browseID: browseID, client: client) }
            return .ok

        case .cancelBrowse(let browseID):
            browses.removeValue(forKey: browseID)?.cancel()
            return .ok

        case .createBatch(let request):
            guard let key = await hub.key(forID: request.deviceID) ?? DeviceKey(parsing: request.deviceID) else {
                throw PulliError(.deviceUnavailable, "the phone is not connected")
            }
            guard !request.paths.isEmpty else { throw PulliError(.invalidRequest, "nothing selected") }
            do {
                let id = try await requireService().create(request, key: key)
                return .batchCreated(batchID: id)
            } catch let error as DeviceError {
                throw PulliError(.deviceUnavailable, error.description)
            }

        case .control(let batchID, let command):
            try await requireService().control(batchID, command)
            return .ok

        case .needsAttention(let batchID):
            return .needsAttention(try await requireService().attention(batchID))

        case .log(let afterID, let limit):
            let events = try journal.events(afterID: afterID, limit: min(max(limit, 1), 1_000))
            return .log(events.map { LogEntry(id: $0.id!, date: Date(timeIntervalSince1970: TimeInterval($0.ts) / 1000),
                                              level: $0.level.rawValue, kind: $0.kind, message: $0.message, batchID: $0.batchId) })

        case .setSettings(let new):
            settings = new
            driveChangesAllowed.value = new.allowDriveChanges ?? false
            try journal.setSetting("settings", String(decoding: try JSONEncoder().encode(new), as: UTF8.self))
            await service?.update(settings: new)
            publish(.settingsChanged(new))
            return .ok

        case .thumbnail(let deviceID, let storageID, let path):
            guard let key = await hub.key(forID: deviceID) else { throw PulliError(.deviceUnavailable, "the phone is not connected") }
            let session: any DeviceSession
            do {
                session = try await hub.open(key)
            } catch {
                throw PulliError(.deviceUnavailable, error.description)
            }
            defer { Task { await session.close() } }
            guard let entry = try? await session.stat(RemotePath(path), storage: storageID), !entry.isFolder else { return .thumbnail(nil) }
            return .thumbnail(try? await session.thumbnail(entry.ref))

        case .measure(let deviceID, let storageID, let paths):
            return .measured(try await tools.measure(deviceID: deviceID, storageID: storageID, paths: paths))

        case .scanStorage(let deviceID, let storageID, let scanID):
            await tools.startScan(deviceID: deviceID, storageID: storageID, scanID: scanID)
            return .ok

        case .cancelScan(let scanID):
            await tools.cancelScan(scanID)
            return .ok

        case .fetchFile(let deviceID, let storageID, let path, let destination):
            try await tools.fetch(deviceID: deviceID, storageID: storageID, path: path, to: destination)
            return .ok

        case .findDuplicates(let deviceID, let storageID, let paths, let macFolders):
            return .duplicates(try await tools.duplicates(deviceID: deviceID, storageID: storageID, paths: paths, macFolders: macFolders))

        case .upload(let deviceID, let storageID, let localPaths, let destination, let uploadID):
            await tools.startUpload(deviceID: deviceID, storageID: storageID, localPaths: localPaths, destination: destination, uploadID: uploadID)
            return .ok

        case .verify(let batchID, let verifyID):
            try await tools.startVerify(batchID: batchID, verifyID: verifyID)
            return .ok

        case .deleteVerified(let batchID):
            return .deleted(try await tools.deleteVerified(batchID: batchID))

        case .startDrive(let deviceID):
            if let running = drives[deviceID] { return .drive(url: running.url) }
            guard let snapshot = await hub.snapshot(forID: deviceID), let storage = snapshot.storages.first else {
                throw PulliError(.deviceUnavailable, "the phone is not ready")
            }
            let volume = snapshot.name.replacingOccurrences(of: "/", with: "-")
            let drive = PhoneDrive(deviceID: deviceID, storageID: storage.id, volume: volume, hub: hub) { [weak self] in
                self?.driveChangesAllowed.value ?? false
            }
            await drive.refreshSpace()
            let server = try HTTPServer { request in await drive.handle(request) }
            let port = try await server.start()
            let name = volume.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? volume
            let url = "http://127.0.0.1:\(port)/\(drive.token)/\(name)/"
            drives[deviceID] = (drive, server, url)
            try? journal.log(.notice, kind: "drive", message: "Serving \(snapshot.name) as a Finder drive on this Mac")
            return .drive(url: url)

        case .stopDrive(let deviceID):
            drives.removeValue(forKey: deviceID)?.server.stop()
            return .ok

        case .applyChunkSuggestion(let deviceID, let accept):
            try await applyChunkSuggestion(deviceID: deviceID, accept: accept)
            return .ok

        case .recordLog(let level, let kind, let message):
            let recordLevel = EventRecord.Level(rawValue: level) ?? .notice
            try? journal.log(recordLevel, kind: kind, message: message)
            return .ok

        case .clearHistory:
            try await requireService().clearHistory()
            return .ok

        case .prepareForUpdate:
            await stop(reason: "updating")
            // Let the reply go out, then leave: launchd starts the new helper on the next request.
            if let exit = onUpdateRequested {
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    exit()
                }
            }
            return .ok
        }
    }

    private func applyChunkSuggestion(deviceID: String, accept: Bool) async throws {
        guard let service else { throw PulliError(.internalError, "helper not started") }
        guard let suggestion = await service.chunkSuggestion(for: deviceID) else { return }

        if accept {
            let suggestedMiB = suggestion.suggestedMiB
            var newSettings = settings
            var overrides = newSettings.chunkMiBByDevice ?? [:]
            overrides[deviceID] = suggestedMiB
            newSettings.chunkMiBByDevice = overrides
            settings = newSettings
            try journal.setSetting("settings", String(decoding: try JSONEncoder().encode(newSettings), as: UTF8.self))
            await service.update(settings: newSettings)
            await service.clearSuggestion(for: deviceID)
            publish(.settingsChanged(newSettings))
            if let key = await hub.key(forID: deviceID) ?? DeviceKey(parsing: deviceID) {
                await service.restartRunningBatch(for: key)
            }
        } else {
            await service.rememberDecline(for: deviceID, size: suggestion.currentMiB)
        }

        if var snapshot = await hub.snapshot(forID: deviceID) {
            snapshot.chunkSuggestion = nil
            publish(.deviceChanged(snapshot))
        }
    }

    private func stopDrive(_ deviceID: String) {
        drives.removeValue(forKey: deviceID)?.server.stop()
    }

    private func requireService() throws -> TransferService {
        guard let service else { throw PulliError(.internalError, "helper not started") }
        return service
    }

    public func snapshot() async -> Snapshot {
        var devices = await hub.snapshots
        for i in devices.indices {
            devices[i].chunkSuggestion = await service?.chunkSuggestion(for: devices[i].id)
        }
        return Snapshot(devices: devices, batches: await service?.snapshots ?? [], settings: settings)
    }

    private func updateWatching() async {
        await hub.setUIActive(clients.values.contains { $0.watchingDevices })
    }

    // MARK: Events

    func publish(_ event: HelperEvent) {
        let sequenced: SequencedEvent
        switch event {
        case .folderPage, .storageScan, .upload, .verification:
            // Lossy progress: never replayed, so not sequenced.
            sequenced = SequencedEvent(sequence: nil, event: event)
        default:
            sequence += 1
            sequenced = SequencedEvent(sequence: sequence, event: event)
            ring.append(sequenced)
            if ring.count > Self.ringCapacity { ring.removeFirst(ring.count - Self.ringCapacity) }
        }
        for client in clients.values where client.subscribed {
            client.continuation.yield(sequenced)
        }
    }

    private func send(_ event: HelperEvent, to client: UUID) {
        clients[client]?.continuation.yield(SequencedEvent(sequence: nil, event: event))
    }

    private func browse(key: DeviceKey, storage: UInt32, path: String, browseID: UUID, client: UUID) async {
        defer { browses[browseID] = nil }
        let session: any DeviceSession
        do {
            session = try await hub.open(key)
        } catch {
            send(.folderPage(browseID: browseID, entries: [], done: true, error: error.description), to: client)
            return
        }
        do {
            for try await page in session.list(RemotePath(path), storage: storage) {
                if Task.isCancelled { break }
                send(.folderPage(browseID: browseID, entries: page.map {
                    FolderEntry(name: $0.name, isFolder: $0.isFolder, sizeBytes: $0.size, modifiedWallClock: $0.modifiedWallClock)
                }, done: false, error: nil), to: client)
            }
            send(.folderPage(browseID: browseID, entries: [], done: true, error: nil), to: client)
        } catch {
            send(.folderPage(browseID: browseID, entries: [], done: true, error: "\(error)"), to: client)
        }
        await session.close()
    }
}

/// Hands PhoneTools' progress events to the engine (which cannot be captured during its init).
private final class EventForwarder: @unchecked Sendable {
    weak var engine: HelperEngine?

    func forward(_ event: HelperEvent) {
        Task { [engine] in await engine?.publish(event) }
    }
}

final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
