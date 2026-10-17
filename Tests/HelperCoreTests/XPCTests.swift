import DeviceAPI
import Foundation
import HelperCore
import MockDevice
import PulliClient
import PulliProtocol
import Testing
import TransferCore

/// The same flows as `HelperEngineTests`, but every request, reply and event goes through XPC
/// (an anonymous listener in this process), so encoding and the transport are exercised.
@Suite(.serialized) struct XPCTransportTests {
    @Test func copyOverXPCAndReconnectWithReplay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-xpc-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = MockDevice(serial: "XPC-PHONE", model: "XPC Phone")
        phone.addFile("DCIM/Camera/a.jpg", size: 1_500_000)
        phone.addFile("DCIM/Camera/b.mp4", size: 17 << 20)
        phone.setFaultInjector { point in
            if case .read = point { usleep(20_000) }
            return nil
        }

        let journal = try Journal(url: root.appendingPathComponent("journal.sqlite"))
        let engine = HelperEngine(journal: journal, sink: POSIXFileSink(), connector: MockConnector(phone),
                                  watcher: MockWatcher(devices: [phone]), version: "xpc-test", pollInterval: .milliseconds(10))
        try await engine.start()
        let server = XPCServer(engine: engine)
        let endpoint = server.listenAnonymously()

        // First connection: start a copy.
        let first = PulliClient(connection: try XPCHelperConnection(endpoint: endpoint, timeout: .seconds(10)))
        try await first.start(clientName: "xpc test") { _ in }
        _ = try await waitFor(first, "phone listed") { $0.devices[phone.key.description] != nil }
        guard case .batchCreated(let id) = try await first.send(.createBatch(CreateBatchRequest(
            deviceID: phone.key.description, storageID: phone.defaultStorage, paths: ["/DCIM"],
            destinationPath: root.appendingPathComponent("Out").path))) else {
            Issue.record("no batch created")
            return
        }
        _ = try await waitFor(first, "copying") { ($0.batches[id]?.bytesDone ?? 0) > 0 }
        await first.stop()

        // A new connection (the app relaunched) picks up the running copy from a snapshot.
        let second = PulliClient(connection: try XPCHelperConnection(endpoint: endpoint, timeout: .seconds(10)))
        try await second.start(clientName: "xpc test 2") { _ in }
        let done = try await waitFor(second, "done") { $0.batches[id]?.phase == .completed }
        #expect(done.batches[id]?.filesDone == 2)
        for job in try journal.jobs(batchID: id) {
            #expect(try Data(contentsOf: job.destinationURL) == phone.expectedContent(RemotePath(job.sourcePath)))
        }

        // Errors come back as typed PulliErrors.
        await #expect(throws: PulliError.self) {
            _ = try await second.send(.control(batchID: 9_999, .pause))
        }

        await second.stop()
        server.stop()
        await engine.stop()
    }
}

private func waitFor(_ client: PulliClient, _ what: String, timeout: Duration = .seconds(30),
                     until condition: (PulliState) -> Bool) async throws -> PulliState {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let state = await client.state
        if condition(state) { return state }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("timed out waiting for \(what)")
    throw CancellationError()
}
