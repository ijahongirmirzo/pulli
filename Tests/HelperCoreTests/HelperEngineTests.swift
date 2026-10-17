import DeviceAPI
import Foundation
@testable import HelperCore
import MockDevice
import PulliClient
import PulliProtocol
import Synchronization
import Testing
import TransferCore

/// Lists the mock phones that are plugged in, like the IOKit watcher does for real ones.
struct MockWatcher: DeviceWatcher {
    let devices: [MockDevice]

    func currentDevices() async -> [DeviceCandidate] {
        devices.filter(\.isPluggedIn).map {
            DeviceCandidate(key: $0.key, usb: $0.usb, hasFileTransferInterface: $0.mode == .fileTransfer, heldByApp: nil)
        }
    }
}

/// A helper engine over mock phones, a temporary journal and destination.
final class Harness: @unchecked Sendable {
    let root: URL
    let destination: URL
    let devices: [MockDevice]
    private(set) var engine: HelperEngine!
    private(set) var journal: Journal!
    private(set) var client: PulliClient!
    private let states = StateLog()

    init(devices: [MockDevice]) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-helper-tests-\(UUID().uuidString)")
        destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        self.devices = devices
        try await startEngine()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Starts (or restarts, like launchd after a crash) the helper on the same journal.
    func startEngine() async throws {
        journal = try Journal(url: root.appendingPathComponent("journal.sqlite"))
        engine = HelperEngine(journal: journal, sink: POSIXFileSink(), connector: MockConnector(devices: devices),
                              watcher: MockWatcher(devices: devices), version: "test",
                              timeZone: TimeZone(identifier: "UTC")!, pollInterval: .milliseconds(10))
        try await engine.start()
        let connection = await LoopbackConnection(engine: engine)
        client = PulliClient(connection: connection)
        try await client.start(clientName: "tests") { [states] state in states.append(state) }
    }

    func stopEngine() async {
        await client.stop()
        await engine.stop()
        client = nil
        engine = nil
        journal = nil
    }

    var state: PulliState {
        get async { await client.state }
    }

    /// Every state the client has seen, oldest first.
    var history: [PulliState] { states.all }

    /// Waits until `condition` holds for the client's state (up to `timeout`).
    func wait(_ what: String, timeout: Duration = .seconds(30), until condition: (PulliState) -> Bool) async throws -> PulliState {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = await state
            if condition(current) { return current }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for \(what); last state: \(await state)")
        throw CancellationError()
    }

    func copy(_ device: MockDevice, _ paths: [String], to folder: String = "Out") async throws -> Int64 {
        let reply = try await client.send(.createBatch(CreateBatchRequest(
            deviceID: device.key.description, storageID: device.defaultStorage, paths: paths,
            destinationPath: destination.appendingPathComponent(folder).path)))
        guard case .batchCreated(let id) = reply else { throw PulliError(.unknown, "unexpected \(reply)") }
        return id
    }

    /// Checks every file of the batch against the phone.
    func expectCopied(_ device: MockDevice, batchID: Int64, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for job in try journal.jobs(batchID: batchID) {
            #expect(job.status == .done, "\(job.sourcePath) is \(job.status)", sourceLocation: sourceLocation)
            #expect(try Data(contentsOf: job.destinationURL) == device.expectedContent(RemotePath(job.sourcePath)),
                    "\(job.sourcePath)", sourceLocation: sourceLocation)
        }
    }
}

private func samplePhone(serial: String = "PHONE-A", big: UInt64 = 9 << 20) -> MockDevice {
    let device = MockDevice(serial: serial, model: "Galaxy Test")
    device.addFile("DCIM/Camera/IMG_1.jpg", size: 2_345_678)
    device.addFile("DCIM/Camera/VID_2.mp4", size: big)
    device.addFile("DCIM/Camera/IMG_3.jpg", size: 1_000_000)
    device.addFile("Download/doc.pdf", size: 300_000)
    return device
}

