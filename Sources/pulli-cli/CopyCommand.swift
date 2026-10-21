import ArgumentParser
import DeviceAPI
import Foundation
import MTPKit
import TransferCore
import USBKit
import WorkerIPC

struct Copy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Copy files and whole folders from the phone, resumably.",
        discussion: """
            Like cp: list what to copy, then the destination folder. Folders are copied with \
            everything inside them. Progress is committed to a journal as it goes: pull the cable, \
            lock the phone or press Ctrl-C at any point, then plug back in (the command waits) or \
            run the same command again to resume.

            Examples:
              pulli-cli copy /DCIM/Camera ~/Pictures/Phone
              pulli-cli copy /DCIM /Pictures/Screenshots /Download/report.pdf ~/Desktop/Backup
            """
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "Files or folders on the phone, then the destination folder on the Mac.")
    var paths: [String]

    @Option(help: "When a file with the same name exists: auto (skip if identical, else keep both), skip, overwrite, keep-both.")
    var duplicates: String = "auto"

    var duplicatePolicy: DuplicatePolicy {
        DuplicatePolicy(rawValue: duplicates.replacingOccurrences(of: "-", with: "_")) ?? .auto
    }

    @Option(name: .customLong("chunk-mib"), help: "Chunk size in MiB (1-64).")
    var chunkMiB: Int = 8

    @Option(help: "Journal file. Defaults to ~/Library/Application Support/Pulli/pulli-cli.sqlite.")
    var journal: String?

    @Flag(help: "Put files that needed attention last time back in the queue.")
    var retryFailed = false

    @Flag(help: "Talk to the phone through a pulli-mtp-worker process, as the background helper does.")
    var viaWorker = false

    func validate() throws {
        guard paths.count >= 2 else { throw ValidationError("Give at least one path on the phone and a destination folder.") }
        guard (1...64).contains(chunkMiB) else { throw ValidationError("--chunk-mib must be 1-64") }
        guard DuplicatePolicy(rawValue: duplicates.replacingOccurrences(of: "-", with: "_")) != nil else {
            throw ValidationError("--duplicates must be auto, skip, overwrite or keep-both")
        }
    }

    func run() async throws {
        let sources: [RemotePath] = paths.dropLast().map { RemotePath($0) }
        let destination = URL(fileURLWithPath: (paths.last! as NSString).expandingTildeInPath).standardizedFileURL
        let journal = try await openCLIJournal(url: journalURL(journal))

        var configuration = TransferConfiguration()
        configuration.chunkBytes = chunkMiB << 20
        configuration.destinationTimeZone = MTPLibrary.systemTimeZone

        let power = PowerAssertion()
        power.hold(reason: "Pulli is copying files from your phone")
        defer { power.release() }

        // Open once to identify the phone and the selection; the supervisor keeps this session.
        let workerConnector = viaWorker ? WorkerConnector(executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().appendingPathComponent("pulli-mtp-worker"),
            extraArguments: phone.reportOnly ? ["--report-only"] : []) : nil
        let session = try await Phones.open(options: phone, workerConnector: workerConnector)
        if viaWorker {
            Log.note("Using a pulli-mtp-worker process for the phone.")
        }
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)

        let batch: BatchRecord
        if let existing = try journal.unfinishedBatch(deviceKey: session.info.key, storageID: storage.id,
                                                      destinationRoot: destination, selection: sources) {
            batch = existing
            if existing.state == .cancelled { try journal.resumeBatch(existing.id!) }
            let totals = try journal.totals(batchID: batch.id!)
            Log.note("Resuming batch \(batch.id!): \(totals.filesDone + totals.filesSkipped) of \(totals.filesTotal) files done.")
        } else {
            var items: [BatchItem] = []
            for source in sources {
                guard let entry = try await session.stat(source, storage: storage.id) else {
                    await session.close()
                    throw CLIError("\(source) was not found on \(storage.description).")
                }
                items.append(BatchItem(entry, at: source))
            }
            batch = try journal.createBatch(deviceKey: session.info.key, storageID: storage.id, destinationRoot: destination,
                                            items: items, duplicatePolicy: duplicatePolicy,
                                            caseSensitive: Self.isCaseSensitive(destination))
            Log.note("Batch \(batch.id!): copying \(sources.map { $0.description }.joined(separator: ", ")) to \(destination.path)")
        }
        if retryFailed {
            let count = try journal.retryAttention(batchID: batch.id!)
            if count > 0 { Log.note("Retrying \(count) file(s) that needed attention.") }
        }
        Log.note("Journal: \(journal.url.path). Ctrl-C is safe; run the same command to resume.")

        let connector = MTPDeviceConnector(policy: phone.reportOnly ? .reportOnly : .releaseSystemDaemons) { attempt in
            if case .terminated(let pid)? = attempt.released {
                Log.note("Released the phone from macOS's camera service (ptpcamerad, pid \(pid)).")
            }
            if let recovered = attempt.recovered { Log.note("Recovered the phone after an interrupted transfer: \(recovered).") }
        }
        let supervisor = TransferSupervisor(connector: viaWorker ? workerConnector! : connector, journal: journal, sink: POSIXFileSink(),
                                            configuration: configuration)
        let display = BatchDisplay()
        let totals = try await supervisor.run(batchID: batch.id!, session: session) { display.handle($0) }
        display.summarize(totals, batchID: batch.id!, journal: journal)
    }

    static func isCaseSensitive(_ url: URL) -> Bool {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return (try? candidate.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? false
    }
}

