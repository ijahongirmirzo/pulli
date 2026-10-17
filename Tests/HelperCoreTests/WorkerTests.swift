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
