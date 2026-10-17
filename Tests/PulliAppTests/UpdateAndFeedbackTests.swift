import Foundation
@testable import Pulli
import PulliProtocol
import Testing

@Suite struct UpdateAndFeedbackTests {
    // MARK: - Version Comparison

    @Test func versionTimestampsOrderChronologically() {
        let earlier = "20261015095845"
        let later = "20261015095846"
        let nextMonth = "20261101000000"

        #expect(UpdateManager.compareVersions(earlier, later) == .orderedAscending)
        #expect(UpdateManager.compareVersions(later, earlier) == .orderedDescending)
        #expect(UpdateManager.compareVersions(earlier, earlier) == .orderedSame)
        #expect(UpdateManager.compareVersions(later, nextMonth) == .orderedAscending)
    }

    @Test func timestampFormatIsNumericAndOrdered() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"

        let stamp1 = formatter.string(from: now)
        let stamp2 = formatter.string(from: now.addingTimeInterval(1))

        #expect(stamp1.count == 14)
        #expect(stamp2.count == 14)
        #expect(Int64(stamp1) != nil)
        #expect(Int64(stamp2) != nil)
        #expect(stamp1 < stamp2)
        #expect(UpdateManager.compareVersions(stamp1, stamp2) == .orderedAscending)
    }

    // MARK: - Feedback Mailto Builder

    @Test func feedbackWithEmptyAddressReturnsNil() {
        #expect(Feedback.buildDraft(
            email: nil,
            shortVersion: "0.4.0",
            build: "20261015120000",
            commit: "abc1234",
            osVersion: "macOS 26.0",
            macModel: "Mac17,3",
            device: nil,
            helperEnabled: true
        ) == nil)

        #expect(Feedback.buildDraft(
            email: "",
            shortVersion: "0.4.0",
            build: "20261015120000",
            commit: "abc1234",
            osVersion: "macOS 26.0",
            macModel: "Mac17,3",
            device: nil,
            helperEnabled: true
        ) == nil)

        #expect(Feedback.buildDraft(
            email: "   \n\t  ",
            shortVersion: "0.4.0",
            build: "20261015120000",
            commit: "abc1234",
            osVersion: "macOS 26.0",
            macModel: "Mac17,3",
            device: nil,
            helperEnabled: true
        ) == nil)
    }

    @Test func feedbackDraftEncodesCorrectlyAndOmitsSerial() {
        let phoneSerial = "SECRET_SERIAL_12345678"
        let device = DeviceSnapshot(
            id: phoneSerial,
            name: "Galaxy Z Fold7",
            model: "SM-F966B",
            manufacturer: "Samsung",
            link: .usb3,
            linkBitsPerSecond: 5_000_000_000,
            state: .ready,
            storages: [],
            resumable: true
        )

        let draft = Feedback.buildDraft(
            email: "support@pulli.app",
            shortVersion: "0.4.0",
            build: "20261015120000",
            commit: "abc1234",
            osVersion: "macOS 26.0 (Build 26A425)",
            macModel: "Mac17,3",
            device: device,
            helperEnabled: true
        )

        let unwrapped = try! #require(draft)
        #expect(unwrapped.subject == "Pulli feedback – 0.4.0 (20261015120000)")

        // Body includes diagnostics
        #expect(unwrapped.body.contains("What happened?"))
        #expect(unwrapped.body.contains("Pulli: 0.4.0 (20261015120000) (abc1234)"))
        #expect(unwrapped.body.contains("macOS: macOS 26.0 (Build 26A425)"))
        #expect(unwrapped.body.contains("Mac model: Mac17,3"))
        #expect(unwrapped.body.contains("Connected phone: Samsung SM-F966B, USB 3"))
        #expect(unwrapped.body.contains("Background helper: On"))

        // Privacy: phone serial or internal ID must NEVER be included
        #expect(!unwrapped.body.contains(phoneSerial))
        #expect(!unwrapped.url.absoluteString.contains(phoneSerial))

        // mailto URL formatting and length
        #expect(unwrapped.url.scheme == "mailto")
        #expect(unwrapped.url.absoluteString.hasPrefix("mailto:support@pulli.app?"))
        #expect(unwrapped.url.absoluteString.count < 1500)
    }

    @Test func feedbackDraftWithoutPhoneOrCommit() {
        let draft = Feedback.buildDraft(
            email: "feedback@pulli.app",
            shortVersion: "0.4.0",
            build: "20261015120000",
            commit: nil,
            osVersion: "macOS 26.0",
            macModel: "Mac17,3",
            device: nil,
            helperEnabled: false
        )

        let unwrapped = try! #require(draft)
        #expect(unwrapped.body.contains("Connected phone: None"))
        #expect(unwrapped.body.contains("Background helper: Off"))
        #expect(unwrapped.body.contains("Pulli: 0.4.0 (20261015120000)\n"))
    }

    // MARK: - Relaunch Postponement

    private static func makeBatch(id: Int64, phase: BatchPhase) -> BatchSnapshot {
        BatchSnapshot(
            id: id,
            deviceID: "dev1",
            deviceName: "Galaxy S24",
            title: "Camera",
            destinationPath: "/tmp",
            phase: phase,
            filesTotal: 10,
            filesDone: 0,
            filesSkipped: 0,
            filesNeedingAttention: 0,
            bytesTotal: 100,
            bytesDone: 0,
            bytesPerSecond: 0,
            secondsRemaining: nil,
            current: nil,
            recent: [],
            createdAt: Date(),
            finishedAt: phase == .completed ? Date() : nil
        )
    }

    @Test func activeCopiesDetection() {
        let scanningBatch = Self.makeBatch(id: 1, phase: .scanning)
        let copyingBatch = Self.makeBatch(id: 2, phase: .copying)
        let pausedBatch = Self.makeBatch(id: 3, phase: .paused(.byUser))
        let completedBatch = Self.makeBatch(id: 4, phase: .completed)
        let cancelledBatch = Self.makeBatch(id: 5, phase: .cancelled)

        #expect(RelaunchPostponer.hasActiveCopies(in: [scanningBatch]))
        #expect(RelaunchPostponer.hasActiveCopies(in: [copyingBatch]))
        #expect(!RelaunchPostponer.hasActiveCopies(in: [pausedBatch]))
        #expect(!RelaunchPostponer.hasActiveCopies(in: [completedBatch]))
        #expect(!RelaunchPostponer.hasActiveCopies(in: [cancelledBatch]))
        #expect(!RelaunchPostponer.hasActiveCopies(in: []))
    }

    @MainActor
    @Test func relaunchPostponementWaitsUntilCopiesComplete() async {
        let postponer = RelaunchPostponer()
        var installHandlerCalled = false
        var beforeInstallCalled = false

        // 1. When a copy is active, handlePostpone returns true
        let postponed = postponer.handlePostpone(hasActiveCopies: true) {
            installHandlerCalled = true
        }
        #expect(postponed)
        #expect(postponer.isPostponed)
        #expect(!installHandlerCalled)

        // 2. While copies are still active, batchesDidUpdate does nothing
        postponer.batchesDidUpdate(hasActiveCopies: true) {
            beforeInstallCalled = true
        }
        #expect(!installHandlerCalled)
        #expect(!beforeInstallCalled)
        #expect(postponer.isPostponed)

        // 3. When active copies complete, beforeInstall runs and installHandler is invoked
        postponer.batchesDidUpdate(hasActiveCopies: false) {
            beforeInstallCalled = true
        }

        // Wait a turn for the async task to execute
        try? await Task.sleep(for: .milliseconds(50))
        #expect(beforeInstallCalled)
        #expect(installHandlerCalled)
        #expect(!postponer.isPostponed)
    }

    @MainActor
    @Test func relaunchWithoutActiveCopiesDoesNotPostpone() {
        let postponer = RelaunchPostponer()
        var installHandlerCalled = false

        let postponed = postponer.handlePostpone(hasActiveCopies: false) {
            installHandlerCalled = true
        }
        #expect(!postponed)
        #expect(!postponer.isPostponed)
        #expect(!installHandlerCalled)
    }
}
