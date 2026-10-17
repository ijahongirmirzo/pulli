import ArgumentParser
import Foundation
import MTPKit

@main
struct PulliCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pulli-cli",
        abstract: "Developer tool for Pulli's transfer engine.",
        discussion: """
            Copies are resumable: Ctrl-C, a pulled cable or a crash are all safe. Run the same \
            copy command again (or plug the phone back in while it waits) to continue.
            """,
        subcommands: [Version.self, Devices.self, Doctor.self, Info.self, List.self, Thumbnail.self, DiskUsage.self, Put.self, Remove.self, Copy.self, Batches.self, Cancel.self, Bench.self, HelperStatus.self, ICCCommand.self]
    )

    /// Must run before any thread starts: switches the process to UTC for libmtp's date parsing.
    static func main() async {
        MTPLibrary.bootstrap()
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            var command = try parseAsRoot()
            if var command = command as? any AsyncParsableCommand {
                try await command.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print component versions.")

    func run() {
        print("libmtp \(MTPLibrary.version)")
    }
}

/// Options shared by commands that talk to one phone.
struct PhoneOptions: ParsableArguments {
    @Option(name: .customLong("device"), help: "USB serial of the phone to use, when several are connected.")
    var serial: String?

    @Flag(help: "Never terminate ptpcamerad; only report who holds the phone.")
    var reportOnly = false
}

struct StorageOption: ParsableArguments {
    @Option(help: "Storage to use: its id (e.g. 0x10001) or part of its name. Defaults to the first.")
    var storage: String?
}
