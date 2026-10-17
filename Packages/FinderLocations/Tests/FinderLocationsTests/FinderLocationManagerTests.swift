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
}
