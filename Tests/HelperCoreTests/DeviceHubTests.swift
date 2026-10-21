import DeviceAPI
import Foundation
@testable import HelperCore
import MockDevice
import PulliProtocol
import Testing

/// A connector whose open takes as long as a real phone's (releasing ptpcamerad, claiming the
/// interface), counting how often it is asked.
private struct SlowConnector: DeviceConnector {
    let inner: MockConnector
    let opens = Counter()

    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        opens.increment()
        try? await Task.sleep(for: .milliseconds(300))
        return try await inner.open(key)
    }
}

private struct OnePhone: DeviceWatcher {
    let phone: MockDevice
    func currentDevices() async -> [DeviceCandidate] {
        [DeviceCandidate(key: phone.key, usb: phone.usb, hasFileTransferInterface: true, heldByApp: nil)]
    }
}

/// Fails the first `failing` opens, as a phone does while it is still switching USB mode.
private struct FlakyConnector: DeviceConnector {
    let inner: MockConnector
    let failing: Int
    let opens = Counter()

    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        opens.increment()
        if opens.current <= failing { throw .transient("not ready yet") }
        return try await inner.open(key)
    }
}

/// One phone whose USB address can change, as when it re-attaches in another mode.
private final class ReattachingPhone: DeviceWatcher, @unchecked Sendable {
    let phone: MockDevice
    private let lock = NSLock()
    private var address: UInt8

    init(phone: MockDevice) {
        self.phone = phone
        address = phone.usb.address
    }

    func reattach() { lock.withLock { address &+= 1 } }

    func currentDevices() async -> [DeviceCandidate] {
        var usb = phone.usb
        usb.address = lock.withLock { address }
        return [DeviceCandidate(key: phone.key, usb: usb, hasFileTransferInterface: true, heldByApp: nil)]
    }
}

/// One phone whose file-transfer interface macOS's camera service can be made to hold.
private final class GrabbablePhone: DeviceWatcher, @unchecked Sendable {
    let phone: MockDevice
    private let lock = NSLock()
    private var grabbed = false

    init(phone: MockDevice) { self.phone = phone }

    func setGrabbed(_ value: Bool) { lock.withLock { grabbed = value } }

    func currentDevices() async -> [DeviceCandidate] {
        [DeviceCandidate(key: phone.key, usb: phone.usb, hasFileTransferInterface: true, heldByApp: nil,
                         heldBySystemCamera: lock.withLock { grabbed })]
    }
}

/// Counts opens.
private struct CountingConnector: DeviceConnector {
    let inner: MockConnector
    let opens = Counter()

    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        opens.increment()
        return try await inner.open(key)
    }
}

@Suite struct DeviceHubTests {
    /// Regression (2026-10-14, Galaxy Z Fold7): macOS's camera service took the phone a second
    /// after Pulli opened it; Pulli kept the dead session and showed "locked" for good. Seeing
    /// the service hold the interface now drops the session and opens a new one.
    @Test func sessionTakenBySystemCameraIsReopened() async throws {
        let phone = MockDevice(serial: "GRABBED")
        let connector = CountingConnector(inner: MockConnector(devices: [phone]))
        let watcher = GrabbablePhone(phone: phone)
        let hub = DeviceHub(connector: connector, watcher: watcher, pollInterval: .seconds(60))
        await hub.setUIActive(true)
        #expect(connector.opens.current == 1)
        #expect(await hub.snapshots.first?.state == .ready)

        watcher.setGrabbed(true)
        await hub.poll()  // the session is dropped
        #expect(await hub.snapshots.first?.state == .connecting)
        watcher.setGrabbed(false)  // the new open releases the service
        await hub.poll()
        #expect(connector.opens.current == 2)
        #expect(await hub.snapshots.first?.state == .ready)
        await hub.stop()
    }

    /// A session that shows no storage for a while is renewed, and the renewed one sees the
    /// files once the phone allows access.
    @Test func lockedSessionIsRenewed() async throws {
        let phone = MockDevice(serial: "LOCKED")
        phone.setLocked(true)
        let connector = CountingConnector(inner: MockConnector(devices: [phone]))
        let hub = DeviceHub(connector: connector, watcher: OnePhone(phone: phone), pollInterval: .seconds(60),
                            lockedRenewal: .milliseconds(50))
        await hub.setUIActive(true)
        #expect(await hub.snapshots.first?.state == .locked)
        try await Task.sleep(for: .milliseconds(80))
        await hub.poll()  // still nothing after the renewal time: the session is closed
        await hub.poll()  // and a fresh one opened
        #expect(connector.opens.current == 2)
        phone.setLocked(false)
        await hub.poll()
        #expect(await hub.snapshots.first?.state == .ready)
        await hub.stop()
    }