func journalURL(_ option: String?) -> URL {
    option.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? Journal.defaultURL(fileName: "pulli-cli.sqlite")
}

/// Opens the journal for the CLI, waiting briefly if locked by a recently killed process.
func openCLIJournal(
    url: URL,
    timeout: Duration = .seconds(15),
    retryInterval: Duration = .milliseconds(500),
    clock: some Clock<Duration> = ContinuousClock(),
    notify: (String) -> Void = { Log.note($0) }
) async throws -> Journal {
    var printedWaiting = false
    let start = clock.now
    while true {
        do {
            return try Journal(url: url)
        } catch JournalError.locked(let path) {
            if !printedWaiting {
                notify("Waiting for the previous run to finish…")
                printedWaiting = true
            }
            if start.duration(to: clock.now) >= timeout {
                throw CLIError("journal \(path) is in use by another Pulli process. If no other pulli-cli or Pulli is running, try again in a moment.")
            }
            try await clock.sleep(for: retryInterval)
        }
    }
}

struct Cancel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mark a copy as cancelled. Partial files are kept (running the copy again resumes) unless --discard."
    )

    @Argument(help: "Batch id (see `pulli-cli batches`).")
    var id: Int64

    @Flag(help: "Delete the partial files instead of keeping them for a later resume.")
    var discard = false

    @Option(help: "Journal file.")
    var journal: String?

    func run() async throws {
        let journal = try await openCLIJournal(url: journalURL(journal))
        try BatchControl.cancel(batchID: id, journal: journal, sink: POSIXFileSink(), discardParts: discard)
        print("Batch \(id) cancelled" + (discard ? "; partial files deleted." : "; run the same copy again to resume."))
    }
}

struct Batches: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List copies in the journal, or show one in detail.")

    @Argument(help: "Batch id to show in detail.")
    var id: Int64?

    @Option(help: "Journal file.")
    var journal: String?

    func run() async throws {
        let journal = try await openCLIJournal(url: journalURL(journal))
        guard let id else {
            let batches = try journal.batches()
            if batches.isEmpty { print("No copies yet.") }
            for batch in batches {
                let totals = try journal.totals(batchID: batch.id!)
                let done = "\(totals.filesDone + totals.filesSkipped)/\(totals.filesTotal)"
                print("\(String(batch.id!).padding(toLength: 5, withPad: " ", startingAt: 0))"
                      + "\(batch.state.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
                      + "\(done.padding(toLength: 14, withPad: " ", startingAt: 0))"
                      + "\(Format.bytes(totals.bytesTotal).padding(toLength: 10, withPad: " ", startingAt: 0))  → \(batch.destinationRoot)")
            }
            return
        }
        let batch = try journal.batch(id)
        let totals = try journal.totals(batchID: id)
        print("Batch \(id) (\(batch.state.rawValue)), \(batch.deviceKey), duplicates: \(batch.duplicatePolicy.rawValue)")
        print("  from: " + batch.selection.split(separator: "\n").joined(separator: ", "))
        print("  to:   \(batch.destinationRoot)")
        print("  \(totals.filesDone) copied, \(totals.filesSkipped) skipped, \(totals.filesNeedingAttention) need attention, \(totals.filesRemaining) remaining")
        print("  \(Format.bytes(totals.bytesDone)) of \(Format.bytes(totals.bytesTotal))")
        for job in try journal.attentionJobs(batchID: id) {
            print("  ! \(job.sourcePath): \(job.lastError ?? "unknown error")")
        }
        for folder in try journal.failedFolders(batchID: id) {
            print("  ! \(folder.sourcePath)/: \(folder.scanError ?? "could not be listed")")
        }
        let renamed = try journal.nameMappings(batchID: id)
        if !renamed.isEmpty {
            print("  Renamed for macOS:")
            for mapping in renamed.prefix(50) { print("    \(mapping.source) → \(mapping.destination) (\(mapping.reason))") }
            if renamed.count > 50 { print("    … and \(renamed.count - 50) more") }
        }
    }
}