@Suite(.serialized) struct HelperEngineTests {
    @Test func showsPhonesAndTheirStateOnlyWhileWatching() async throws {
        let phone = samplePhone()
        let harness = try await Harness(devices: [phone])

        // Not watching: the phone is listed from USB but never opened.
        let listed = try await harness.wait("phone listed") { $0.devices[phone.key.description] != nil }
        #expect(listed.devices[phone.key.description]?.state == .connecting)
        #expect(phone.readCalls == 0)

        _ = try await harness.client.send(.setWatchingDevices(true))
        let ready = try await harness.wait("phone ready") { $0.devices[phone.key.description]?.state == .ready }
        #expect(ready.devices[phone.key.description]?.storages.first?.name == "Internal shared storage")
        #expect(ready.devices[phone.key.description]?.name == "Galaxy Test")

        phone.setMode(.chargingOnly)
        _ = try await harness.wait("charging only") { $0.devices[phone.key.description]?.state == .notInFileTransferMode }

        phone.unplug()
        _ = try await harness.wait("phone gone") { $0.devices[phone.key.description] == nil }
        await harness.stopEngine()
    }

    @Test func copiesAFolderEndToEnd() async throws {
        let phone = samplePhone()
        let harness = try await Harness(devices: [phone])
        _ = try await harness.wait("phone listed") { $0.devices[phone.key.description] != nil }

        let id = try await harness.copy(phone, ["/DCIM"])
        let done = try await harness.wait("copy done") { $0.batches[id]?.phase == .completed }

        let batch = try #require(done.batches[id])
        #expect(batch.filesTotal == 3)
        #expect(batch.filesDone == 3)
        #expect(batch.bytesDone == batch.bytesTotal)
        #expect(batch.title == "DCIM")
        #expect(batch.recent.count == 3)
        #expect(harness.history.contains { $0.batches[id]?.phase == .copying })
        try harness.expectCopied(phone, batchID: id)
        await harness.stopEngine()
    }

    @Test func unpluggingPausesAndReplugResumes() async throws {
        let phone = samplePhone(big: 24 << 20)
        let reads = Counter()
        phone.setFaultInjector { point in
            if case .read = point, reads.increment() == 3 { return .disconnect }   // mid-video (8 MiB chunks)
            return nil
        }
        let harness = try await Harness(devices: [phone])
        _ = try await harness.wait("phone listed") { $0.devices[phone.key.description] != nil }
        let id = try await harness.copy(phone, ["/DCIM"])

        let paused = try await harness.wait("paused") { $0.batches[id]?.phase == .paused(.phoneDisconnected) }
        #expect(paused.batches[id]?.filesNeedingAttention == 0, "unplugging is a pause, never a failure")

        phone.plug()
        _ = try await harness.wait("copy done after replug") { $0.batches[id]?.phase == .completed }
        try harness.expectCopied(phone, batchID: id)
        await harness.stopEngine()
    }

    /// A helper from another build steps aside when asked (the app then connects to the new one).
    @Test func quitsWhenReplacedByAnotherBuild() async throws {
        let harness = try await Harness(devices: [samplePhone(big: 1_000)])
        let asked = Counter()
        await harness.engine.setUpdateHandler { asked.increment() }
        let reply = try await harness.client.send(.prepareForUpdate)
        #expect(reply == .ok)
        try await Task.sleep(for: .milliseconds(600))
        #expect(asked.current == 1)
    }

    @Test func pauseResumeAndCancel() async throws {
        let phone = samplePhone(big: 64 << 20)
        let gate = Counter()
        // Slow the phone down (8 MiB reads, 40 ms each) so the pause lands mid-copy even when the
        // whole test suite runs in parallel.
        phone.setFaultInjector { point in
            if case .read = point { gate.increment(); usleep(40_000) }
            return nil
        }
        let harness = try await Harness(devices: [phone])
        _ = try await harness.wait("phone listed") { $0.devices[phone.key.description] != nil }
        let id = try await harness.copy(phone, ["/DCIM"])

        _ = try await harness.wait("copying") { ($0.batches[id]?.bytesDone ?? 0) > 2 << 20 }
        _ = try await harness.client.send(.control(batchID: id, .pause))
        let paused = try await harness.wait("paused by user") { $0.batches[id]?.phase == .paused(.byUser) }
        let readsAtPause = gate.current
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.current - readsAtPause <= 1, "no reads while paused")
        #expect((paused.batches[id]?.bytesDone ?? 0) < paused.batches[id]?.bytesTotal ?? 0)

