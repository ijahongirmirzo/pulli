import MTPKit
import Testing

@Suite struct MTPLibraryTests {
    @Test func linksVendoredLibmtp() {
        #expect(MTPLibrary.version == "1.1.23")
    }

    @Test func detectionWithoutDevicesDoesNotThrow() async throws {
        // Runs on machines with or without a phone attached; it must never throw for "none".
        _ = try await MTPLibrary.detectRawDevices()
    }
}