/// Console rendering of supervisor events: one redrawn status line plus notes.
final class BatchDisplay: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDraw = ContinuousClock.now - .seconds(1)
    private var lastWait: WaitReason?
    private var rate = 0.0
    private var lastSample: (time: ContinuousClock.Instant, bytes: UInt64)?
    private let started = ContinuousClock.now
    private var startBytes: UInt64?
    /// Bytes actually read from the phone in this run, per job (skipped files add nothing).
    private var transferred: [Int64: UInt64] = [:]

    func handle(_ event: SupervisorEvent) {
        lock.withLock {
            switch event {
            case .connected(let info):
                if lastWait != nil { note("\(info.displayName) connected, \(Format.link(info.usb)). Continuing.") }
                lastWait = nil
            case .waiting(let reason):
                guard reason != lastWait else { return }
                lastWait = reason
                rate = 0
                lastSample = nil
                note("Paused: \(reason)")
            case .batch(.scanning(let folder, _, let files, _)):
                draw("Scanning \(folder.isEmpty ? "/" : folder)… \(files) files found")
            case .batch(.progress(let progress)):
                transferred[progress.job.id!] = progress.file.bytesReceived - min(progress.file.resumedFrom, progress.file.bytesReceived)
                render(progress)
            case .batch(.fileNeedsAttention(let job, let reason)):
                note("Needs attention: \(job.sourcePath): \(reason)")
            case .batch(.fileStarted), .batch(.fileFinished), .batch(.readFailed):
                break
            case .finished:
                FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
            }
        }
    }

    private func render(_ progress: BatchProgress) {
        let now = ContinuousClock.now
        if startBytes == nil { startBytes = progress.bytesDone }
        if let sample = lastSample {
            let interval = (now - sample.time).seconds
            if interval >= 0.5 {
                let instant = Double(progress.bytesDone &- sample.bytes) / interval
                rate = rate == 0 ? instant : rate * 0.7 + instant * 0.3
                lastSample = (now, progress.bytesDone)
            }
        } else {
            lastSample = (now, progress.bytesDone)
        }
        guard now - lastDraw >= .milliseconds(250) else { return }
        let totals = progress.totals
        let fileNumber = totals.filesDone + totals.filesSkipped + totals.filesNeedingAttention + 1
        let remaining = rate > 0 ? Double(totals.bytesTotal - min(progress.bytesDone, totals.bytesTotal)) / rate : .infinity
        let percent = Double(progress.bytesDone) / Double(max(totals.bytesTotal, 1)) * 100
        draw(String(format: "%5.1f%%  file %d/%d  %@ of %@  %@  %@ left  %@", percent, fileNumber, totals.filesTotal,
                    Format.bytes(progress.bytesDone), Format.bytes(totals.bytesTotal), Format.rate(rate),
                    Format.duration(remaining), RemotePath(progress.job.sourcePath).name))
    }

    func summarize(_ totals: BatchTotals, batchID: Int64, journal: Journal) {
        let elapsed = (ContinuousClock.now - started).seconds
        let moved = lock.withLock { transferred.values.reduce(0, +) }
        note("Done: \(totals.filesDone) copied, \(totals.filesSkipped) already there, \(totals.filesNeedingAttention) need attention.")
        note("  \(Format.bytes(moved)) this run in \(Format.duration(elapsed)) (\(Format.rate(Double(moved) / max(elapsed, 0.001)))).")
        if let attention = try? journal.attentionJobs(batchID: batchID), !attention.isEmpty {
            for job in attention.prefix(20) { note("  ! \(job.sourcePath): \(job.lastError ?? "unknown error")") }
            note("  Details: pulli-cli batches \(batchID). Retry: add --retry-failed.")
        }
        if let renamed = try? journal.nameMappings(batchID: batchID), !renamed.isEmpty {
            note("  \(renamed.count) name(s) changed to be valid on macOS: pulli-cli batches \(batchID).")
        }
    }

    private func draw(_ line: String) {
        lastDraw = .now
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + line).utf8))
    }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data(("\r\u{1B}[K" + message + "\n").utf8))
    }
}

extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
