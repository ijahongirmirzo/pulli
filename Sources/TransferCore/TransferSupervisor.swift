public import DeviceAPI
import Foundation

/// Why a transfer is paused. Never a failure: each clears itself when the condition goes away.
public enum WaitReason: Sendable, Equatable, CustomStringConvertible {
    case disconnected
    /// Attached, but no storage is visible: locked, or "Allow access" not tapped yet.
    case locked
    /// Attached in "Charging only" (or another non-MTP) USB mode.
    case notInFileTransferMode
    case heldBy(InterfaceHolder)
    case destination(DestinationError)
    case retrying(after: Duration, reason: String)

    public var description: String {
        switch self {
        case .disconnected: "Phone disconnected. Reconnect it to continue."
        case .locked: "Unlock your phone and allow access to continue."
        case .notInFileTransferMode: "On your phone, choose USB mode \"File transfer\"."
        case .heldBy(let holder): "\(CameraClientApps.sanitizedHolderName(holder.name)) is using the phone. Quit it to continue."
        case .destination(let error): "Destination problem: \(error). Fix it to continue."
        case .retrying(let delay, let reason): "\(reason). Retrying in \(delay.formatted(.units(allowed: [.seconds], width: .abbreviated)))."
        }
    }
}

public enum SupervisorEvent: Sendable {
    case connected(DeviceInfo)
    case waiting(WaitReason)
    case batch(BatchEvent)
    case finished(BatchTotals)
}

/// Keeps one batch moving to completion across disconnects, locks, contention, flaky links and
/// destination problems. Used by `pulli-cli` and, from Phase 3, by the background helper.
public struct TransferSupervisor: Sendable {
    public let connector: any DeviceConnector
    public let journal: Journal
    public let sink: any FileSink
    public var configuration: TransferConfiguration
    /// Poll interval while waiting for a condition to clear.
    public var pollInterval: Duration = .seconds(1)
    /// Injectable so tests run instantly and can change the world while "waiting".
    public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Lost sessions (disconnects, stalls, crashed workers) without committed progress after which
    /// commits happen at every 4 MiB block
    /// (docs/DECISIONS.md, D-006: otherwise a flaky link may never make durable progress).
    public var flakyAfterDisconnects = 2

    public init(connector: any DeviceConnector, journal: Journal, sink: any FileSink, configuration: TransferConfiguration = .init()) {
        self.connector = connector
        self.journal = journal
        self.sink = sink
        self.configuration = configuration
    }

    /// Runs the batch until every file is done, skipped or needs attention.
    ///
    /// - Parameter session: an already-open session to start with (saves reopening, which on
    ///   Android resets the USB device).
    public func run(batchID: Int64, session initial: (any DeviceSession)? = nil,
                    events: @Sendable (SupervisorEvent) -> Void = { _ in }) async throws -> BatchTotals {
        let batch = try journal.batch(batchID)
        guard let key = DeviceKey(parsing: batch.deviceKey) else {
            throw JournalError.invariantViolation("batch \(batchID) has an unreadable device key \(batch.deviceKey)")
        }
        let destination = URL(fileURLWithPath: batch.destinationRoot)

        var configuration = configuration
        configuration.smallFileSync = sameVolume(destination, journal.url) ? .ordered : .durable

        var pending = initial
        var backoff = Backoff()
        var disconnectsWithoutProgress = 0

        while true {
            try Task.checkCancellation()

            // 1. A session with visible storage.
            let session: any DeviceSession
            if let existing = pending {
                session = existing
                pending = nil
            } else {
                do {
                    session = try await connector.open(key)
                } catch {
                    events(.waiting(Self.reason(for: error)))
                    try await sleep(pollInterval)
                    continue
                }
            }
            events(.connected(session.info))
            do {
                try await waitForStorage(session, events: events)
            } catch let error as DeviceError {
                await session.close()
                events(.waiting(Self.reason(for: error)))
                try await sleep(pollInterval)
                continue
            }

            // 2. Run, pausing in place for destination problems.
            var runConfiguration = configuration
            if disconnectsWithoutProgress >= flakyAfterDisconnects {
                runConfiguration.commitBytes = ChainDigest.blockSize
            }
            let progressBefore = try journal.totals(batchID: batchID).bytesDone
            let runner = BatchRunner(session: session, journal: journal, sink: sink, configuration: runConfiguration)
            do {
                let totals = try await runWithDestinationWaits(runner, batchID: batchID, destination: destination, events: events)
                await session.close()
                events(.finished(totals))
                return totals
            } catch let error as DeviceError {
                await session.close()
                let progressed = try journal.totals(batchID: batchID).bytesDone > progressBefore
                if progressed { backoff.reset() }
                switch error {
                case .deviceGone:
                    disconnectsWithoutProgress = progressed ? 0 : disconnectsWithoutProgress + 1
                    events(.waiting(.disconnected))
                case .transient, .staleHandle:
                    // A session lost to a stall or a crashed worker counts like a disconnect: if it
                    // keeps happening before a commit, commit every block (D-006).
                    disconnectsWithoutProgress = progressed ? 0 : disconnectsWithoutProgress + 1
                    let delay = backoff.next()
                    events(.waiting(.retrying(after: delay, reason: error.description)))
                    try await sleep(delay)
                default:
                    events(.waiting(Self.reason(for: error)))
                    try await sleep(pollInterval)
                }
            }
        }
    }

