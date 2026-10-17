public import DeviceAPI
public import Foundation

/// Messages between the helper and a per-phone worker process (docs/DECISIONS.md, D-001).
///
/// Each frame on the pipe is `[UInt32 total][UInt32 header length][JSON header][raw payload]`,
/// big-endian lengths. File data travels as the raw payload, never inside the JSON.
public enum WorkerRequest: Codable, Sendable {
    case open
    case storages
    case list(folder: RemotePath, storage: StorageID)
    case stat(path: RemotePath, storage: StorageID)
    case read(handle: UInt32, storage: StorageID, offset: UInt64, maxLength: Int)
    case readWhole(handle: UInt32, storage: StorageID)
    /// The phone's preview of an object; the reply is `.data`, empty when there is none.
    case thumbnail(handle: UInt32, storage: StorageID)
    case delete(handle: UInt32, storage: StorageID)
    case makeFolder(name: String, parent: RemotePath, storage: StorageID)
    case rename(handle: UInt32, storage: StorageID, name: String)
    /// Sends a Mac file (the worker reads it itself); `.progress` replies, then `.entry`.
    case upload(localPath: String, name: String, parent: RemotePath, storage: StorageID)
    /// Stops a running `list` or `readWhole`.
    case cancel(requestID: UInt64)
    case close
}

public enum WorkerResponse: Codable, Sendable {
    case opened(DeviceInfo)
    case storages([StorageInfo])
    /// One page of a listing; more follow until `.end`.
    case page([WorkerEntry])
    case entry(WorkerEntry?)
    /// Bytes in the frame's payload (a read, or one piece of a whole-object read).
    case data
    /// Bytes sent so far by an upload.
    case progress(UInt64)
    /// Done, with nothing to return (`delete`).
    case ok
    /// The end of a streamed reply (`list`, `readWhole`).
    case end
    case closed
    case failure(DeviceError)
}

/// `RemoteEntry` without its session-bound `ObjectRef`: the helper rebinds handles to its own epoch.
public struct WorkerEntry: Codable, Sendable, Hashable {
    public var name: String
    public var isFolder: Bool
    public var size: UInt64
    public var modifiedWallClock: Int64
    public var handle: UInt32
    public var storage: StorageID

    public init(_ entry: RemoteEntry) {
        name = entry.name
        isFolder = entry.isFolder
        size = entry.size
        modifiedWallClock = entry.modifiedWallClock
        handle = entry.ref.handle
        storage = entry.ref.storage
    }

    public func remoteEntry(epoch: SessionEpoch) -> RemoteEntry {
        RemoteEntry(name: name, isFolder: isFolder, size: size, modifiedWallClock: modifiedWallClock,
                    ref: ObjectRef(handle: handle, storage: storage, epoch: epoch))
    }
}

public struct WorkerFrame<Header: Codable & Sendable>: Sendable {
    public var id: UInt64
    public var header: Header
    public var payload: Data

    public init(id: UInt64, header: Header, payload: Data = Data()) {
        self.id = id
        self.header = header
        self.payload = payload
    }
}

private struct Envelope<Header: Codable>: Codable {
    var id: UInt64
    var header: Header
}

public enum FrameError: Error, Sendable {
    case closed
    case malformed(String)
}

/// Reads and writes frames on a pair of file descriptors. Reads block; use a dedicated thread.
public final class FrameChannel: @unchecked Sendable {
    private let input: FileHandle
    private let output: FileHandle
    private let writeLock = NSLock()
    public static let maxFrame = 128 << 20

    public init(input: FileHandle, output: FileHandle) {
        self.input = input
        self.output = output
    }

    public func write<Header: Codable & Sendable>(_ frame: WorkerFrame<Header>) throws {
        let header = try JSONEncoder().encode(Envelope(id: frame.id, header: frame.header))
        var data = Data(capacity: 8 + header.count + frame.payload.count)
        var total = UInt32(4 + header.count + frame.payload.count).bigEndian
        var headerLength = UInt32(header.count).bigEndian
        withUnsafeBytes(of: &total) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &headerLength) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(frame.payload)
        try writeLock.withLock {
            try output.write(contentsOf: data)
        }
    }

    /// The next frame, or `FrameError.closed` at end of input.
    public func read<Header: Codable & Sendable>(_ type: Header.Type) throws -> WorkerFrame<Header> {
        let lengthBytes = try readExactly(4)
        let total = Int(lengthBytes.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard total >= 4, total <= Self.maxFrame else { throw FrameError.malformed("frame of \(total) bytes") }
        let body = try readExactly(total)
        let headerLength = Int(body.prefix(4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard headerLength <= total - 4 else { throw FrameError.malformed("header of \(headerLength) bytes") }
        let headerData = body.subdata(in: 4..<(4 + headerLength))
        let envelope = try JSONDecoder().decode(Envelope<Header>.self, from: headerData)
        return WorkerFrame(id: envelope.id, header: envelope.header, payload: body.subdata(in: (4 + headerLength)..<total))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw FrameError.closed
            }
            data.append(chunk)
        }
        return data
    }
}