        _ = try await harness.client.send(.control(batchID: id, .resume))
        _ = try await harness.wait("done after resume") { $0.batches[id]?.phase == .completed }
        try harness.expectCopied(phone, batchID: id)

        // Cancel a second copy with discard: no partial files remain.
        let second = try await harness.copy(phone, ["/DCIM"], to: "Second")
        _ = try await harness.wait("second copying") { ($0.batches[second]?.bytesDone ?? 0) > 1 << 20 }
        _ = try await harness.client.send(.control(batchID: second, .cancel(discardPartialFiles: true)))
        _ = try await harness.wait("cancelled") { $0.batches[second]?.phase == .cancelled }
        let leftovers = (FileManager.default.enumerator(atPath: harness.destination.appendingPathComponent("Second").path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".part") }
        #expect(leftovers.isEmpty)
        await harness.stopEngine()
    }

    @Test func helperRestartResumesByItself() async throws {
        let phone = samplePhone(big: 28 << 20)
        phone.setFaultInjector { point in
            if case .read = point { usleep(2_000) }
            return nil
        }
        let harness = try await Harness(devices: [phone])
        _ = try await harness.wait("phone listed") { $0.devices[phone.key.description] != nil }
        let id = try await harness.copy(phone, ["/DCIM"])
        _ = try await harness.wait("copying") { ($0.batches[id]?.bytesDone ?? 0) > 4 << 20 }

        // The helper process goes away (quit, crash or reboot), then launchd starts it again.
        await harness.stopEngine()
        let servedBefore = phone.bytesServed
        try await harness.startEngine()

        let done = try await harness.wait("done after restart") { $0.batches[id]?.phase == .completed }
        #expect(done.batches[id]?.filesDone == 3)
        #expect(phone.bytesServed - servedBefore < (28 << 20) + (4 << 20), "resumed, not restarted")
        try harness.expectCopied(phone, batchID: id)
        await harness.stopEngine()
    }

    @Test func twoPhonesAtOnceAreAllInTheSnapshot() async throws {
        let first = samplePhone(serial: "PHONE-A")
        let second = samplePhone(serial: "PHONE-B")
        let harness = try await Harness(devices: [first, second])
        _ = try await harness.wait("both listed") { $0.devices.count == 2 }

        let a = try await harness.copy(first, ["/DCIM"], to: "A")
        let b = try await harness.copy(second, ["/DCIM", "/Download"], to: "B")
        let queued = try await harness.copy(first, ["/Download"], to: "A2")

        let done = try await harness.wait("all done") { state in
            [a, b, queued].allSatisfy { state.batches[$0]?.phase == .completed }
        }
        #expect(done.batchesForMenu.count == 3)
        #expect(harness.history.contains { $0.batches[queued]?.phase == .paused(.queued) }, "second copy on the same phone waits its turn")
        try harness.expectCopied(first, batchID: a)
        try harness.expectCopied(second, batchID: b)
        try harness.expectCopied(first, batchID: queued)
        await harness.stopEngine()
    }

    @Test func browsingAFolderStreamsPages() async throws {
        let phone = MockDevice()
        for index in 0..<700 { phone.addFile(RemotePath("DCIM/Camera/IMG_\(index).jpg"), size: 100) }
        let harness = try await Harness(devices: [phone])
        _ = try await harness.wait("phone listed") { $0.devices[phone.key.description] != nil }

        var entries: [FolderEntry] = []
        var pages = 0
        for await page in try await harness.client.listFolder(deviceID: phone.key.description, storageID: phone.defaultStorage, path: "/DCIM/Camera") {
            #expect(page.error == nil)
            entries += page.entries
            if !page.entries.isEmpty { pages += 1 }
        }
        #expect(entries.count == 700)
        #expect(pages >= 3)
        await harness.stopEngine()
    }

    @Test func suggestsSmallerChunkWhenReadsKeepFailing() async throws {
        let phoneA = samplePhone(serial: "PHONE-A", big: 24 << 20)
        let phoneB = samplePhone(serial: "PHONE-B", big: 24 << 20)
        let failA = Mutex(true)
        phoneA.setFaultInjector { point in
            if case .read = point, failA.withLock({ $0 }) {
                return .transient
            }
            return nil
        }
        let failB = Mutex(true)
        phoneB.setFaultInjector { point in
            if case .read = point, failB.withLock({ $0 }) {
                return .transient
            }
            return nil
        }

        let harness = try await Harness(devices: [phoneA, phoneB])
        _ = try await harness.wait("phones listed") {
            $0.devices[phoneA.key.description] != nil && $0.devices[phoneB.key.description] != nil
        }

        // 1. Phone A: transient read failures trigger a suggestion (8 -> 2)
        let idA = try await harness.copy(phoneA, ["/DCIM"])
        let stateWithSuggestionA = try await harness.wait("chunk suggestion appears for phone A") {
            $0.devices[phoneA.key.description]?.chunkSuggestion != nil
        }
        let suggestionA = try #require(stateWithSuggestionA.devices[phoneA.key.description]?.chunkSuggestion)
        #expect(suggestionA.currentMiB == 8)
        #expect(suggestionA.suggestedMiB == 2)
        #expect(suggestionA.failures >= 3)

        // Accepting updates settings, clears the suggestion, and restarts the batch with the smaller chunk
        failA.withLock { $0 = false }
        let acceptReply = try await harness.client.send(.applyChunkSuggestion(deviceID: phoneA.key.description, accept: true))
        #expect(acceptReply == .ok)

        let afterAccept = try await harness.wait("phone A suggestion gone and settings updated") {
            $0.devices[phoneA.key.description]?.chunkSuggestion == nil &&
            $0.settings.chunkMiB(for: phoneA.key.description) == 2
        }
        #expect(afterAccept.settings.chunkMiBByDevice?[phoneA.key.description] == 2)
        _ = try await harness.wait("phone A batch completes") { $0.batches[idA]?.phase == .completed }

        // 2. Phone B: declining clears the suggestion and remembers the decline
        _ = try await harness.copy(phoneB, ["/DCIM"], to: "OutB")
        let stateWithSuggestionB = try await harness.wait("chunk suggestion appears for phone B") {
            $0.devices[phoneB.key.description]?.chunkSuggestion != nil
        }
        let suggestionB = try #require(stateWithSuggestionB.devices[phoneB.key.description]?.chunkSuggestion)
        #expect(suggestionB.currentMiB == 8)
        #expect(suggestionB.suggestedMiB == 2)

        let declineReply = try await harness.client.send(.applyChunkSuggestion(deviceID: phoneB.key.description, accept: false))
        #expect(declineReply == .ok)

        let afterDecline = try await harness.wait("phone B suggestion gone after decline") {
            $0.devices[phoneB.key.description]?.chunkSuggestion == nil
        }
        #expect(afterDecline.settings.chunkMiBByDevice?[phoneB.key.description] == nil)

        // Let more transient read failures occur on Phone B at size 8
        try await Task.sleep(for: .milliseconds(150))
        let finalState = await harness.state
        #expect(finalState.devices[phoneB.key.description]?.chunkSuggestion == nil)

        await harness.stopEngine()
    }

    @Test func versionMismatchIsRefused() async throws {
        let harness = try await Harness(devices: [])
        var hello = ClientHello(clientName: "old app")
        hello.major = 99
        await #expect(throws: PulliError.self) {
            _ = try await harness.client.send(.hello(hello))
        }
        await harness.stopEngine()
    }
}

