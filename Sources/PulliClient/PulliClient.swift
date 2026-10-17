import Foundation
public import PulliProtocol

/// A connection to the helper: XPC in the app, a direct loopback in tests and previews.
public protocol HelperConnection: Sendable {
    func send(_ request: ClientRequest) async throws -> HelperReply
    /// Like `send`, with a different time limit (transports without one ignore it).
    func send(_ request: ClientRequest, timeout: Duration) async throws -> HelperReply
    /// Events after `subscribe`. Finishes when the connection is lost.
    var events: AsyncStream<SequencedEvent> { get }
    func close() async
}

/// What the app knows about phones and copies, kept in step with the helper.
///
/// Apply a `.snapshot` reply with `reset`, then every event with `apply`. A gap in sequence numbers
/// (events lost while disconnected) makes `apply` return false: resubscribe with `cursor` to get the
/// missed events replayed, or a fresh snapshot if the helper restarted.
public struct PulliState: Sendable, Equatable {
    public var devices: [String: DeviceSnapshot] = [:]
    public var batches: [Int64: BatchSnapshot] = [:]
    public var settings = HelperSettings()
    public private(set) var cursor: EventCursor?

    public init() {}

    public mutating func reset(_ snapshot: Snapshot, cursor: EventCursor) {
        devices = Dictionary(uniqueKeysWithValues: snapshot.devices.map { ($0.id, $0) })
        batches = Dictionary(uniqueKeysWithValues: snapshot.batches.map { ($0.id, $0) })
        settings = snapshot.settings
        self.cursor = cursor
    }

    /// Applies one event. Returns false if events were missed and a resubscribe is needed.
    @discardableResult
    public mutating func apply(_ sequenced: SequencedEvent) -> Bool {
        if let sequence = sequenced.sequence, let cursor {
            if sequence <= cursor.sequence { return true }          // already seen (replay overlap)
            if sequence > cursor.sequence + 1 { return false }      // gap
            self.cursor?.sequence = sequence
        }
        switch sequenced.event {
        case .deviceChanged(let device): devices[device.id] = device
        case .deviceRemoved(let id): devices[id] = nil
        case .batchChanged(let batch): batches[batch.id] = batch
        case .batchRemoved(let id): batches[id] = nil
        case .settingsChanged(let new): settings = new
        case .folderPage, .helperWillExit, .storageScan, .upload, .verification: break
        }
        return true
    }

    /// Copies for the menu bar: running first, then paused, then the rest; newest first within each.
    public var batchesForMenu: [BatchSnapshot] {
        func rank(_ batch: BatchSnapshot) -> Int {
            switch batch.phase {
            case .copying, .scanning: 0
            case .paused(.queued): 2
            case .paused: 1
            default: 3
            }
        }
        return batches.values.sorted { (rank($0), -$0.id) < (rank($1), -$1.id) }
    }
}

/// Connects a client to the helper and keeps a `PulliState` current.
public actor PulliClient {
    public private(set) var state = PulliState()
    /// Who answered the handshake.
    public private(set) var helper: HelperHello?
    private let connection: any HelperConnection
    private var pump: Task<Void, Never>?
    private var onChange: (@Sendable (PulliState) -> Void)?
    private var folderPages: [UUID: AsyncStream<FolderPage>.Continuation] = [:]
    /// Progress of phone tools (storage scans, uploads, verification): not part of `PulliState`.
    private var onProgress: (@Sendable (HelperEvent) -> Void)?

    public func setProgressHandler(_ handler: @escaping @Sendable (HelperEvent) -> Void) {
        onProgress = handler
    }

    /// Sends with a longer wait than usual (walking a folder tree, fetching a big file).
    public func send(_ request: ClientRequest, timeout: Duration) async throws -> HelperReply {
        let reply = try await connection.send(request, timeout: timeout)
        if case .error(let error) = reply { throw error }
        return reply
    }

    public struct FolderPage: Sendable {
        public var entries: [FolderEntry]
        public var done: Bool
        public var error: String?
    }

    public init(connection: any HelperConnection) {
        self.connection = connection
    }

    /// Handshake, subscribe, and start following events. `onChange` gets every new state.
    public func start(clientName: String, onChange: @escaping @Sendable (PulliState) -> Void) async throws {
        self.onChange = onChange
        guard case .hello(let hello) = try await connection.send(.hello(ClientHello(clientName: clientName))) else {
            throw PulliError(.versionMismatch, "the helper did not answer the handshake")
        }
        helper = hello
        guard hello.major == PulliProtocolVersion.major else {
            throw PulliError(.versionMismatch, "helper protocol \(hello.major), app \(PulliProtocolVersion.major)")
        }
        try await subscribe()
        let events = connection.events
        pump = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    /// Waits until the helper's event stream ends (the connection was lost or closed).
    public var eventsEnded: @Sendable () async -> Void {
        let pump = self.pump
        return { await pump?.value }
    }

    public func stop() async {
        pump?.cancel()
        await connection.close()
    }

    public func send(_ request: ClientRequest) async throws -> HelperReply {
        let reply = try await connection.send(request)
        if case .error(let error) = reply { throw error }
        return reply
    }

    /// Applies or declines a suggested read chunk size for a phone.
    public func applyChunkSuggestion(deviceID: String, accept: Bool) async throws {
        _ = try await send(.applyChunkSuggestion(deviceID: deviceID, accept: accept))
    }

    /// Lists a folder on the phone; pages arrive on the stream as the helper reads them.
    public func listFolder(deviceID: String, storageID: UInt32, path: String) async throws -> AsyncStream<FolderPage> {
        let browseID = UUID()
        let (stream, continuation) = AsyncStream<FolderPage>.makeStream()
        folderPages[browseID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.endBrowse(browseID) }
        }
        _ = try await send(.listFolder(deviceID: deviceID, storageID: storageID, path: path, browseID: browseID))
        return stream
    }

    private func endBrowse(_ id: UUID) async {
        guard folderPages.removeValue(forKey: id) != nil else { return }
        _ = try? await connection.send(.cancelBrowse(browseID: id))
    }

    private func subscribe() async throws {
        switch try await connection.send(.subscribe(since: state.cursor)) {
        case .snapshot(let snapshot, let cursor):
            state.reset(snapshot, cursor: cursor)
        case .replay(let events):
            for event in events where !state.apply(event) {
                // Should not happen (the helper replays contiguously); start over.
                state = PulliState()
                return try await subscribe()
            }
        case .error(let error):
            throw error
        default:
            throw PulliError(.invalidRequest, "unexpected reply to subscribe")
        }
        onChange?(state)
    }

    private func receive(_ event: SequencedEvent) async {
        if case .folderPage(let browseID, let entries, let done, let error) = event.event {
            folderPages[browseID]?.yield(FolderPage(entries: entries, done: done, error: error))
            if done { folderPages.removeValue(forKey: browseID)?.finish() }
            return
        }
        switch event.event {
        case .storageScan, .upload, .verification:
            onProgress?(event.event)
            return
        default:
            break
        }
        if !state.apply(event) {
            try? await subscribe()
            return
        }
        onChange?(state)
    }
}

extension HelperConnection {
    public func send(_ request: ClientRequest, timeout: Duration) async throws -> HelperReply {
        try await send(request)
    }
}
