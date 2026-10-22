import Foundation
import Testing
import TransferCore

@Suite struct TransferRateCalculatorTests {
    /// When resuming at 900 MB of 1 GB, committed bytes must not count as throughput in this run.
    @Test func resumedJobNeverReportsMoreThanRealRate() throws {
        var calc = TransferRateCalculator()
        let t0 = ContinuousClock.now

        // Resumes at 900 MB of 1 GB.
        calc.apply(fileBytesReceived: 900_000_000, fileResumedFrom: 900_000_000, jobID: 1, now: t0)
        #expect(calc.rate == 0)
        #expect(calc.isResuming)
        #expect(calc.secondsRemaining(bytesDone: 900_000_000, bytesTotal: 1_000_000_000) == nil)

        // Receives 10 MB in 0.5 s (now at 910 MB).
        let t1 = t0 + .milliseconds(500)
        calc.apply(fileBytesReceived: 910_000_000, fileResumedFrom: 900_000_000, jobID: 1, now: t1)

        // Must report about 20 MB/s (10 MB in 0.5 s), never the absurd ~1820 MB/s.
        #expect(calc.rate > 0)
        #expect(calc.rate <= 20_000_000 + 1)
        #expect(calc.rate >= 19_999_999)
        #expect(!calc.isResuming)

        // Time left uses the same rate: 90 MB left / 20 MB/s = 4.5 s.
        let left = try #require(calc.secondsRemaining(bytesDone: 910_000_000, bytesTotal: 1_000_000_000))
        #expect(abs(left - 4.5) < 0.01)
    }

    /// Fresh starts count from zero and produce the expected rate once sampled.
    @Test func freshStartBehavesAsBefore() {
        var calc = TransferRateCalculator()
        let t0 = ContinuousClock.now

        calc.apply(fileBytesReceived: 0, fileResumedFrom: 0, jobID: 1, now: t0)
        #expect(calc.rate == 0)
        #expect(!calc.isResuming)

        let t1 = t0 + .milliseconds(500)
        calc.apply(fileBytesReceived: 10_000_000, fileResumedFrom: 0, jobID: 1, now: t1)

        #expect(calc.rate <= 20_000_000 + 1)
        #expect(calc.rate >= 19_999_999)
    }

    /// A stall shows no speed rather than decaying nonsense; a short gap between chunks does not.
    @Test func stallShowsNoSpeedButShortGapsKeepIt() {
        var calc = TransferRateCalculator()
        let t0 = ContinuousClock.now

        // Transfer at 20 MB/s.
        calc.apply(fileBytesReceived: 0, fileResumedFrom: 0, jobID: 1, now: t0)
        calc.apply(fileBytesReceived: 10_000_000, fileResumedFrom: 0, jobID: 1, now: t0 + .milliseconds(500))
        #expect(calc.rate > 0)

        // 1 second without new bytes (a big chunk on a slow cable): the speed stays.
        calc.apply(fileBytesReceived: 10_000_000, fileResumedFrom: 0, jobID: 1, now: t0 + .milliseconds(1500))
        #expect(calc.rate > 0)

        // 6 seconds without new bytes: stalled.
        calc.apply(fileBytesReceived: 10_000_000, fileResumedFrom: 0, jobID: 1, now: t0 + .milliseconds(6500))
        #expect(calc.rate == 0)
        #expect(calc.secondsRemaining(bytesDone: 10_000_000, bytesTotal: 100_000_000) == nil)

        // Explicit pause also immediately zeroes speed.
        calc.apply(fileBytesReceived: 20_000_000, fileResumedFrom: 0, jobID: 1, now: t0 + .milliseconds(7000))
        calc.pause()
        #expect(calc.rate == 0)
    }

    /// The next file starting (a progress event with no bytes yet) must not blank the speed.
    @Test func nextFileStartingKeepsSpeed() {
        var calc = TransferRateCalculator()
        let t0 = ContinuousClock.now
        calc.apply(fileBytesReceived: 0, fileResumedFrom: 0, jobID: 1, now: t0)
        calc.apply(fileBytesReceived: 10_000_000, fileResumedFrom: 0, jobID: 1, now: t0 + .milliseconds(500))
        let before = calc.rate
        calc.apply(fileBytesReceived: 0, fileResumedFrom: 0, jobID: 2, now: t0 + .milliseconds(1200))
        #expect(calc.rate == before)
        calc.apply(fileBytesReceived: 8_000_000, fileResumedFrom: 0, jobID: 2, now: t0 + .milliseconds(1600))
        #expect(calc.rate > 0)
    }

    /// Multiple files in a run track fresh bytes smoothly without spikes.
    @Test func multipleFilesInRunTrackSmoothly() {
        var calc = TransferRateCalculator()
        let t0 = ContinuousClock.now

        // File 1 resumes at 90 MB of 100 MB, finishes in 0.5 s (10 MB read).
        calc.apply(fileBytesReceived: 90_000_000, fileResumedFrom: 90_000_000, jobID: 1, now: t0)
        let t1 = t0 + .milliseconds(500)
        calc.apply(fileBytesReceived: 100_000_000, fileResumedFrom: 90_000_000, jobID: 1, now: t1)
        #expect(calc.rate == 20_000_000)

        // File 2 starts fresh, reads 10 MB in next 0.5 s.
        calc.apply(fileBytesReceived: 0, fileResumedFrom: 0, jobID: 2, now: t1)
        let t2 = t1 + .milliseconds(500)
        calc.apply(fileBytesReceived: 10_000_000, fileResumedFrom: 0, jobID: 2, now: t2)

        // Steady state EWMA remains around 20 MB/s.
        #expect(calc.rate == 20_000_000)
    }
}