@Suite struct PulliStateTests {
    @Test func appliesEventsAndDetectsGaps() {
        var state = PulliState()
        let instance = UUID()
        state.reset(Snapshot(devices: [], batches: [], settings: HelperSettings()), cursor: EventCursor(instanceID: instance, sequence: 10))
        let device = DeviceSnapshot(id: "usb:18d1:X", name: "P", model: nil, manufacturer: nil, link: .usb3, linkBitsPerSecond: nil,
                                    state: .ready, storages: [], resumable: true)
        let applied = state.apply(SequencedEvent(sequence: 11, event: .deviceChanged(device)))
        #expect(applied)
        #expect(state.devices["usb:18d1:X"] == device)
        let duplicate = state.apply(SequencedEvent(sequence: 11, event: .deviceRemoved(id: "usb:18d1:X")))
        #expect(duplicate, "duplicate ignored")
        #expect(state.devices["usb:18d1:X"] != nil)
        let gap = state.apply(SequencedEvent(sequence: 13, event: .deviceRemoved(id: "usb:18d1:X")))
        #expect(!gap, "gap detected")
        let lossy = state.apply(SequencedEvent(sequence: nil, event: .folderPage(browseID: UUID(), entries: [], done: true, error: nil)))
        #expect(lossy)
    }

