import FinderLocations
import Foundation

/// Health check for a phone's Finder location: confirms that fileproviderd is serving the domain
/// and folders load without error.
enum FinderLocationHealth: Sendable {
    private static let devSwitchLock = NSLock()
    nonisolated(unsafe) private static var didFakeErrorOnce = false

    /// Reads PULLI_FAKE_FINDER_ERROR for manual testing ("once" fails the first check, "always" every check).
    private static func shouldFakeError() -> Bool {
        devSwitchLock.lock()
        defer { devSwitchLock.unlock() }
        guard let env = ProcessInfo.processInfo.environment["PULLI_FAKE_FINDER_ERROR"] else { return false }
        if env == "always" { return true }
        if env == "once" && !didFakeErrorOnce {
            didFakeErrorOnce = true
            return true
        }
        return false
    }

    /// Checks whether the Finder location at `root` is healthy, preferring the phone's DCIM subfolder.
    /// In the default path (no custom `list`), respects `PULLI_FAKE_FINDER_ERROR`.
    static func check(
        root: URL,
        timeout: Duration = .seconds(8),
        list: (@Sendable (URL) throws -> [URL])? = nil
    ) async -> Bool {
        await checkStatus(root: root, timeout: timeout, list: list) == .healthy
    }

    /// Checks the health of a Finder location, distinguishing a disabled domain from other failures.
    static func checkStatus(
        root: URL,
        timeout: Duration = .seconds(8),
        list: (@Sendable (URL) throws -> [URL])? = nil
    ) async -> FinderLocations.FinderLocationHealth.CheckResult {
        if list == nil, shouldFakeError() { return .failed }
        return await FinderLocations.FinderLocationHealth.checkStatus(
            root: root,
            timeout: timeout,
            preferredSubfolder: "DCIM",
            list: list
        )
    }
}
