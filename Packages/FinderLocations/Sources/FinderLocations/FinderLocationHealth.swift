public import Foundation

/// Health check verifying that a File Provider location is responsive in Finder.
public enum FinderLocationHealth: Sendable {
    /// Outcome of checking a Finder location's health.
    public enum CheckResult: Sendable, Equatable {
        case healthy
        case domainDisabled
        case failed
    }

    /// Whether an error thrown when accessing a File Provider domain indicates that sync is disabled
    /// (NSFileProviderError -2011, "Sync is not enabled").
    public static func isDomainDisabledError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == "NSFileProviderErrorDomain" && nsError.code == -2011) || nsError.code == -2011
    }

    /// Default directory listing skipping hidden files.
    public static let defaultList: @Sendable (URL) throws -> [URL] = { url in
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    }

    /// Thread-safe single-resume continuation wrapper to prevent duplicate resumes.
    private final class SingleResume<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
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
        await checkStatus(root: root, timeout: timeout, preferredSubfolder: preferredSubfolder, list: list) == .healthy
    }

    /// Checks the health of a Finder location root, distinguishing a disabled domain from other failures.
    public static func checkStatus(
        root: URL,
        timeout: Duration = .seconds(8),
        preferredSubfolder: String? = nil,
        list: (@Sendable (URL) throws -> [URL])? = nil
    ) async -> CheckResult {
        let listFn = list ?? defaultList
        return await withCheckedContinuation { continuation in
            let single = SingleResume<CheckResult>(continuation)
            let timerBox = TaskBox()

            let work = Task.detached {
                let status: CheckResult
                do {
                    let items = try listFn(root)
                    if items.isEmpty {
                        status = .healthy
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
                        status = .healthy
                    }
                } catch {
                    status = isDomainDisabledError(error) ? .domainDisabled : .failed
                }
                timerBox.cancel()
                single.resume(returning: status)
            }

            let timer = Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                single.resume(returning: .failed)
            }
            timerBox.set(timer)
        }
    }
}