    @Test func protocolRoundTripsThroughJSON() throws {
        let requests: [ClientRequest] = [
            .hello(ClientHello(clientName: "Pulli")),
            .subscribe(since: EventCursor(instanceID: UUID(), sequence: 4)),
            .createBatch(CreateBatchRequest(deviceID: "usb:04e8:R", storageID: 65537, paths: ["/DCIM"], destinationPath: "~/Pictures")),
            .control(batchID: 3, .cancel(discardPartialFiles: true)),
            .setWatchingDevices(true),
            .recordLog(level: 2, kind: "finder_location", message: "Finder location repaired"),
            .clearHistory,
        ]
        for request in requests {
            let data = try JSONEncoder().encode(request)
            #expect(try JSONDecoder().decode(ClientRequest.self, from: data) == request)
        }
        let event = HelperEvent.batchChanged(BatchSnapshot(
            id: 1, deviceID: "usb:04e8:R", deviceName: "myGalaxy", title: "Camera", destinationPath: "/tmp",
            phase: .paused(.heldBy(appName: "Photos")), filesTotal: 2, filesDone: 1, filesSkipped: 0, filesNeedingAttention: 0,
            bytesTotal: 10, bytesDone: 5, bytesPerSecond: 1, secondsRemaining: 5, current: nil, recent: [],
            createdAt: Date(timeIntervalSince1970: 1), finishedAt: nil))
        #expect(try JSONDecoder().decode(HelperEvent.self, from: JSONEncoder().encode(event)) == event)
    }
}

final class StateLog: Sendable {
    private let states = Mutex<[PulliState]>([])

    func append(_ state: PulliState) { states.withLock { $0.append(state) } }
    var all: [PulliState] { states.withLock { $0 } }
}

final class Counter: Sendable {
    private let value = Mutex(0)

    @discardableResult
    func increment() -> Int { value.withLock { $0 += 1; return $0 } }
    var current: Int { value.withLock { $0 } }
}


@Suite struct CableAdvisorTests {
    @Test func foldOnUSB2SuggestsAUSB3CableWithAPrediction() {
        let advice = CableAdvisor.advice(link: .usb2, throughHub: false, model: "SM-F966B", measured: { $0 == .usb2 ? 29.5e6 : nil })
        #expect(advice.phoneSupports == .usb3)
        #expect(advice.suggestion == .useUSB3Cable)
        #expect(advice.measured)
        #expect(advice.bytesPerSecond == 29.5e6)
        let (now, faster) = advice.duration(ofBytes: 1_830_000_000)
        #expect(Int(now) == 62)
        #expect(faster.map { $0 < now / 2 } == true)
    }

    @Test func hubComesFirst() {
        let advice = CableAdvisor.advice(link: .usb2, throughHub: true, model: "Pixel 9 Pro", measured: { _ in nil })
        #expect(advice.phoneSupports == .usb3)
        #expect(advice.suggestion == .plugDirectly)
        #expect(advice.fasterBytesPerSecond != nil)
    }

    @Test func usb2PhonesAndUSB3LinksGetNoNagging() {
        #expect(CableAdvisor.advice(link: .usb2, throughHub: false, model: "SM-A556B", measured: { _ in nil }).suggestion == .none)
        #expect(CableAdvisor.advice(link: .usb3, throughHub: false, model: "SM-F966B", measured: { _ in nil }).suggestion == .none)
        let unknown = CableAdvisor.advice(link: .usb2, throughHub: false, model: "Some Phone", measured: { _ in nil })
        #expect(unknown.suggestion == .mayBeFaster)
    }
}
