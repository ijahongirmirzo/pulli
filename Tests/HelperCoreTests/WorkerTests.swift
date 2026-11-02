import DeviceAPI
import Foundation
import MockDevice
import Testing
import TransferCore
import WorkerIPC

/// Copies through real `pulli-mtp-worker` processes running a simulated phone, including workers
/// that hang (killed by the stall watchdog) and workers that crash.
@Suite(.serialized) struct WorkerProcessTests {
    static var workerURL: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/out/Products/Debug", ".build/out/Products/Release", ".build/debug", ".build/release"]
            .map { root.appendingPathComponent($0).appendingPathComponent("pulli-mtp-worker") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }

    func copy(scenario: String, stallTimeout: Duration = .seconds(30)) async throws -> (WorkerConnector, BatchTotals) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-worker-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = MockScenarios.device(named: "standard")
        let journal = try Journal(url: root.appendingPathComponent("journal.sqlite"))
        let connector = WorkerConnector(executable: Self.workerURL, extraArguments: ["--mock", scenario],
                                        stallTimeout: stallTimeout, openTimeout: .seconds(20), quietAfterKill: .milliseconds(100))

        let session = try await connector.open(expected.key)
        var items: [BatchItem] = []
        for path in ["DCIM", "Download"] {
            let entry = try #require(try await session.stat(RemotePath(path), storage: expected.defaultStorage))
            items.append(BatchItem(entry, at: RemotePath(path)))
        }
        await session.close()
        let batch = try journal.createBatch(deviceKey: expected.key, storageID: expected.defaultStorage,
                                            destinationRoot: root.appendingPathComponent("Out"), items: items)

        var supervisor = TransferSupervisor(connector: connector, journal: journal, sink: POSIXFileSink())
        supervisor.pollInterval = .milliseconds(50)
        supervisor.sleep = { try await Task.sleep(for: min($0, .milliseconds(100))) }
        let totals = try await supervisor.run(batchID: batch.id!)

        for job in try journal.jobs(batchID: batch.id!) {
            #expect(job.status == .done)
            #expect(try Data(contentsOf: job.destinationURL) == expected.expectedContent(RemotePath(job.sourcePath)), "\(job.sourcePath)")
        }
        return (connector, totals)
    }

    @Test func copiesThroughAWorkerProcess() async throws {
        let (_, totals) = try await copy(scenario: "standard")
        #expect(totals.filesDone == 5)
    }

    @Test func hungWorkerIsKilledAndTheCopyContinues() async throws {
        let (connector, totals) = try await copy(scenario: "hang-on-read-4", stallTimeout: .seconds(1))
        #expect(totals.filesDone == 5)
        #expect(connector.stalledWorkersKilled >= 1)
    }

    @Test func crashedWorkerIsReplacedAndTheCopyContinues() async throws {
        let (_, totals) = try await copy(scenario: "crash-on-read-3")
        #expect(totals.filesDone == 5)
    }
}

/// File bytes pass through the pipe on a plain `Thread`, which has no autorelease pool of its own.
@Suite struct FrameChannelMemoryTests {
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// A 48 GB copy once filled a Mac's memory: 2 GB through the channel must not stay in it.
    /// (The allocator keeps about 512 MB of freed 8 MB buffers; that plateau is not a leak.)
    @Test func readingFramesDoesNotKeepTheirBytes() async throws {
        let frames = 256, payload = Data(repeating: 7, count: 8 << 20)
        let pipe = Pipe()
        let channel = FrameChannel(input: pipe.fileHandleForReading, output: pipe.fileHandleForWriting)
        Thread.detachNewThread {
            for id in 0..<frames {
                autoreleasepool { try? channel.write(WorkerFrame(id: UInt64(id), header: WorkerResponse.data, payload: payload)) }
            }
        }
        let growth: UInt64 = await withCheckedContinuation { done in
            Thread.detachNewThread {
                var peak: UInt64 = 0
                let start = Self.footprint()
                for _ in 0..<frames {
                    guard (try? channel.read(WorkerResponse.self)) != nil else { break }
                    peak = max(peak, Self.footprint())
                }
                done.resume(returning: peak > start ? peak - start : 0)
            }
        }
        #expect(growth < 768 << 20, "kept \(growth >> 20) MB of 2048 MB")
    }
}
