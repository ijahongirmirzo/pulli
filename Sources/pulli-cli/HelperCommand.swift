import ArgumentParser
import Foundation
import PulliClient
import PulliProtocol

struct HelperStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Show what the background helper sees: phones and copies (over XPC).",
        discussion: "Needs the helper running under launchd (scripts/dev-helper.sh install)."
    )

    @Flag(help: "Keep watching and print every change.")
    var follow = false

    func run() async throws {
        let client: PulliClient
        do {
            client = PulliClient(connection: try XPCHelperConnection(timeout: .seconds(5)))
            try await client.start(clientName: "pulli-cli") { state in
                guard follow else { return }
                print(Self.describe(state))
            }
        } catch {
            throw CLIError("The helper is not running (\(error)). Start it with: scripts/dev-helper.sh install [--mock]")
        }
        _ = try await client.send(.setWatchingDevices(true))
        try await Task.sleep(for: .seconds(2))
        print(Self.describe(await client.state))
        if follow {
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
        await client.stop()
    }

    static func describe(_ state: PulliState) -> String {
        var lines: [String] = []
        if state.devices.isEmpty { lines.append("No phones.") }
        for device in state.devices.values.sorted(by: { $0.id < $1.id }) {
            let storage = device.storages.first.map { " · \($0.name)" } ?? ""
            lines.append("\(device.name) [\(device.id)] \(device.link.rawValue) · \(device.state)\(storage)")
        }
        for batch in state.batchesForMenu {
            let percent = Int((batch.fractionDone * 100).rounded())
            lines.append("#\(batch.id) \(batch.deviceName) · \(batch.title) → \(batch.destinationPath) · \(percent)% · \(batch.filesDone)/\(batch.filesTotal) files · \(batch.phase)")
        }
        return lines.joined(separator: "\n")
    }
}
