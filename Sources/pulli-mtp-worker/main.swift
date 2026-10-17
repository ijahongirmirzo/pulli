import Darwin
import DeviceAPI
import Foundation
import MockDevice
import MTPKit
import WorkerIPC

// One phone's MTP session, in its own process (docs/DECISIONS.md, D-001). The helper talks to it
// over stdin/stdout frames and kills it if a call stops making progress.
//
//   pulli-mtp-worker --key usb:04e8:SERIAL [--report-only]
//   pulli-mtp-worker --key … --mock <scenario>        (MockScenarios, for tests)

MTPLibrary.bootstrap()

// libmtp prints to stdout in places; frames need a clean stream. Keep the real stdout for frames
// and send anything else written to fd 1 to stderr.
let frameFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)
let channel = FrameChannel(input: .standardInput, output: FileHandle(fileDescriptor: frameFD, closeOnDealloc: true))

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
}

guard let keyText = option("--key"), let key = DeviceKey(parsing: keyText) else {
    FileHandle.standardError.write(Data("pulli-mtp-worker: --key is required\n".utf8))
    exit(2)
}

let connector: any DeviceConnector = if let scenario = option("--mock") {
    MockConnector(MockScenarios.device(named: scenario))
} else {
    MTPDeviceConnector(policy: arguments.contains("--report-only") ? .reportOnly : .releaseSystemDaemons)
}

/// Serves requests against the one session this worker owns.
actor Server {
    private let key: DeviceKey
    private let connector: any DeviceConnector
    private let channel: FrameChannel
    private var session: (any DeviceSession)?
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var refs: [UInt32: ObjectRef] = [:]

    init(key: DeviceKey, connector: any DeviceConnector, channel: FrameChannel) {
        self.key = key
        self.connector = connector
        self.channel = channel
    }

    func handle(_ frame: WorkerFrame<WorkerRequest>) {
        let id = frame.id
        switch frame.header {
        case .cancel(let requestID):
            tasks.removeValue(forKey: requestID)?.cancel()
        case .list, .readWhole:
            tasks[id] = Task { await self.run(frame) }
        default:
            Task { await self.run(frame) }
        }
    }

    private func run(_ frame: WorkerFrame<WorkerRequest>) async {
        let id = frame.id
        do {
            switch frame.header {
            case .open:
                let opened = try await connector.open(key)
                session = opened
                reply(id, .opened(opened.info))
            case .storages:
                reply(id, .storages(try await requireSession().storages()))
            case .list(let folder, let storage):
                for try await page in try requireSession().list(folder, storage: storage) {
                    if Task.isCancelled { break }
                    remember(page)
                    reply(id, .page(page.map(WorkerEntry.init)))
                }
                reply(id, .end)
            case .stat(let path, let storage):
                let entry = try await requireSession().stat(path, storage: storage)
                if let entry { remember([entry]) }
                reply(id, .entry(entry.map(WorkerEntry.init)))
            case .read(let handle, let storage, let offset, let maxLength):
                let data = try await requireSession().read(try ref(handle, storage), offset: offset, maxLength: maxLength)
                reply(id, .data, payload: data)
            case .thumbnail(let handle, let storage):
                let data = try await requireSession().thumbnail(try ref(handle, storage))
                reply(id, .data, payload: data ?? Data())
            case .delete(let handle, let storage):
                try await requireSession().delete(try ref(handle, storage))
                reply(id, .ok)
            case .rename(let handle, let storage, let name):
                try await requireSession().rename(try ref(handle, storage), to: name)
                reply(id, .ok)
            case .makeFolder(let name, let parent, let storage):
                let entry = try await requireSession().makeFolder(name, in: parent, storage: storage)
                remember([entry])
                reply(id, .entry(WorkerEntry(entry)))
            case .upload(let localPath, let name, let parent, let storage):
                let entry = try await requireSession().upload(URL(fileURLWithPath: localPath), as: name, into: parent, storage: storage) { sent in
                    self.progressReply(id, sent)
                }
                remember([entry])
                reply(id, .entry(WorkerEntry(entry)))
                reply(id, .end)
            case .readWhole(let handle, let storage):
                for try await piece in try requireSession().readWhole(try ref(handle, storage)) {
                    if Task.isCancelled { break }
                    reply(id, .data, payload: piece)
                }
                reply(id, .end)
            case .close:
                await session?.close()
                session = nil
                reply(id, .closed)
                exit(0)
            case .cancel:
                break
            }
        } catch let error as DeviceError {
            reply(id, .failure(error))
        } catch is CancellationError {
            reply(id, .end)
        } catch {
            reply(id, .failure(.transient("\(error)")))
        }
        tasks[id] = nil
    }

    /// The helper closed the pipe (it quit or crashed): end the session cleanly.
    func shutdown() async {
        await session?.close()
        exit(0)
    }

    private func requireSession() throws(DeviceError) -> any DeviceSession {
        guard let session else { throw .deviceGone }
        return session
    }

    private func remember(_ entries: [RemoteEntry]) {
        for entry in entries { refs[entry.ref.handle] = entry.ref }
    }

    private func ref(_ handle: UInt32, _ storage: StorageID) throws(DeviceError) -> ObjectRef {
        guard let ref = refs[handle], ref.storage == storage else { throw .staleHandle }
        return ref
    }

    /// Called on the MTP thread from libmtp's upload callback (the channel's writes are locked).
    nonisolated func progressReply(_ id: UInt64, _ sent: UInt64) {
        try? channel.write(WorkerFrame(id: id, header: WorkerResponse.progress(sent)))
    }

    private func reply(_ id: UInt64, _ response: WorkerResponse, payload: Data = Data()) {
        do {
            try channel.write(WorkerFrame(id: id, header: response, payload: payload))
        } catch {
            exit(0)   // the helper is gone
        }
    }
}

let server = Server(key: key, connector: connector, channel: channel)
let reader = Thread {
    while true {
        do {
            let frame = try channel.read(WorkerRequest.self)
            Task { await server.handle(frame) }
        } catch {
            Task { await server.shutdown() }
            return
        }
    }
}
reader.name = "pulli.worker-requests"
reader.start()

while true {
    try? await Task.sleep(for: .seconds(3600))
}
