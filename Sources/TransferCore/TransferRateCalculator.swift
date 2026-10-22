import Foundation

public extension Duration {
    /// Seconds as a floating-point number.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

/// Measures transfer throughput and calculates time-left estimates.
///
/// Baseline committed bytes from earlier runs are ignored so resume never causes a speed spike.
/// Only bytes actually read from the phone during this run count toward throughput.
public struct TransferRateCalculator: Sendable {
    /// Bytes per second, smoothed over recent samples. Zero until a real sample is available.
    public private(set) var rate: Double = 0

    /// Whether this copy resumed from an existing baseline and has not produced a speed sample yet.
    public var isResuming: Bool {
        rate == 0 && hasResumedBaseline
    }

    /// Bytes received from the device per job in this run (excluding resumed baseline).
    private var transferredByJob: [Int64: UInt64] = [:]

    /// Sum of all fresh bytes received in this run across jobs.
    public private(set) var totalTransferredInRun: UInt64 = 0

    /// Beginning of the current sampling window: timestamp and total bytes transferred at that time.
    private var sampleStart: (time: ContinuousClock.Instant, bytes: UInt64)?

    /// Whether at least one file reported a non-zero resumed baseline.
    private var hasResumedBaseline = false

    /// Minimum duration to wait before producing an initial sample when enough bytes arrived (~0.5 s).
    private let minInitialInterval: Double = 0.5

    /// Minimum fresh bytes to produce an initial sample before ~1 s has elapsed (2 MB).
    private let minInitialBytes: UInt64 = 2_000_000

    /// Maximum duration before producing an initial sample even on slow links (~1 s).
    private let maxInitialWait: Double = 1.0

    /// Window duration for subsequent steady-state samples.
    private let sampleInterval: Double = 0.5

    /// How long without fresh bytes before the speed is shown as stalled.
    private let stallInterval: Double = 5

    public init() {}

    /// Resets the rate window on resume, reconnect or start.
    public mutating func reset() {
        rate = 0
        sampleStart = nil
        transferredByJob.removeAll()
        totalTransferredInRun = 0
        hasResumedBaseline = false
    }

    /// Stops reporting speed immediately on pause or disconnect.
    public mutating func pause() {
        rate = 0
        sampleStart = nil
    }

    /// Updates throughput from file progress.
    public mutating func apply(
        fileBytesReceived: UInt64,
        fileResumedFrom: UInt64,
        jobID: Int64 = 0,
        now: ContinuousClock.Instant = .now
    ) {
        if fileResumedFrom > 0 {
            hasResumedBaseline = true
        }

        // Fresh bytes actually received from the device for this job.
        let freshForJob = fileBytesReceived > fileResumedFrom ? fileBytesReceived - fileResumedFrom : 0
        let previousForJob = transferredByJob[jobID] ?? 0

        if freshForJob > previousForJob {
            totalTransferredInRun += (freshForJob - previousForJob)
            transferredByJob[jobID] = freshForJob
        } else if freshForJob < previousForJob {
            // File restarted (e.g. tail guard mismatch).
            totalTransferredInRun -= min(totalTransferredInRun, previousForJob - freshForJob)
            transferredByJob[jobID] = freshForJob
        }

        guard let start = sampleStart else {
            sampleStart = (time: now, bytes: totalTransferredInRun)
            return
        }

        let elapsed = (now - start.time).seconds
        let bytesDelta = totalTransferredInRun >= start.bytes ? totalTransferredInRun - start.bytes : 0

        if rate == 0 {
            // First sample: wait for ~1 s or a few MB of fresh data (at least 0.5 s).
            let hasEnoughData = (elapsed >= minInitialInterval && bytesDelta >= minInitialBytes) || (elapsed >= maxInitialWait && bytesDelta > 0)
            if hasEnoughData {
                rate = elapsed > 0 ? Double(bytesDelta) / elapsed : 0
                sampleStart = (time: now, bytes: totalTransferredInRun)
            }
        } else {
            // Steady state: update every sample interval.
            if elapsed >= sampleInterval, bytesDelta > 0 {
                let instant = Double(bytesDelta) / elapsed
                rate = rate * 0.7 + instant * 0.3
                sampleStart = (time: now, bytes: totalTransferredInRun)
            } else if elapsed >= stallInterval {
                // Nothing new for a while: stalled, so show no speed rather than decaying nonsense.
                // A progress event without bytes (a new file starting) does not count: a big chunk
                // on a slow cable can take seconds, and the speed must not blink out between files.
                rate = 0
                sampleStart = (time: now, bytes: totalTransferredInRun)
            }
        }
    }

    /// Updates throughput from a BatchProgress event.
    public mutating func apply(progress: BatchProgress, now: ContinuousClock.Instant = .now) {
        apply(
            fileBytesReceived: progress.file.bytesReceived,
            fileResumedFrom: progress.file.resumedFrom,
            jobID: progress.job.id ?? 0,
            now: now
        )
    }

    /// Estimated remaining seconds to complete the batch, or nil if rate is zero or already done.
    public func secondsRemaining(bytesDone: UInt64, bytesTotal: UInt64) -> Double? {
        guard rate > 0, bytesTotal > bytesDone else { return nil }
        return Double(bytesTotal - bytesDone) / rate
    }
}
