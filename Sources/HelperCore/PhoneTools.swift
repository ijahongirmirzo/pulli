import CryptoKit
public import DeviceAPI
public import Foundation
public import PulliProtocol
public import TransferCore

/// Everything besides copying to the Mac: measuring folders, the storage map, fetching a file for
/// Quick Look, finding files already on the Mac, sending files to the phone, and freeing up space
/// (verify, then delete). Each works on a leased session from the hub, so it shares the phone
/// with running copies.
public actor PhoneTools {
    private let hub: DeviceHub
    private let journal: Journal
    private let publish: @Sendable (HelperEvent) -> Void
    private var scans: [UUID: Task<Void, Never>] = [:]
    /// Per batch: jobs the last verification found identical, with what the phone file looked like.
    private var verified: [Int64: [Int64: (path: String, size: UInt64, mtime: Int64)]] = [:]
    /// The Mac size index, reused for two minutes (opening folder after folder in Choose).
    private var indexCache: (folders: [String], built: ContinuousClock.Instant, index: [UInt64: [String]])?

    init(hub: DeviceHub, journal: Journal, publish: @escaping @Sendable (HelperEvent) -> Void) {
        self.hub = hub
        self.journal = journal
        self.publish = publish
    }

    private func session(_ deviceID: String) async throws -> any DeviceSession {
        guard let key = await hub.key(forID: deviceID) else { throw PulliError(.deviceUnavailable, "the phone is not connected") }
        do {
            return try await hub.open(key)
        } catch {
            throw PulliError(.deviceUnavailable, error.description)
        }
    }

    // MARK: Walking folder trees

    /// Visits every file under `root`, breadth first. `visit` gets the folder path and its files.
    private func walk(_ session: any DeviceSession, _ root: RemotePath, storage: StorageID,
                      visit: (RemotePath, [RemoteEntry]) -> Void) async throws -> Bool {
        var queue: [RemotePath] = [root]
        var index = 0
        var exists = true
        while index < queue.count {
            try Task.checkCancellation()
            let folder = queue[index]
            index += 1
            var files: [RemoteEntry] = []
            do {
                for try await page in session.list(folder, storage: storage) {
                    for entry in page {
                        if entry.isFolder { queue.append(folder.appending(entry.name)) } else { files.append(entry) }
                    }
                }
            } catch DeviceError.notFound {
                if folder == root { exists = false }
                continue
            }
            visit(folder, files)
        }
        return exists
    }

    func measure(deviceID: String, storageID: UInt32, paths: [String]) async throws -> [FolderMeasure] {
        let session = try await session(deviceID)
        defer { Task { await session.close() } }
        var results: [FolderMeasure] = []
        for path in paths {
            var files = 0
            var bytes: UInt64 = 0
            let exists = try await walk(session, RemotePath(path), storage: storageID) { _, entries in
                files += entries.count
                bytes += entries.reduce(0) { $0 + $1.size }
            }
            results.append(FolderMeasure(path: path, exists: exists, files: files, bytes: bytes))
        }
        return results
    }

    // MARK: Storage map

    private final class Tally {
        let name: String
        let path: String
        var bytes: UInt64 = 0
        var files = 0
        var images: UInt64 = 0
        var videos: UInt64 = 0
        var audio: UInt64 = 0
        var children: [String: Tally] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func node(depth: Int) -> StorageNode {
            let sorted = children.values.sorted { $0.bytes > $1.bytes }
            let kept = depth > 0 ? sorted.prefix(14).filter { $0.bytes > 0 }.map { $0.node(depth: depth - 1) } : []
            return StorageNode(name: name, path: path, bytes: bytes, files: files, images: images, videos: videos, audio: audio, children: Array(kept))
        }
    }

    func startScan(deviceID: String, storageID: UInt32, scanID: UUID) {
        scans[scanID] = Task { [weak self] in
            await self?.scan(deviceID: deviceID, storageID: storageID, scanID: scanID)
        }
    }

    func cancelScan(_ scanID: UUID) {
        scans.removeValue(forKey: scanID)?.cancel()
    }

    private func scan(deviceID: String, storageID: UInt32, scanID: UUID) async {
        let root = Tally(name: "Internal storage", path: "/")
        var folders = 0
        var lastReport = ContinuousClock.now
        let report = { [publish] (done: Bool, error: String?) in
            publish(.storageScan(StorageScan(scanID: scanID, root: root.node(depth: 4), foldersScanned: folders, done: done, error: error)))
        }
        do {
            let session = try await session(deviceID)
            defer { Task { await session.close() } }
            _ = try await walk(session, .root, storage: storageID) { folder, files in
                folders += 1
                // Add each file to every folder on its way from the top.
                var chain: [Tally] = [root]
                var node = root
                var path = RemotePath.root
                for component in folder.components {
                    path = path.appending(component)
                    let next = node.children[component] ?? Tally(name: component, path: path.description)
                    node.children[component] = next
                    node = next
                    chain.append(node)
                }
                for file in files {
                    let kind = Self.kind(file.name)
                    for tally in chain {
                        tally.bytes += file.size
                        tally.files += 1
                        switch kind {
                        case .image: tally.images += file.size
                        case .video: tally.videos += file.size
                        case .audio: tally.audio += file.size
                        case .other: break
                        }
                    }
                }
                if ContinuousClock.now - lastReport > .milliseconds(500) {
                    lastReport = .now
                    report(false, nil)
                }
            }
            report(true, nil)
        } catch is CancellationError {
            return
        } catch {
            report(true, (error as? PulliError)?.message ?? "\(error)")
        }
        scans[scanID] = nil
    }

    enum Kind { case image, video, audio, other }

    static func kind(_ name: String) -> Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "bmp", "tif", "tiff": .image
        case "mp4", "mov", "m4v", "3gp", "mkv", "avi", "webm": .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "amr": .audio
        default: .other
        }
    }

    // MARK: Quick Look

    func fetch(deviceID: String, storageID: UInt32, path: String, to destination: String) async throws {
        let session = try await session(deviceID)
        defer { Task { await session.close() } }
        guard let entry = try await session.stat(RemotePath(path), storage: storageID), !entry.isFolder else {
            throw PulliError(.notFound, "\(path) is not on the phone")
        }
        let url = URL(fileURLWithPath: destination)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: partial) else { throw PulliError(.internalError, "cannot write \(destination)") }
        do {
            var offset: UInt64 = 0
            while offset < entry.size {
                try Task.checkCancellation()
                let data = try await session.read(entry.ref, offset: offset, maxLength: 8 << 20)
                if data.isEmpty { break }
                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: partial)
            throw PulliError(.deviceUnavailable, "\(error)")
        }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }

    // MARK: Duplicates

    /// Phone files whose content is already somewhere in `macFolders`, under any name. Candidates
    /// share the exact size; then the first and last 64 KB are compared (the whole file when it is
    /// smaller), read from the phone without copying the file.
    func duplicates(deviceID: String, storageID: UInt32, paths: [String], macFolders: [String]) async throws -> [DuplicateMatch] {
        let index: [UInt64: [String]]
        if let cached = indexCache, cached.folders == macFolders, ContinuousClock.now - cached.built < .seconds(120) {
            index = cached.index
        } else {
            index = Self.sizeIndex(macFolders)
            indexCache = (macFolders, .now, index)
        }
        guard !index.isEmpty else { return [] }
        let session = try await session(deviceID)
        defer { Task { await session.close() } }
        var matches: [DuplicateMatch] = []
        for path in paths {
            try Task.checkCancellation()
            guard let entry = try await session.stat(RemotePath(path), storage: storageID), !entry.isFolder, entry.size > 0,
                  let candidates = index[entry.size] else { continue }
            let window = UInt64(64 << 10)
            let head = try await read(session, entry, offset: 0, count: Int(min(window, entry.size)))
            let tailOffset = entry.size > window ? entry.size - window : 0
            let tail = entry.size > window * 2 ? try await read(session, entry, offset: tailOffset, count: Int(window)) : Data()
            for candidate in candidates {
                guard let local = try? FileHandle(forReadingFrom: URL(fileURLWithPath: candidate)) else { continue }
                defer { try? local.close() }
                guard (try? local.read(upToCount: head.count)) == head else { continue }
                if !tail.isEmpty {
                    try? local.seek(toOffset: tailOffset)
                    guard (try? local.read(upToCount: tail.count)) == tail else { continue }
                }
                matches.append(DuplicateMatch(path: path, macPath: candidate))
                break
            }
        }
        return matches
    }

    private func read(_ session: any DeviceSession, _ entry: RemoteEntry, offset: UInt64, count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let piece = try await session.read(entry.ref, offset: offset + UInt64(data.count), maxLength: count - data.count)
            if piece.isEmpty { break }
            data += piece
        }
        return data
    }

    /// Mac files by size, under the given folders (hidden files and app bundles skipped).
    static func sizeIndex(_ folders: [String]) -> [UInt64: [String]] {
        var index: [UInt64: [String]] = [:]
        var seen = 0
        for folder in folders {
            let url = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in enumerator {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, let size = values.fileSize, size > 0 else { continue }
                index[UInt64(size), default: []].append(file.path)
                seen += 1
                if seen > 400_000 { return index }
            }
        }
        return index
    }

    // MARK: Mac to phone

    func startUpload(deviceID: String, storageID: UInt32, localPaths: [String], destination: String, uploadID: UUID) {
        Task { [weak self] in
            await self?.upload(deviceID: deviceID, storageID: storageID, localPaths: localPaths, destination: destination, uploadID: uploadID)
        }
    }

    private func upload(deviceID: String, storageID: UInt32, localPaths: [String], destination: String, uploadID: UUID) async {
        // What to send: files, and folders with everything in them (hidden files skipped).
        var plan: [(local: URL, folder: RemotePath)] = []
        var folders: [RemotePath] = []
        let base = RemotePath(destination)
        for path in localPaths {
            let url = URL(fileURLWithPath: path)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                plan.append((url, base))
                continue
            }
            let top = base.appending(url.lastPathComponent)
            folders.append(top)
            // Compare resolved components: the enumerator may report /private/var for /var.
            let rootComponents = url.resolvingSymlinksInPath().pathComponents
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            while let item = enumerator?.nextObject() as? URL {
                let relative = Array(item.resolvingSymlinksInPath().pathComponents.dropFirst(rootComponents.count))
                var folder = top
                for component in relative.dropLast() { folder = folder.appending(component) }
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    folders.append(folder.appending(relative.last ?? ""))
                } else {
                    plan.append((item, folder))
                }
            }
        }
        let sizes = plan.map { (try? $0.local.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0 }
        let total = sizes.reduce(0, +)
        var progress = UploadProgress(uploadID: uploadID, deviceID: deviceID, destination: destination, filesDone: 0, filesTotal: plan.count,
                                      bytesDone: 0, bytesTotal: total, current: nil, done: false, error: nil)
        publish(.upload(progress))
        do {
            let session = try await session(deviceID)
            defer { Task { await session.close() } }
            for folder in folders {
                _ = try await session.makeFolder(folder.name, in: folder.parent, storage: storageID)
            }
            let reporter = UploadReporter(publish: publish)
            for (index, item) in plan.enumerated() {
                progress.current = item.local.lastPathComponent
                publish(.upload(progress))
                let before = progress.bytesDone
                let snapshot = progress
                _ = try await session.upload(item.local, as: item.local.lastPathComponent, into: item.folder, storage: storageID) { sent in
                    var update = snapshot
                    update.bytesDone = before + sent
                    reporter.report(update)
                }
                progress.bytesDone = before + sizes[index]
                progress.filesDone += 1
            }
            progress.current = nil
            progress.done = true
            publish(.upload(progress))
            try? journal.log(.notice, kind: "upload", message: "Copied \(plan.count) files (\(total) bytes) from the Mac to \(destination) on the phone")
        } catch {
            progress.done = true
            progress.error = (error as? PulliError)?.message ?? "\(error)"
            publish(.upload(progress))
            try? journal.log(.warning, kind: "upload", message: "Copying to the phone stopped: \(progress.error ?? "")")
        }
    }

    // MARK: Free up space

    func startVerify(batchID: Int64, verifyID: UUID) async throws {
        let batch = try journal.batch(batchID)
        let jobs = try journal.jobs(batchID: batchID).filter { $0.status == .done }
        Task { [weak self] in await self?.verify(batch: batch, jobs: jobs, verifyID: verifyID) }
    }

    private func verify(batch: BatchRecord, jobs: [JobRecord], verifyID: UUID) async {
        let batchID = batch.id!
        verified[batchID] = [:]
        var progress = VerifyProgress(verifyID: verifyID, batchID: batchID, filesTotal: jobs.count,
                                      bytesTotal: jobs.reduce(0) { $0 + UInt64($1.sourceSize) }, bytesChecked: 0, identical: 0, identicalBytes: 0,
                                      problems: [], recent: [], current: nil, done: false, error: nil)
        var lastReport = ContinuousClock.now
        do {
            guard let key = DeviceKey(parsing: batch.deviceKey) else { throw PulliError(.invalidRequest, "unknown phone") }
            let session = try await session(key.description)
            defer { Task { await session.close() } }
            for job in jobs {
                try Task.checkCancellation()
                let name = (job.sourcePath as NSString).lastPathComponent
                progress.current = name
                publish(.verification(progress))
                let result: VerifyProgress.Item.Result
                var mtime: Int64 = 0
                if let entry = try await session.stat(RemotePath(job.sourcePath), storage: batch.storageID), !entry.isFolder {
                    mtime = entry.modifiedWallClock
                    if !FileManager.default.fileExists(atPath: job.destinationURL.path) {
                        result = .missingOnMac
                    } else if entry.size != UInt64(job.sourceSize) {
                        result = .different
                    } else {
                        let phone = try await phoneDigest(session, entry) { bytes in
                            progress.bytesChecked += bytes
                            if ContinuousClock.now - lastReport > .milliseconds(250) {
                                lastReport = .now
                                publish(.verification(progress))
                            }
                        }
                        result = phone == Self.fileDigest(job.destinationURL) ? .identical : .different
                    }
                } else {
                    result = .missingOnPhone
                }
                let item = VerifyProgress.Item(name: name, sizeBytes: UInt64(job.sourceSize), result: result)
                if result == .identical {
                    progress.identical += 1
                    progress.identicalBytes += UInt64(job.sourceSize)
                    verified[batchID]?[job.id!] = (job.sourcePath, UInt64(job.sourceSize), mtime)
                } else {
                    progress.problems.append(item)
                }
                progress.recent.insert(item, at: 0)
                progress.recent = Array(progress.recent.prefix(6))
            }
            progress.current = nil
            progress.done = true
            publish(.verification(progress))
            try? journal.log(.notice, kind: "verify", batchID: batchID,
                             message: "Checked \(jobs.count) copies against the phone: \(progress.identical) identical, \(progress.problems.count) not")
        } catch {
            verified[batchID] = nil
            progress.done = true
            progress.error = (error as? PulliError)?.message ?? "\(error)"
            publish(.verification(progress))
        }
    }

    private func phoneDigest(_ session: any DeviceSession, _ entry: RemoteEntry, progress: (UInt64) -> Void) async throws -> SHA256.Digest {
        var hasher = SHA256()
        var offset: UInt64 = 0
        while offset < entry.size {
            try Task.checkCancellation()
            let data = try await session.read(entry.ref, offset: offset, maxLength: 8 << 20)
            if data.isEmpty { break }
            hasher.update(data: data)
            offset += UInt64(data.count)
            progress(UInt64(data.count))
        }
        return hasher.finalize()
    }

    static func fileDigest(_ url: URL) -> SHA256.Digest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try? handle.read(upToCount: 8 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize()
    }

    /// Deletes the files the last verification found identical, if they are unchanged on the
    /// phone since (same size and date). Nothing else is ever deleted.
    func deleteVerified(batchID: Int64) async throws -> DeleteSummary {
        guard let files = verified.removeValue(forKey: batchID), !files.isEmpty else {
            throw PulliError(.invalidRequest, "check the copies first")
        }
        let batch = try journal.batch(batchID)
        guard let key = DeviceKey(parsing: batch.deviceKey) else { throw PulliError(.invalidRequest, "unknown phone") }
        let session = try await session(key.description)
        defer { Task { await session.close() } }
        var summary = DeleteSummary(deleted: 0, bytesFreed: 0, kept: [])
        for (_, file) in files.sorted(by: { $0.key < $1.key }) {
            do {
                guard let entry = try await session.stat(RemotePath(file.path), storage: batch.storageID),
                      !entry.isFolder, entry.size == file.size, entry.modifiedWallClock == file.mtime else {
                    summary.kept.append(file.path)
                    continue
                }
                try await session.delete(entry.ref)
                summary.deleted += 1
                summary.bytesFreed += file.size
            } catch {
                summary.kept.append(file.path)
            }
        }
        try? journal.log(.notice, kind: "free_up", batchID: batchID,
                         message: "Deleted \(summary.deleted) verified originals from the phone (\(summary.bytesFreed) bytes); kept \(summary.kept.count)")
        return summary
    }
}

/// Throttles upload progress events (libmtp reports every few kilobytes).
private final class UploadReporter: @unchecked Sendable {
    private let publish: @Sendable (HelperEvent) -> Void
    private let lock = NSLock()
    private var last = ContinuousClock.now - .seconds(1)

    init(publish: @escaping @Sendable (HelperEvent) -> Void) {
        self.publish = publish
    }

    func report(_ progress: UploadProgress) {
        let due = lock.withLock { () -> Bool in
            guard ContinuousClock.now - last > .milliseconds(200) else { return false }
            last = .now
            return true
        }
        if due { publish(.upload(progress)) }
    }
}
