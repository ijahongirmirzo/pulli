public import DeviceAPI
public import Foundation
import Synchronization

/// Opens phones through a separate `pulli-mtp-worker` process per session (docs/DECISIONS.md, D-001).
///
/// A read that hangs inside libmtp cannot be interrupted in-process. Here, when a call makes no
/// progress for `stallTimeout`, the worker is killed: the helper, its clients and the journal carry
/// on, and the next open starts a fresh worker, which recovers the phone (D-016).
public final class WorkerConnector: DeviceConnector {
    public let executable: URL
    public let extraArguments: [String]
    public let stallTimeout: Duration
    public let openTimeout: Duration
    /// Pause after killing a worker before starting another, so the phone can settle.
    public let quietAfterKill: Duration

    private let previous = Mutex<[DeviceKey: WorkerProcess]>([:])
    private let kills = KillCounter()

    public init(executable: URL, extraArguments: [String] = [], stallTimeout: Duration = .seconds(30),
                openTimeout: Duration = .seconds(120), quietAfterKill: Duration = .seconds(3)) {
        self.executable = executable
        self.extraArguments = extraArguments
        self.stallTimeout = stallTimeout
        self.openTimeout = openTimeout
        self.quietAfterKill = quietAfterKill
    }

    /// Workers killed because they stopped responding (for logs and tests).
    public var stalledWorkersKilled: Int { kills.value }

    /// `name` next to the running executable, found from the process's real path. (argv[0] is
    /// not enough: launchd starts the helper with a path relative to the app bundle, from `/`.)
    public static func besideCurrentExecutable(_ name: String) -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        let path = _NSGetExecutablePath(&buffer, &size) == 0 ? String(cString: buffer) : CommandLine.arguments[0]
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent(name)
    }

    public func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw .unsupported("the phone worker is missing at \(executable.path); reinstall Pulli")
        }
        // A worker killed inside a USB call can take a moment to exit and release the phone.
        if let old = previous.withLock({ $0[key] }) {
            await old.waitForExit(timeout: .seconds(10))
            if old.wasKilledForStall { try? await Task.sleep(for: quietAfterKill) }
        }

        let process: WorkerProcess
        do {
            process = try WorkerProcess(executable: executable, arguments: extraArguments + ["--key", key.description],
                                        stallTimeout: stallTimeout) { [kills] in kills.increment() }
        } catch {
            throw .transient("could not start the phone worker: \(error)")
        }
        previous.withLock { $0[key] = process }

        do throws(DeviceError) {
            let reply = try await process.single(.open, timeout: openTimeout)
            guard case .opened(let info) = reply.header else { throw DeviceError.transient("unexpected reply to open") }
            return WorkerSession(process: process, info: info)
        } catch {
            process.kill(forStall: false)
            throw error
        }
    }
}

private final class KillCounter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

/// A `DeviceSession` whose calls run in a worker process.
final class WorkerSession: DeviceSession, @unchecked Sendable {
    let info: DeviceInfo
    let epoch: SessionEpoch
    private let process: WorkerProcess

    private static let epochs = Mutex<UInt64>(1 << 32)

    init(process: WorkerProcess, info: DeviceInfo) {
        self.process = process
        self.info = info
        epoch = SessionEpoch(rawValue: Self.epochs.withLock { $0 += 1; return $0 })
    }

    func storages() async throws(DeviceError) -> [StorageInfo] {
        guard case .storages(let storages) = try await process.single(.storages).header else { throw .transient("unexpected reply") }
        return storages
    }

    func list(_ folder: RemotePath, storage: StorageID) -> AsyncThrowingStream<[RemoteEntry], any Error> {
        let (frames, requestID) = process.stream(.list(folder: folder, storage: storage))
        let epoch = epoch
        let process = process
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames {
                        if case .page(let entries) = frame.header {
                            continuation.yield(entries.map { $0.remoteEntry(epoch: epoch) })
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { process.cancel(requestID) }
            }
        }
    }

