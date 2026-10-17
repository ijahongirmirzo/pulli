import Darwin
import Foundation
import Testing
import TransferCore

/// Tests data folder resolution and safe migration from Relay.
@Suite struct DataFolderTests {
    private func makeTemporaryDirectory() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("datafolder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    @Test func migrationMovesJournalFilesAndSessionsButLeavesDrives() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let relay = support.appendingPathComponent("Relay", isDirectory: true)
        try FileManager.default.createDirectory(at: relay.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relay.appendingPathComponent("Drives/Phone1"), withIntermediateDirectories: true)

        try Data("journal".utf8).write(to: relay.appendingPathComponent("journal.sqlite"))
        try Data("wal".utf8).write(to: relay.appendingPathComponent("journal.sqlite-wal"))
        try Data("session".utf8).write(to: relay.appendingPathComponent("sessions/serial1"))
        try Data("cli".utf8).write(to: relay.appendingPathComponent("relay-cli.sqlite"))
        try Data("cli-wal".utf8).write(to: relay.appendingPathComponent("relay-cli.sqlite-wal"))
        try Data("drivefile".utf8).write(to: relay.appendingPathComponent("Drives/Phone1/file.txt"))

        let resolved = DataFolder.resolve(applicationSupport: support)
        let pulli = support.appendingPathComponent("Pulli", isDirectory: true)

        #expect(resolved.path == pulli.path)
        #expect(FileManager.default.fileExists(atPath: pulli.appendingPathComponent("journal.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: pulli.appendingPathComponent("journal.sqlite-wal").path))
        #expect(FileManager.default.fileExists(atPath: pulli.appendingPathComponent("sessions/serial1").path))
        #expect(FileManager.default.fileExists(atPath: pulli.appendingPathComponent("pulli-cli.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: pulli.appendingPathComponent("pulli-cli.sqlite-wal").path))
        #expect(!FileManager.default.fileExists(atPath: pulli.appendingPathComponent("relay-cli.sqlite").path))

        // Drives folder remained in Relay because it had contents.
        #expect(FileManager.default.fileExists(atPath: relay.appendingPathComponent("Drives/Phone1/file.txt").path))
        #expect(!FileManager.default.fileExists(atPath: relay.appendingPathComponent("journal.sqlite").path))
    }

    /// Regression (2026-10-14, the owner's Mac): an unmounted phone's empty folder under Drives
    /// must not stop the one-step move of the whole folder.
    @Test func emptyDriveFoldersDoNotBlockTheMove() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let relay = support.appendingPathComponent("Relay", isDirectory: true)
        try FileManager.default.createDirectory(at: relay.appendingPathComponent("Drives/myGalaxy"), withIntermediateDirectories: true)
        try Data("journal".utf8).write(to: relay.appendingPathComponent("journal.sqlite"))

        let resolved = DataFolder.resolve(applicationSupport: support)
        #expect(resolved.lastPathComponent == "Pulli")
        #expect(FileManager.default.fileExists(atPath: resolved.appendingPathComponent("journal.sqlite").path))
        #expect(!FileManager.default.fileExists(atPath: relay.path))
    }

    @Test func heldLockKeepsUsingRelay() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let relay = support.appendingPathComponent("Relay", isDirectory: true)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)

        let journal = relay.appendingPathComponent("journal.sqlite")
        try Data("journal".utf8).write(to: journal)
        let lockURL = relay.appendingPathComponent("journal.sqlite.lock")
        try Data().write(to: lockURL)

        let fd = open(lockURL.path, O_RDWR | O_CLOEXEC)
        #expect(fd >= 0)
        #expect(flock(fd, LOCK_EX) == 0)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }

        let resolved = DataFolder.resolve(applicationSupport: support)
        #expect(resolved.path == relay.path)

        let pulli = support.appendingPathComponent("Pulli", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: pulli.path))
    }

    @Test func existingPulliFolderWins() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let pulli = support.appendingPathComponent("Pulli", isDirectory: true)
        let relay = support.appendingPathComponent("Relay", isDirectory: true)
        try FileManager.default.createDirectory(at: pulli, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)

        try Data("pulli".utf8).write(to: pulli.appendingPathComponent("test.txt"))
        try Data("relay".utf8).write(to: relay.appendingPathComponent("test.txt"))

        let resolved = DataFolder.resolve(applicationSupport: support)
        #expect(resolved.path == pulli.path)
        #expect(FileManager.default.fileExists(atPath: relay.appendingPathComponent("test.txt").path))
    }

    @Test func freshMachineGetsPulli() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let resolved = DataFolder.resolve(applicationSupport: support)
        let pulli = support.appendingPathComponent("Pulli", isDirectory: true)
        let relay = support.appendingPathComponent("Relay", isDirectory: true)

        #expect(resolved.path == pulli.path)
        #expect(FileManager.default.fileExists(atPath: pulli.path))
        #expect(!FileManager.default.fileExists(atPath: relay.path))
    }
}
