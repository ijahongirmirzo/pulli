import Foundation
import TransferCore

/// An in-memory destination volume that models what survives a power loss, like APFS:
/// - file contents (and date, job tag) survive only once the file was synced;
/// - a name (from create or rename) survives only once its folder was synced;
/// - `createDirectory` is durable by contract.
///
/// `powerFailAfter` cuts the power after that many operations: every later call fails until
/// `powerCycle()`, which throws away everything that was not durable. Optionally some unsynced
/// appended bytes survive too, as they can on real disks.
final class SimulatedVolume: FileSink, @unchecked Sendable {
    final class Node {
        let isDirectory: Bool
        var data = Data(), durableData = Data()
        var modified: Date?, durableModified: Date?
        var tag: String?, durableTag: String?
        var entries: [String: Node] = [:], durableEntries: [String: Node] = [:]

        init(isDirectory: Bool) { self.isDirectory = isDirectory }
    }

    private let lock = NSRecursiveLock()
    private let root = Node(isDirectory: true)
    private var operationsLeft: Int?
    private(set) var powerFailed = false

    /// Creates `url` (and its parents) as durable folders.
    init(existing url: URL) {
        try! createDirectory(url)
    }

    /// Cuts the power after `count` more operations.
    func powerFail(afterOperations count: Int) {
        lock.withLock { operationsLeft = count }
    }

    /// Reboots: everything not durable is lost. `keepUnsynced` returns how many unsynced appended
    /// bytes of a file happen to survive (0…extra).
    func powerCycle(keepUnsynced: (Int) -> Int = { _ in 0 }) {
        lock.withLock {
            restore(root, keepUnsynced)
            powerFailed = false
            operationsLeft = nil
        }
    }

    private func restore(_ node: Node, _ keepUnsynced: (Int) -> Int) {
        if node.isDirectory {
            node.entries = node.durableEntries
            for child in node.entries.values { restore(child, keepUnsynced) }
        } else {
            var survived = node.durableData
            if node.data.count > survived.count, node.data.prefix(survived.count) == survived {
                let extra = node.data.count - survived.count
                survived = node.data.prefix(survived.count + min(extra, max(0, keepUnsynced(extra))))
            }
            node.data = survived
            node.modified = node.durableModified
            node.tag = node.durableTag
        }
    }

    /// Counts an operation; fails once the power is out.
    func tick() throws(DestinationError) {
        try locked { () throws(DestinationError) in
            if powerFailed { throw .io(code: EIO, context: "power lost") }
            if let left = operationsLeft {
                if left <= 0 {
                    powerFailed = true
                    throw .io(code: EIO, context: "power lost")
                }
                operationsLeft = left - 1
            }
        }
    }

    /// `withLock` that keeps the typed error.
    private func locked<T>(_ body: () throws(DestinationError) -> T) throws(DestinationError) -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Lookup

    private func node(at url: URL) -> Node? {
        var current = root
        for component in url.standardizedFileURL.pathComponents.dropFirst() {
            guard current.isDirectory, let next = current.entries[component] else { return nil }
            current = next
        }
        return current
    }

    private func parent(of url: URL) -> (Node, String)? {
        guard let folder = node(at: url.deletingLastPathComponent()), folder.isDirectory else { return nil }
        return (folder, url.lastPathComponent)
    }

    /// Current contents of a file (after `powerCycle`, what survived).
    func contents(of url: URL) -> Data? {
        lock.withLock {
            guard let node = node(at: url), !node.isDirectory else { return nil }
            return node.data
        }
    }

    /// Relative paths of all files under `url`.
    func files(under url: URL) -> Set<String> {
        lock.withLock {
            guard let start = node(at: url) else { return [] }
            var result: Set<String> = []
            func walk(_ node: Node, _ prefix: String) {
                for (name, child) in node.entries {
                    let path = prefix.isEmpty ? name : prefix + "/" + name
                    if child.isDirectory { walk(child, path) } else { result.insert(path) }
                }
            }
            walk(start, "")
            return result
        }
    }

    // MARK: FileSink

    func openPart(at url: URL) throws(DestinationError) -> any PartFile {
        try tick()
        return try locked { () throws(DestinationError) -> any PartFile in
            guard let (folder, name) = parent(of: url) else { throw .volumeUnavailable(url.path) }
            if let existing = folder.entries[name], !existing.isDirectory {
                return SimulatedPart(node: existing, volume: self)
            }
            let file = Node(isDirectory: false)
            folder.entries[name] = file
            return SimulatedPart(node: file, volume: self)
        }
    }