    func stat(_ path: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry? {
        guard case .entry(let entry) = try await process.single(.stat(path: path, storage: storage)).header else {
            throw .transient("unexpected reply")
        }
        return entry?.remoteEntry(epoch: epoch)
    }

    func read(_ ref: ObjectRef, offset: UInt64, maxLength: Int) async throws(DeviceError) -> Data {
        guard ref.epoch == epoch else { throw .staleHandle }
        let frame = try await process.single(.read(handle: ref.handle, storage: ref.storage, offset: offset, maxLength: maxLength))
        guard case .data = frame.header else { throw .transient("unexpected reply") }
        return frame.payload
    }

    func delete(_ ref: ObjectRef) async throws(DeviceError) {
        guard ref.epoch == epoch else { throw .staleHandle }
        guard case .ok = try await process.single(.delete(handle: ref.handle, storage: ref.storage)).header else {
            throw .transient("unexpected reply")
        }
    }

    func rename(_ ref: ObjectRef, to name: String) async throws(DeviceError) {
        guard ref.epoch == epoch else { throw .staleHandle }
        guard case .ok = try await process.single(.rename(handle: ref.handle, storage: ref.storage, name: name)).header else {
            throw .transient("unexpected reply")
        }
    }

    func makeFolder(_ name: String, in parent: RemotePath, storage: StorageID) async throws(DeviceError) -> RemoteEntry {
        guard case .entry(let entry?) = try await process.single(.makeFolder(name: name, parent: parent, storage: storage)).header else {
            throw .transient("unexpected reply")
        }
        return entry.remoteEntry(epoch: epoch)
    }

    func upload(_ file: URL, as name: String, into parent: RemotePath, storage: StorageID,
                progress: @escaping @Sendable (UInt64) -> Void) async throws(DeviceError) -> RemoteEntry {
        let (frames, _) = process.stream(.upload(localPath: file.path, name: name, parent: parent, storage: storage))
        var result: RemoteEntry?
        do {
            for try await frame in frames {
                switch frame.header {
                case .progress(let sent): progress(sent)
                case .entry(let entry?): result = entry.remoteEntry(epoch: epoch)
                default: break
                }
            }
        } catch let error as DeviceError {
            throw error
        } catch {
            throw .transient("\(error)")
        }
        guard let result else { throw .transient("the phone did not confirm the upload") }
        return result
    }

    func thumbnail(_ ref: ObjectRef) async throws(DeviceError) -> Data? {
        guard ref.epoch == epoch else { throw .staleHandle }
        let frame = try await process.single(.thumbnail(handle: ref.handle, storage: ref.storage))
        guard case .data = frame.header else { throw .transient("unexpected reply") }
        return frame.payload.isEmpty ? nil : frame.payload
    }

    func readWhole(_ ref: ObjectRef) -> AsyncThrowingStream<Data, any Error> {
        guard ref.epoch == epoch else {
            return AsyncThrowingStream { $0.finish(throwing: DeviceError.staleHandle) }
        }
        let (frames, requestID) = process.stream(.readWhole(handle: ref.handle, storage: ref.storage))
        let process = process
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames where frame.header.isData {
                        continuation.yield(frame.payload)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { process.cancel(requestID) }
            }
        }
    }

    func close() async {
        _ = try? await process.single(.close, timeout: .seconds(10))
        await process.waitForExit(timeout: .seconds(5))
        process.kill(forStall: false)
    }
}

extension WorkerResponse {
    var isData: Bool {
        if case .data = self { return true }
        return false
    }
}

/// One running worker: its pipes, the requests waiting for replies, and the stall watchdog.
final class WorkerProcess: @unchecked Sendable {
    private let process = Process()
    private let channel: FrameChannel
    private let stallTimeout: Duration
    private let onStallKill: @Sendable () -> Void

    private struct Pending {
        var continuation: AsyncThrowingStream<WorkerFrame<WorkerResponse>, any Error>.Continuation
        var timeout: Duration
        var lastActivity: ContinuousClock.Instant
        var multiFrame: Bool
    }

    private struct State {
        var pending: [UInt64: Pending] = [:]
        var nextID: UInt64 = 1
        var exited = false
        var killedForStall = false
        var exitWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())
    private var watchdog: Task<Void, Never>?

