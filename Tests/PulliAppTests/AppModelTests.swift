import Foundation
@testable import Pulli
import PulliProtocol
import Testing

/// The app's model against a real in-app engine and the simulated phone: connect, summarise the
/// phone, copy a pick, and land on the Done screen, with no UI.
@MainActor
@Suite(.serialized)
struct AppModelTests {
    private func waitUntil(timeout: Double = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    struct TimeoutError: Error {}

    /// Open in Finder mounts the phone's drive quickly and shows its files; unmounting leaves
    /// nothing behind. Regression (2026-10-08): the NetFS mount failed (-6600), and when made to
    /// work it took 90 seconds. Mounts a real volume, so it runs with PULLI_MOUNT_TEST=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULLI_MOUNT_TEST"] == "1"))
    func mountsThePhoneInFinderQuickly() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(mock: true, journalURL: folder.appendingPathComponent("journal.sqlite"))
        await model.start()
        model.setWindowVisible(true)
        try await waitUntil { model.device?.state == .ready }
        let device = try #require(model.device)

        let started = Date()
        let mountPoint = try #require(await model.mountedDrive())
        #expect(Date().timeIntervalSince(started) < 10)
        let camera = try FileManager.default.contentsOfDirectory(atPath: mountPoint.appendingPathComponent("DCIM/Camera").path)
        #expect(!camera.isEmpty)

        model.unmountFinderDrive(device.id)
        try await waitUntil { !FileManager.default.fileExists(atPath: mountPoint.path) }
        await model.shutdown()
    }

    @Test func copiesAPickFromTheSimulatedPhone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(mock: true, journalURL: folder.appendingPathComponent("journal.sqlite"))
        await model.start()
        #expect(model.connection == .embedded)

        try await waitUntil { model.device?.state == .ready && model.device.map { model.summaries[$0.id] != nil } == true }
        let device = try #require(model.device)
        let summary = try #require(model.summaries[device.id])
        #expect(summary.camera?.files.count == 92)
        #expect(summary.screenshots?.path == "/DCIM/Screenshots")
        #expect(summary.screenshots?.files.count == 12)
        #expect(summary.downloads?.files.count == 2)
        #expect(device.cable?.link == .usb2)
        guard case .overview = model.route else {
            Issue.record("expected the phone screen, got \(model.route)")
            return
        }

        model.picks = [.downloads]
        model.destinationOverride = folder.appendingPathComponent("out").path
        #expect(model.pickedItems().paths == ["/Download"])
        #expect(model.pickedItems().bytes == 244_000)
        await model.copyPicks()
        #expect(model.section == .copies)
        let batchID = try #require(model.focusedBatchID)

        try await waitUntil { model.state.batches[batchID]?.phase == .completed }
        guard case .done(let batch) = model.route else {
            Issue.record("expected the Done screen, got \(model.route)")
            return
        }
        #expect(batch.filesDone == 2)
        let copied = FileManager.default.enumerator(atPath: folder.appendingPathComponent("out").path)?.allObjects as? [String] ?? []
        #expect(copied.contains { $0.hasSuffix("boarding-pass.pdf") })
        #expect(copied.contains { $0.hasSuffix("project-brief.docx") })
        #expect(!copied.contains { $0.hasSuffix(".part") })

        await model.shutdown()
    }

    @Test func clearHistoryClearsCompletedCopiesAndCaches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let model = AppModel(mock: true, journalURL: folder.appendingPathComponent("journal.sqlite"))
        await model.start()

        try await waitUntil { model.device?.state == .ready && model.device.map { model.summaries[$0.id] != nil } == true }

        model.picks = [.downloads]
        model.destinationOverride = folder.appendingPathComponent("out").path
        await model.copyPicks()
        let batchID = try #require(model.focusedBatchID)
        try await waitUntil { model.state.batches[batchID]?.phase == .completed }

        #expect(model.focusedBatchID == batchID)
        #expect(model.state.batches[batchID] != nil)

        await model.clearHistory()

        try await waitUntil { model.state.batches[batchID] == nil }
        #expect(model.focusedBatchID == nil)
        #expect(model.state.batches.isEmpty)

        await model.shutdown()
    }

    @Test func routesFollowTheCopyPhase() {
        var state = Snapshots.state
        let model = AppModel(preview: state)
        model.section = .copies
        model.focusedBatchID = 11
        #expect(model.route.scene == .paused)
        model.focusedBatchID = 12
        #expect(model.route.scene == .copying)
        model.focusedBatchID = 10
        #expect(model.route.scene == .done)
        state.devices = [:]
        let empty = AppModel(preview: state)
        #expect(empty.route == .welcome)
    }

    @Test func picksNeverCopyTheCameraTwice() {
        let model = AppModel(preview: Snapshots.state, summaries: [Snapshots.phone.id: Snapshots.summary])
        model.picks = [.new]
        let new = model.pickedItems()
        #expect(new.count == Snapshots.summary.newItems.count)
        #expect(new.paths.allSatisfy { $0.hasPrefix("/DCIM/Camera/") })
        model.picks = [.camera, .screenshots]
        #expect(model.pickedItems().paths == ["/DCIM/Camera", "/DCIM/Screenshots"])
    }

    /// Owner request (2026-09-27): Back from a folder opened by a card returns to the phone
    /// screen, not to the folder's parent.
    @Test func backReturnsToWhereBrowsingStarted() {
        let model = AppModel(preview: Snapshots.state, summaries: [Snapshots.phone.id: Snapshots.summary])
        model.openBrowser(at: "/DCIM/Camera")
        #expect(model.navTransition == .forward)
        #expect(model.backTitle == "myGalaxy")
        model.browse(to: "/DCIM/Camera/Edited")
        #expect(model.backTitle == "Camera")
        model.goBack()
        #expect(model.browsePath == "/DCIM/Camera")
        #expect(model.navTransition == .back)
        model.goBack()
        #expect(model.browsePath == nil)
        guard case .overview = model.route else {
            Issue.record("expected the phone screen, got \(model.route)")
            return
        }

        // Going above the starting folder by the path bar moves the starting point with it.
        model.openBrowser(at: "/Download")
        model.browse(to: "/")
        #expect(model.browseRoot == "/")
        model.goBack()
        #expect(model.browsePath == nil)
    }

    @Test func sidebarMovesSlideInTheirDirection() {
        let model = AppModel(preview: Snapshots.state)
        model.show(.history)
        #expect(model.navTransition == .up)
        model.show(.copies)
        #expect(model.navTransition == .down)
        model.openBrowser(at: "/DCIM")
        model.show(.phone)
        #expect(model.section == .phone && model.browsePath == nil)
    }

    @Test func formatsLikeTheDesign() {
        #expect(Format.duration(23) == "23 s")
        #expect(Format.duration(24 * 60) == "24 min")
        #expect(Format.duration(80 * 60) == "1 h 20 min")
        #expect(Format.speed(31_400_000) == "31 MB/s")
        #expect(Format.place(NSHomeDirectory() + "/Pictures/From myGalaxy") == "Pictures › From myGalaxy")
    }
}
