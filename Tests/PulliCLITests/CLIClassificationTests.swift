import Darwin
import DeviceAPI
import Foundation
@testable import pulli_cli
import Testing
import TransferCore
import USBKit
import WorkerIPC

@Suite struct CLIClassificationTests {
    // MARK: - Classification tests

    @Test func classifiesTransientAndDeviceGoneAsRetry() {
        #expect(Phones.classify(DeviceError.deviceGone) == .retry)
        #expect(Phones.classify(DeviceError.transient("could not open an MTP session")) == .retry)
        #expect(Phones.classify(DeviceError.transient("Could not init USB on second attempt")) == .retry)
    }

    @Test func classifiesSystemCameraDaemonsAsRetryUnlessReportOnly() {
        let ptp = DeviceError.contended(holder: .process(pid: 100, name: "ptpcamerad"))
        let msc = DeviceError.contended(holder: .process(pid: 101, name: "mscamerad-xpc"))

        #expect(Phones.classify(ptp, reportOnly: false) == .retry)
        #expect(Phones.classify(msc, reportOnly: false) == .retry)

        #expect(Phones.classify(ptp, reportOnly: true) == .fail(Phones.guidance(for: ptp)))
        #expect(Phones.classify(msc, reportOnly: true) == .fail(Phones.guidance(for: msc)))
    }

    @Test func classifiesOwnWorkerWithDeadParentAsRetryAndLiveParentAsFail() {
        let pulliWorker = DeviceError.contended(holder: .process(pid: 200, name: OwnWorkers.name))
        let legacyWorker = DeviceError.contended(holder: .process(pid: 201, name: OwnWorkers.legacyName))
        let expectedLiveFail = OpenDecision.fail("Pulli is using the phone. Quit Pulli or pause its copy, then try again.")

        // Dead parent (orphan) -> .retry
        #expect(Phones.classify(pulliWorker, workerOwner: { _ in .orphan }) == .retry)
        #expect(Phones.classify(legacyWorker, workerOwner: { _ in .orphan }) == .retry)

        // Live parent (this engine, background helper, other Pulli) -> .fail
        #expect(Phones.classify(pulliWorker, workerOwner: { _ in .thisEngine }) == expectedLiveFail)
        #expect(Phones.classify(pulliWorker, workerOwner: { _ in .backgroundHelper }) == expectedLiveFail)
        #expect(Phones.classify(pulliWorker, workerOwner: { _ in .otherPulli }) == expectedLiveFail)
        #expect(Phones.classify(legacyWorker, workerOwner: { _ in .backgroundHelper }) == expectedLiveFail)
    }

    @Test func classifiesUserInterventionErrors() {
        #expect(Phones.classify(DeviceError.noStorage) == .waitForUser(Phones.guidance(for: .noStorage)))
        #expect(Phones.classify(DeviceError.noMTPInterface) == .waitForUser(Phones.guidance(for: .noMTPInterface)))
    }

    @Test func classifiesThirdPartyAppContentionAsFail() {
        let preview = DeviceError.contended(holder: .process(pid: 300, name: "Preview"))
        let aft = DeviceError.contended(holder: .process(pid: 301, name: "Android File Transfer"))
        let driver = DeviceError.contended(holder: .driver(name: "AppleUSBACMControl"))

        #expect(Phones.classify(preview) == .fail("Preview is using the phone. Quit Preview and try again."))
        #expect(Phones.classify(aft) == .fail("Android File Transfer is using the phone. Quit Android File Transfer and try again."))
        #expect(Phones.classify(driver) == .fail(Phones.guidance(for: driver)))
    }

    @Test func classifiesPermanentErrorsAsFail() {
        let notFound = DeviceError.notFound(RemotePath("/DCIM/missing.jpg"))
        let unsupported = DeviceError.unsupported("feature not supported")
        let rejected = DeviceError.rejected("access denied")

        #expect(Phones.classify(notFound) == .fail(Phones.guidance(for: notFound)))
        #expect(Phones.classify(unsupported) == .fail(Phones.guidance(for: unsupported)))
        #expect(Phones.classify(rejected) == .fail(Phones.guidance(for: rejected)))
    }

    // MARK: - Backoff schedule tests

    @Test func backoffScheduleDelays() {
        #expect(BackoffSchedule.delay(forAttempt: 0) == .milliseconds(500))
        #expect(BackoffSchedule.delay(forAttempt: 1) == .seconds(1))
        #expect(BackoffSchedule.delay(forAttempt: 2) == .seconds(2))
        #expect(BackoffSchedule.delay(forAttempt: 3) == .seconds(4))
        #expect(BackoffSchedule.delay(forAttempt: 4) == .seconds(8))
        #expect(BackoffSchedule.delay(forAttempt: 5) == .seconds(8))
        #expect(BackoffSchedule.delay(forAttempt: 10) == .seconds(8))

        var schedule = BackoffSchedule()
        #expect(schedule.next() == .milliseconds(500))
        #expect(schedule.next() == .seconds(1))
        #expect(schedule.next() == .seconds(2))
        #expect(schedule.next() == .seconds(4))
        #expect(schedule.next() == .seconds(8))
        #expect(schedule.next() == .seconds(8))

        #expect(BackoffSchedule.retryTimeout == .seconds(45))
        #expect(BackoffSchedule.userPollInterval == .seconds(2))
        #expect(BackoffSchedule.userTimeout == .seconds(120))
    }

    // MARK: - Journal lock wait tests

    @Test func journalLockWaitRetriesAndFailsWithHelpfulMessage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-lock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let journalFile = folder.appendingPathComponent("pulli-cli.sqlite")
        let lockFile = journalFile.path + ".lock"
        let fd = open(lockFile, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        var notices: [String] = []
        do {
            _ = try await openCLIJournal(
                url: journalFile,
                timeout: .milliseconds(150),
                retryInterval: .milliseconds(30),
                notify: { notices.append($0) }
            )
            Issue.record("Expected openCLIJournal to fail when locked")
        } catch let cliError as CLIError {
            #expect(notices == ["Waiting for the previous run to finish…"])
            #expect(cliError.description.contains("journal \(journalFile.path) is in use by another Pulli process."))
            #expect(cliError.description.contains("If no other pulli-cli or Pulli is running, try again in a moment."))
        }
    }

    @Test func journalLockWaitSucceedsWhenUnlocked() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-unlock-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let journalFile = folder.appendingPathComponent("pulli-cli.sqlite")
        let lockFile = journalFile.path + ".lock"
        let fd = open(lockFile, O_RDWR | O_CREAT, 0o644)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)

        // Release the lock after 60ms in background
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            flock(fd, LOCK_UN)
            close(fd)
        }

        var notices: [String] = []
        let journal = try await openCLIJournal(
            url: journalFile,
            timeout: .seconds(2),
            retryInterval: .milliseconds(25),
            notify: { notices.append($0) }
        )
        #expect(notices == ["Waiting for the previous run to finish…"])
        #expect(FileManager.default.fileExists(atPath: journal.url.path))
    }
}