    init(executable: URL, arguments: [String], stallTimeout: Duration, onStallKill: @escaping @Sendable () -> Void) throws {
        let toWorker = Pipe()
        let fromWorker = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = toWorker
        process.standardOutput = fromWorker
        process.standardError = FileHandle.standardError
        channel = FrameChannel(input: fromWorker.fileHandleForReading, output: toWorker.fileHandleForWriting)
        self.stallTimeout = stallTimeout
        self.onStallKill = onStallKill
        process.terminationHandler = { [weak self] _ in self?.didExit() }
        try process.run()

        let reader = Thread { [weak self] in self?.readLoop() }
        reader.name = "pulli.worker-reader"
        reader.start()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.checkForStall()
            }
        }
    }

    deinit {
        watchdog?.cancel()
    }

    var wasKilledForStall: Bool { state.withLock { $0.killedForStall } }

    /// Sends a request and waits for its single reply.
    func single(_ request: WorkerRequest, timeout: Duration? = nil) async throws(DeviceError) -> WorkerFrame<WorkerResponse> {
        let (frames, _) = stream(request, timeout: timeout, multiFrame: false)
        do {
            for try await frame in frames { return frame }
            throw DeviceError.transient("the phone worker ended without replying")
        } catch let error as DeviceError {
            throw error
        } catch {
            throw .transient("\(error)")
        }
    }

    /// Sends a request whose reply may span several frames (ending with `.end`).
    func stream(_ request: WorkerRequest, timeout: Duration? = nil, multiFrame: Bool = true)
        -> (AsyncThrowingStream<WorkerFrame<WorkerResponse>, any Error>, UInt64) {
        let (stream, continuation) = AsyncThrowingStream<WorkerFrame<WorkerResponse>, any Error>.makeStream()
        let id: UInt64? = state.withLock { state in
            guard !state.exited else { return nil }
            let id = state.nextID
            state.nextID += 1
            state.pending[id] = Pending(continuation: continuation, timeout: timeout ?? stallTimeout, lastActivity: .now, multiFrame: multiFrame)
            return id
        }
        guard let id else {
            continuation.finish(throwing: DeviceError.transient("the phone worker has stopped"))
            return (stream, 0)
        }
        do {
            try channel.write(WorkerFrame(id: id, header: request))
        } catch {
            fail(id, DeviceError.transient("could not reach the phone worker"))
        }
        return (stream, id)
    }

    func cancel(_ requestID: UInt64) {
        guard requestID != 0 else { return }
        state.withLock { _ = $0.pending.removeValue(forKey: requestID) }
        try? channel.write(WorkerFrame(id: 0, header: WorkerRequest.cancel(requestID: requestID)))
    }

    func kill(forStall: Bool) {
        let running = state.withLock { state -> Bool in
            if forStall { state.killedForStall = true }
            return !state.exited
        }
        if running, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }

    func waitForExit(timeout: Duration) async {
        let exited = state.withLock { $0.exited }
        if exited { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await withCheckedContinuation { continuation in
                    guard let self else { return continuation.resume() }
                    let resumeNow = self.state.withLock { state -> Bool in
                        if state.exited { return true }
                        state.exitWaiters.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: Internals

    private func readLoop() {
        while true {
            do {
                let frame = try channel.read(WorkerResponse.self)
                deliver(frame)
            } catch {
                return   // closed: didExit fails what is left
            }
        }
    }

    private func deliver(_ frame: WorkerFrame<WorkerResponse>) {
        let (continuation, finished): (AsyncThrowingStream<WorkerFrame<WorkerResponse>, any Error>.Continuation?, Bool) = state.withLock { state in
            guard var pending = state.pending[frame.id] else { return (nil, false) }
            pending.lastActivity = .now
            let done: Bool = switch frame.header {
            case .end, .failure: true
            default: !pending.multiFrame
            }
            if done { state.pending[frame.id] = nil } else { state.pending[frame.id] = pending }
            return (pending.continuation, done)
        }
        guard let continuation else { return }
        switch frame.header {
        case .failure(let error):
            continuation.finish(throwing: error)
        case .end:
            continuation.finish()
        default:
            continuation.yield(frame)
            if finished { continuation.finish() }
        }
    }

    private func checkForStall() {
        let stalled = state.withLock { state in
            state.pending.values.contains { ContinuousClock.now - $0.lastActivity > $0.timeout }
        }
        guard stalled else { return }
        onStallKill()
        kill(forStall: true)
    }

    private func fail(_ id: UInt64, _ error: DeviceError) {
        state.withLock { $0.pending.removeValue(forKey: id) }?.continuation.finish(throwing: error)
    }

    private func didExit() {
        watchdog?.cancel()
        let (pending, waiters, stalled) = state.withLock { state in
            state.exited = true
            let pending = state.pending
            state.pending.removeAll()
            let waiters = state.exitWaiters
            state.exitWaiters.removeAll()
            return (pending, waiters, state.killedForStall)
        }
        let error: DeviceError = stalled ? .transient("the phone stopped responding; reconnecting") : .transient("the phone worker stopped")
        for entry in pending.values { entry.continuation.finish(throwing: error) }
        for waiter in waiters { waiter.resume() }
    }
}
