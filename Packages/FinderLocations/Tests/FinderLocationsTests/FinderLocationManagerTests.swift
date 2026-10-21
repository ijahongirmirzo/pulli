import FileProvider
import FinderLocations
import Foundation
import RemoteFiles
import Testing

/// Tests for FinderLocationManager: identifier generation and domain store coordination.
@Suite struct FinderLocationManagerTests {
    @Test func generatesSafeIdentifiersWithPrefix() {
        let manager = FinderLocationManager(appGroup: "group.test", identifierPrefix: "remote-")

        #expect(manager.identifier(for: "server:123").rawValue == "remote-server-123")
        #expect(manager.identifier(for: "abc_def.xyz-9").rawValue == "remote-abc_def.xyz-9")
        #expect(manager.identifier(for: "invalid/name!").rawValue == "remote-invalid-name-")
        #expect(manager.identifier(for: "").rawValue == "remote-location")
    }

    @Test func managesDomainStoreSettings() {
        let suite = "group.test.\(UUID().uuidString)"
        let manager = FinderLocationManager(appGroup: suite, identifierPrefix: "loc-")
        let settings = RemoteFilesDomainSettings(
            baseURL: URL(string: "http://127.0.0.1:8080/files/")!,
            readOnly: true,
            displayName: "Test Storage"
        )

        let domainID = manager.identifier(for: "drive1")
        #expect(manager.domainStore.settings(for: domainID.rawValue) == nil)

        manager.domainStore.set(settings, for: domainID.rawValue)
        #expect(manager.domainStore.settings(for: domainID.rawValue) == settings)

        manager.domainStore.remove(domainID.rawValue)
        #expect(manager.domainStore.settings(for: domainID.rawValue) == nil)
    }

    @Test func userVisibleURLRetriesWhenDomainIsStillSettingUp() async throws {
        let manager = FinderLocationManager(appGroup: "group.test", identifierPrefix: "loc-")
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test"), displayName: "Test")
        guard let fileProviderManager = NSFileProviderManager(for: domain) else { return }

        let attempts = LockBox(0)
        let expectedURL = URL(fileURLWithPath: "/tmp/Pulli-Test")

        let url = try await manager.userVisibleRootURL(for: fileProviderManager, retries: 5, delay: .milliseconds(1)) {
            let count = attempts.increment()
            if count < 3 {
                throw CocoaError(.fileNoSuchFile)
            }
            return expectedURL
        }

        #expect(url == expectedURL)
        #expect(attempts.value == 3)
    }
}

/// Simple thread-safe box for test counters.
private final class LockBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ initial: T) {
        stored = initial
    }

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() -> Int where T == Int {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
        return stored
    }
}
