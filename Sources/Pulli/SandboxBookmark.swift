import Foundation

/// Manages security-scoped bookmarks for folders chosen outside ~/Downloads.
@MainActor
final class SandboxBookmark {
    static let shared = SandboxBookmark()
    private var activeURLs: [String: (url: URL, count: Int)] = [:]
    private let defaults = UserDefaults.standard
    private let keyPrefix = "bookmark:"

    /// Resolves and stores a security-scoped bookmark for a user-selected URL.
    func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        defaults.set(data, forKey: keyPrefix + url.path)
    }

    /// Starts accessing the security-scoped bookmark for `path` if outside ~/Downloads.
    /// Returns true if access was successfully started.
    @discardableResult
    func startAccessing(path: String) -> Bool {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        if path == downloads || path.hasPrefix(downloads + "/") {
            return true
        }
        if let existing = activeURLs[path] {
            activeURLs[path] = (existing.url, existing.count + 1)
            return true
        }
        guard let data = defaults.data(forKey: keyPrefix + path) else { return false }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }

        if isStale {
            saveBookmark(for: url)
        }
        guard url.startAccessingSecurityScopedResource() else { return false }
        activeURLs[path] = (url, 1)
        return true
    }

    /// Stops accessing the security-scoped resource when finished.
    func stopAccessing(path: String) {
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
        if path == downloads || path.hasPrefix(downloads + "/") {
            return
        }
        guard let existing = activeURLs[path] else { return }
        if existing.count > 1 {
            activeURLs[path] = (existing.url, existing.count - 1)
        } else {
            existing.url.stopAccessingSecurityScopedResource()
            activeURLs.removeValue(forKey: path)
        }
    }
}
