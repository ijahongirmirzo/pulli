import ArgumentParser
import DeviceAPI
import Foundation
import MTPKit

struct Bench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure read throughput per chunk size (the brief's 8-64 MiB experiment).",
        discussion: "Reads from the phone only; nothing is written. Use a file of at least 1 GB."
    )

    @OptionGroup var phone: PhoneOptions
    @OptionGroup var storageOption: StorageOption

    @Argument(help: "A large file on the phone.")
    var remotePath: String

    @Option(name: .customLong("chunk-mib"), parsing: .upToNextOption, help: "Chunk sizes in MiB.")
    var chunkMiB: [Int] = [8, 16, 32, 64]

    @Option(help: "MiB to read per chunk size.")
    var mib: Int = 512

    @Option(help: "Passes over all chunk sizes, alternating order to cancel out warm-up effects.")
    var passes: Int = 2

    func run() async throws {
        let session = try await Phones.open(options: phone)
        let storage = try await Phones.storage(of: session, matching: storageOption.storage)
        guard let entry = try await session.stat(RemotePath(remotePath), storage: storage.id) else {
            throw CLIError("\(remotePath) not found")
        }
        let budget = min(UInt64(mib) << 20, entry.size)
        print("\(session.info.displayName), \(Format.link(session.info.usb)), reads: \(session.info.readStrategy.rawValue)")
        print("File \(Format.bytes(entry.size)); reading \(Format.bytes(budget)) per run\n")

        var results: [Int: [(rate: Double, maxCall: Double)]] = [:]
        for pass in 0..<passes {
            let order = pass % 2 == 0 ? chunkMiB : chunkMiB.reversed()
            for chunk in order {
                let chunkBytes = chunk << 20
                var offset: UInt64 = 0
                var slowest = 0.0
                let start = ContinuousClock.now
                while offset < budget {
                    let callStart = ContinuousClock.now
                    let data = try await session.read(entry.ref, offset: offset, maxLength: min(chunkBytes, Int(budget - offset)))
                    slowest = max(slowest, (ContinuousClock.now - callStart).seconds)
                    guard !data.isEmpty else { break }
                    offset += UInt64(data.count)
                }
                let rate = Double(offset) / (ContinuousClock.now - start).seconds
                results[chunk, default: []].append((rate, slowest))
                print(String(format: "pass %d  %3d MiB chunks  %@  slowest call %.2f s", pass + 1, chunk, Format.rate(rate), slowest))
            }
        }

        print("\nchunk   median rate   slowest call")
        for chunk in chunkMiB {
            let runs = results[chunk] ?? []
            let rates = runs.map(\.rate).sorted()
            let median = rates.isEmpty ? 0 : rates[rates.count / 2]
            print(String(format: "%3d MiB  %@  %.2f s", chunk, Format.rate(median).padding(toLength: 12, withPad: " ", startingAt: 0),
                         runs.map(\.maxCall).max() ?? 0))
        }
        await session.close()
    }
}
