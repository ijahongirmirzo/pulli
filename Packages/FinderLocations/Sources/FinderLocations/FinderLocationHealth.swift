public import Foundation

/// Health check verifying that a File Provider location is responsive in Finder.
public enum FinderLocationHealth: Sendable {
    /// Default directory listing skipping hidden files.
    public static let defaultList: @Sendable (URL) throws -> [URL] = { url in
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    /// Thread-safe single-resume continuation wrapper to prevent duplicate resumes.
    private final class SingleResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: Bool) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            let t = task
            task = nil
            lock.unlock()
            t?.cancel()
        }
    }

    /// Whether a URL points to a folder.
    private static func isDirectory(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), let isDir = values.isDirectory {
            return isDir
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue
        }
        return url.hasDirectoryPath
    }

    /// Checks whether the Finder location at `root` is healthy by listing the root folder
    /// and its first subfolder (preferring `preferredSubfolder` if specified), racing against `timeout`.
    public static func check(
        root: URL,
        timeout: Duration = .seconds(8),
        preferredSubfolder: String? = nil,
        list: (@Sendable (URL) throws -> [URL])? = nil
    ) async -> Bool {
        let listFn = list ?? defaultList
        return await withCheckedContinuation { continuation in
            let single = SingleResume(continuation)
            let timerBox = TaskBox()

            let work = Task.detached {
                let healthy: Bool
                do {
                    let items = try listFn(root)
                    if items.isEmpty {
                        healthy = true
                    } else {
                        let subfolders = items.filter { isDirectory($0) }
                        let target: URL?
                        if let preferred = preferredSubfolder {
                            target = subfolders.first(where: {
                                $0.lastPathComponent.caseInsensitiveCompare(preferred) == .orderedSame
                            }) ?? subfolders.first
                        } else {
                            target = subfolders.first
                        }

                        if let target {
                            try Task.checkCancellation()
                            _ = try listFn(target)
                        }
                        healthy = true
                    }
                } catch {
                    healthy = false
                }
                timerBox.cancel()
                single.resume(returning: healthy)
            }

            let timer = Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                single.resume(returning: false)
            }
            timerBox.set(timer)
        }
    }
}