    /// Regression (2026-10-14, Galaxy Z Fold7): switched to "File transfer", the phone took about
    /// 15 s to appear. Opens had failed while it switched, and the retry waited out the backoff;
    /// a phone back on the bus (new USB address) is now tried at once.
    @Test func reattachedPhoneIsTriedAtOnce() async throws {
        let phone = MockDevice(serial: "REATTACH")
        let connector = FlakyConnector(inner: MockConnector(devices: [phone]), failing: 1)
        let watcher = ReattachingPhone(phone: phone)
        let hub = DeviceHub(connector: connector, watcher: watcher, pollInterval: .seconds(60))
        await hub.setUIActive(true)  // the open fails: the next try waits 2 s
        await hub.poll()             // inside that wait: no attempt
        #expect(connector.opens.current == 1)
        #expect(await hub.snapshots.first?.state != .ready)

        watcher.reattach()
        await hub.poll()
        #expect(connector.opens.current == 2)
        #expect(await hub.snapshots.first?.state == .ready)
        await hub.stop()
    }

    /// Regression (2026-09-27, Galaxy Z Fold7): the app announced "watching" twice at launch while
    /// the poll loop ran; each started its own open, and the second worker found the phone held by
    /// the first, so the app said "pulli-mtp-worker is using your phone".
    @Test func concurrentRequestsShareOneOpen() async throws {
        let phone = MockDevice(serial: "SLOWOPEN")
        let connector = SlowConnector(inner: MockConnector(devices: [phone]))
        let hub = DeviceHub(connector: connector, watcher: OnePhone(phone: phone), pollInterval: .seconds(60))
        await hub.poll()  // the phone is seen, not opened (no one is watching yet)
        #expect(connector.opens.current == 0)

        async let first: Void = hub.setUIActive(true)
        async let second: Void = hub.setUIActive(true)
        async let poll: Void = hub.poll()
        async let transfer = hub.open(phone.key)
        _ = await (first, second, poll)
        let session = try await transfer

        #expect(connector.opens.current == 1)
        #expect(await hub.snapshots.first?.state == .ready)
        await session.close()
        await hub.stop()
    }

    /// The phone is reported as connecting/opening as soon as it appears, before a slow open or
    /// catalogue completes, and catalogue progress is forwarded while opening.
    @Test func phoneReportedAsOpeningBeforeCatalogueCompletes() async throws {
        let phone = MockDevice(serial: "PROGRESS_PHONE")
        let connector = ProgressSlowConnector(inner: MockConnector(devices: [phone]))
        let hub = DeviceHub(connector: connector, watcher: OnePhone(phone: phone), pollInterval: .seconds(60))

        let recordedSnapshots = DeviceHubTestBox<[DeviceSnapshot]>([])
        await hub.observe(onChange: { snapshot in
            recordedSnapshots.mutate { $0.append(snapshot) }
        }, onRemove: { _ in })

        Task { await hub.setUIActive(true) }

        let first = try await waitForHubCondition(timeout: .seconds(2)) {
            recordedSnapshots.value.first
        }
        #expect(first.state == .connecting)
        #expect(first.catalogueProgress == nil)

        connector.reportProgress(phone.key, percent: 50)
        let withProgress = try await waitForHubCondition(timeout: .seconds(2)) {
            recordedSnapshots.value.first(where: { $0.catalogueProgress == 50 })
        }
        #expect(withProgress.state == .connecting)

        connector.unblock()
        let ready = try await waitForHubCondition(timeout: .seconds(2)) {
            recordedSnapshots.value.first(where: { $0.state == .ready })
        }
        #expect(ready.catalogueProgress == nil)

        await hub.stop()
    }
}

/// A connector that blocks open until unblocked, and can report opening progress.
private final class ProgressSlowConnector: DeviceConnector, DeviceOpeningProgress, @unchecked Sendable {
    let inner: MockConnector
    let opened = Counter()
    private let lock = NSLock()
    private var progressHandler: (@Sendable (DeviceKey, Int) -> Void)?
    private var unblockContinuation: CheckedContinuation<Void, Never>?

    init(inner: MockConnector) {
        self.inner = inner
    }

    func setProgressHandler(_ handler: (@Sendable (DeviceKey, Int) -> Void)?) {
        lock.withLock { progressHandler = handler }
    }

    func reportProgress(_ key: DeviceKey, percent: Int) {
        let handler = lock.withLock { progressHandler }
        handler?(key, percent)
    }

    func unblock() {
        lock.withLock {
            unblockContinuation?.resume()
            unblockContinuation = nil
        }
    }

    func open(_ key: DeviceKey) async throws(DeviceError) -> any DeviceSession {
        opened.increment()
        await withCheckedContinuation { cont in
            lock.withLock { unblockContinuation = cont }
        }
        return try await inner.open(key)
    }
}

private final class DeviceHubTestBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ initial: T) { stored = initial }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

private func waitForHubCondition<T: Sendable>(timeout: Duration, check: @Sendable () -> T?) async throws -> T {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if let value = check() { return value }
        try? await Task.sleep(for: .milliseconds(20))
    }
    if let value = check() { return value }
    throw CocoaError(.fileNoSuchFile)
}