    private func runWithDestinationWaits(_ runner: BatchRunner, batchID: Int64, destination: URL,
                                         events: @Sendable (SupervisorEvent) -> Void) async throws -> BatchTotals {
        while true {
            do {
                return try await runner.run(batchID: batchID) { events(.batch($0)) }
            } catch let error as DestinationError {
                events(.waiting(.destination(error)))
                try await waitForDestination(destination, after: error)
            }
        }
    }

    /// Waits while the phone shows no storage (locked, or access not yet allowed), keeping the
    /// session open: closing and reopening would reset the USB device each time.
    private func waitForStorage(_ session: any DeviceSession, events: @Sendable (SupervisorEvent) -> Void) async throws {
        var announced = false
        while try await session.storages().isEmpty {
            if !announced {
                events(.waiting(.locked))
                announced = true
            }
            try await sleep(pollInterval)
        }
    }

    /// Waits until the destination is reachable and has room for at least a couple of chunks.
    private func waitForDestination(_ destination: URL, after error: DestinationError) async throws {
        let needed = UInt64(configuration.chunkBytes) * 2
        while true {
            try await sleep(pollInterval)
            guard let free = sink.availableCapacity(at: destination) ?? sink.availableCapacity(at: destination.deletingLastPathComponent()) else {
                continue
            }
            if error == .noSpace, free < needed { continue }
            return
        }
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        // The destination folder may not exist yet; its nearest existing ancestor decides.
        var candidate = a
        while sink.volumeID(of: candidate) == nil, candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        guard let first = sink.volumeID(of: candidate), let second = sink.volumeID(of: b) else { return false }
        return first == second
    }

    static func reason(for error: any Error) -> WaitReason {
        switch error as? DeviceError {
        case .noStorage?: .locked
        case .noMTPInterface?: .notInFileTransferMode
        case .contended(let holder)?: .heldBy(holder)
        case .transient(let detail)?: .retrying(after: .seconds(1), reason: detail)
        default: .disconnected
        }
    }
}

/// Exponential backoff with jitter: 1, 2, 4 … 60 s, each scaled by 0.5-1.0.
public struct Backoff: Sendable {
    private var attempt = 0

    public init() {}

    public mutating func next() -> Duration {
        let base = min(60.0, pow(2.0, Double(attempt)))
        attempt += 1
        return .milliseconds(Int(base * Double.random(in: 0.5...1.0) * 1000))
    }

    public mutating func reset() { attempt = 0 }
}