    func attributes(of url: URL) -> (size: UInt64, modified: Date)? {
        lock.withLock {
            guard !powerFailed, let node = node(at: url), !node.isDirectory else { return nil }
            return (UInt64(node.data.count), node.modified ?? Date(timeIntervalSince1970: 0))
        }
    }

    func jobTag(of url: URL) -> String? {
        lock.withLock { powerFailed ? nil : node(at: url)?.tag }
    }

    func renameExclusive(_ source: URL, to destination: URL) throws(DestinationError) {
        try rename(source, destination, replacing: false)
    }

    func renameReplacing(_ source: URL, to destination: URL) throws(DestinationError) {
        try rename(source, destination, replacing: true)
    }

    private func rename(_ source: URL, _ destination: URL, replacing: Bool) throws(DestinationError) {
        try tick()
        try locked { () throws(DestinationError) in
            guard let (from, oldName) = parent(of: source), let file = from.entries[oldName],
                  let (to, newName) = parent(of: destination) else {
                throw .volumeUnavailable(source.path)
            }
            if !replacing, to.entries[newName] != nil { throw .alreadyExists(destination.path) }
            to.entries[newName] = file
            from.entries[oldName] = nil
        }
    }

    func syncDirectory(_ url: URL, _ request: SyncRequest) throws(DestinationError) {
        try tick()
        try locked { () throws(DestinationError) in
            guard let folder = node(at: url), folder.isDirectory else { throw .volumeUnavailable(url.path) }
            folder.durableEntries = folder.entries
        }
    }

    func createDirectory(_ url: URL) throws(DestinationError) {
        try tick()
        lock.withLock {
            var current = root
            for component in url.standardizedFileURL.pathComponents.dropFirst() {
                if let next = current.entries[component] {
                    current = next
                } else {
                    let folder = Node(isDirectory: true)
                    current.entries[component] = folder
                    current.durableEntries[component] = folder
                    current = folder
                }
            }
        }
    }

    func remove(_ url: URL) {
        lock.withLock {
            guard !powerFailed, let (folder, name) = parent(of: url) else { return }
            folder.entries[name] = nil
        }
    }

    func availableCapacity(at url: URL) -> UInt64? {
        lock.withLock { powerFailed ? nil : 1 << 40 }
    }

    func volumeID(of url: URL) -> UInt64? { nil }

    // MARK: Part file

    final class SimulatedPart: PartFile {
        let node: Node
        let volume: SimulatedVolume

        init(node: Node, volume: SimulatedVolume) {
            self.node = node
            self.volume = volume
        }

        func size() throws(DestinationError) -> UInt64 {
            try volume.tick()
            return volume.lock.withLock { UInt64(node.data.count) }
        }

        func write(_ data: Data, at offset: UInt64) throws(DestinationError) {
            try volume.tick()
            volume.lock.withLock {
                let end = Int(offset) + data.count
                if node.data.count < end { node.data.append(Data(count: end - node.data.count)) }
                node.data.replaceSubrange(Int(offset)..<end, with: data)
            }
        }

        func read(at offset: UInt64, count: Int) throws(DestinationError) -> Data {
            try volume.tick()
            return volume.lock.withLock {
                let start = min(Int(offset), node.data.count)
                return node.data.subdata(in: start..<min(start + count, node.data.count))
            }
        }

        func truncate(to length: UInt64) throws(DestinationError) {
            try volume.tick()
            volume.lock.withLock {
                if node.data.count > Int(length) {
                    node.data = node.data.prefix(Int(length))
                } else {
                    node.data.append(Data(count: Int(length) - node.data.count))
                }
            }
        }

        func sync(_ request: SyncRequest) throws(DestinationError) -> SyncLevel {
            try volume.tick()
            volume.lock.withLock {
                node.durableData = node.data
                node.durableModified = node.modified
                node.durableTag = node.tag
            }
            return .full
        }

        func setModificationDate(_ date: Date) throws(DestinationError) {
            try volume.tick()
            volume.lock.withLock { node.modified = date }
        }

        func setJobTag(_ tag: String) throws(DestinationError) {
            try volume.tick()
            volume.lock.withLock { node.tag = tag }
        }

        func close() {}
    }
}
