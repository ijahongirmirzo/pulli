import DeviceAPI
import Darwin
import Foundation
@testable import HelperCore
import MockDevice
import Testing
import WorkerIPC

/// A stand-in for a worker: `sleep`, copied under the worker's name.
private func workerBinary() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("own-workers-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let binary = folder.appendingPathComponent(OwnWorkers.name)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
    return binary
}

/// The phone is held by a given worker the first time it is opened, then free.
private final class HeldOnce: DeviceConnector, @unchecked Sendable {
    let inner: MockConnector
    let holder: Int32
    private let lock = NSLock()
    private var held = true

    init(inner: MockConnector, holder: Int32) {
        self.inner = inner
        self.holder = holder
    }

    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        let first = lock.withLock { defer { held = false }; return held }
        if first { throw .contended(holder: .process(pid: holder, name: OwnWorkers.name)) }
        return try await inner.open(key)
    }
}

private struct OnePhone: DeviceWatcher {
    let phone: MockDevice
    func currentDevices() async -> [DeviceCandidate] {
        [DeviceCandidate(key: phone.key, usb: phone.usb, hasFileTransferInterface: true, heldByApp: nil)]
    }
}

@Suite(.serialized) struct OwnWorkersTests {
    @Test func aWorkerThisEngineStartedIsItsOwn() throws {
        let worker = Process()
        worker.executableURL = try workerBinary()
        worker.arguments = ["30"]
        try worker.run()
        defer { worker.terminate() }
        #expect(OwnWorkers.processName(worker.processIdentifier) == OwnWorkers.name)
        #expect(OwnWorkers.owner(of: worker.processIdentifier) == .thisEngine)
    }

    /// Regression (2026-10-05, Lenovo A1000): after a stall the phone was held by a Pulli worker,
    /// and Pulli said "pulli-mtp-worker is using your phone" with a Quit button that did nothing.
    @Test func aLeftoverWorkerIsStoppedAndThePhoneOpens() async throws {
        // An orphan: started by a shell that exits at once, so its parent is gone.
        let binary = try workerBinary()
        let pidFile = binary.deletingLastPathComponent().appendingPathComponent("pid")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "\"$0\" 30 & echo $! > \"$1\"", binary.path, pidFile.path]
        try shell.run()
        shell.waitUntilExit()
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(OwnWorkers.owner(of: pid) == .orphan)

        let phone = MockDevice(serial: "LEFTOVER")
        let hub = DeviceHub(connector: HeldOnce(inner: MockConnector(devices: [phone]), holder: pid), watcher: OnePhone(phone: phone),
                            pollInterval: .seconds(60))
        await hub.setUIActive(true)
        await hub.poll()
        // Not reported as another app; the leftover is stopped.
        #expect(await hub.snapshots.first?.state == .connecting)
        try await Task.sleep(for: .milliseconds(300))
        #expect(Darwin.kill(pid, 0) != 0, "the leftover worker was stopped")

        // The next try (a second later) opens the phone.
        try await Task.sleep(for: .seconds(1.1))
        await hub.poll()
        #expect(await hub.snapshots.first?.state == .ready)
        await hub.stop()
    }
}
