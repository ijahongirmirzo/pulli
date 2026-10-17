import Darwin
public import Foundation

/// Resolves Pulli's application support data folder, migrating from legacy Relay when safe.
public enum DataFolder: Sendable {
    /// The user's application support directory for Pulli, computed once per process.
    public static let current: URL = resolve(
        applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    )

    /// Resolves the data folder under a given Application Support location.
    public static func resolve(applicationSupport: URL, fileManager: FileManager = .default) -> URL {
        let pulli = applicationSupport.appendingPathComponent("Pulli", isDirectory: true)
        let relay = applicationSupport.appendingPathComponent("Relay", isDirectory: true)

        // 1. If <support>/Pulli exists, use it.
        if fileManager.fileExists(atPath: pulli.path) {
            return pulli
        }

        // 2. Else if <support>/Relay exists, migrate if not locked by another process.
        if fileManager.fileExists(atPath: relay.path) {
            let lockPath = relay.appendingPathComponent("journal.sqlite.lock").path
            if fileManager.fileExists(atPath: lockPath) {
                var fd = open(lockPath, O_RDWR | O_CLOEXEC)
                if fd < 0 {
                    fd = open(lockPath, O_RDONLY | O_CLOEXEC)
                }
                if fd >= 0 {
                    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                        let err = errno
                        close(fd)
                        if err == EWOULDBLOCK || err == EAGAIN {
                            return relay
                        }
                    } else {
                        flock(fd, LOCK_UN)
                        close(fd)
                    }
                }
            }

            // Drives holds mount points only while a phone is mounted: empty ones (an unmounted
            // phone's folder, then Drives itself) go now. rmdir only: a mounted phone is never
            // touched, its folder simply stays.
            let drives = relay.appendingPathComponent("Drives", isDirectory: true)
            for name in (try? fileManager.contentsOfDirectory(atPath: drives.path)) ?? [] {
                rmdir(drives.appendingPathComponent(name).path)
            }
            rmdir(drives.path)
            if !fileManager.fileExists(atPath: drives.path) {
                // One rename moves everything at once: the journal, its write-ahead log and the
                // session markers can never end up split across two folders.
                do {
                    try fileManager.moveItem(at: relay, to: pulli)
                } catch {
                    return relay
                }
                renameCLIJournal(in: pulli, fileManager: fileManager)
                return pulli
            }

            // A phone is still mounted under Drives: move the rest, leave Drives where it is.
            do {
                try fileManager.createDirectory(at: pulli, withIntermediateDirectories: true)
            } catch {
                return relay
            }

            guard let items = try? fileManager.contentsOfDirectory(at: relay, includingPropertiesForKeys: nil) else {
                return relay
            }

            for item in items {
                let name = item.lastPathComponent
                if name == "Drives" {
                    // Drives may contain active mount points: leave in place, only remove if empty.
                    rmdir(item.path)
                    continue
                }

                let targetName: String
                if name.hasPrefix("relay-cli.sqlite") {
                    targetName = "pulli-cli.sqlite" + name.dropFirst("relay-cli.sqlite".count)
                } else {
                    targetName = name
                }
                let targetURL = pulli.appendingPathComponent(targetName)
                do {
                    try fileManager.moveItem(at: item, to: targetURL)
                } catch {
                    return relay
                }
            }

            // Remove Relay folder only if now empty (e.g. if non-empty Drives remained, rmdir safely fails).
            rmdir(relay.path)
            return pulli
        }

        // 3. Else create and use <support>/Pulli.
        try? fileManager.createDirectory(at: pulli, withIntermediateDirectories: true)
        return pulli
    }

    /// The command-line tool's journal follows the new name.
    private static func renameCLIJournal(in folder: URL, fileManager: FileManager) {
        guard let items = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return }
        for name in items where name.hasPrefix("relay-cli.sqlite") {
            let target = "pulli-cli.sqlite" + name.dropFirst("relay-cli.sqlite".count)
            try? fileManager.moveItem(at: folder.appendingPathComponent(name), to: folder.appendingPathComponent(target))
        }
    }
}
