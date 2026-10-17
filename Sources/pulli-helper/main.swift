import DeviceAPI
import Dispatch
import Foundation
import HelperCore
import MockDevice
import PulliClient
import PulliHost
import PulliProtocol
import TransferCore
import WorkerIPC

// Pulli's background helper: owns the phones and the journal, and runs every copy. Launched on
// demand by launchd through its Mach service (a LaunchAgent registered by the app with
// SMAppService), so copies continue while the app is closed and resume after a restart.
//
//   pulli-helper                  real phones over USB
//   pulli-helper --mock           a simulated phone (for building the app without one)
//   pulli-helper --journal PATH   use another journal file

// libmtp runs only in pulli-mtp-worker processes (docs/DECISIONS.md, D-001), next to this binary.
let workerURL = WorkerConnector.besideCurrentExecutable("pulli-mtp-worker")

let arguments = CommandLine.arguments
let mock = arguments.contains("--mock")
let journalURL = arguments.firstIndex(of: "--journal").flatMap { index in
    arguments.indices.contains(index + 1) ? URL(fileURLWithPath: arguments[index + 1]) : nil
} ?? Journal.defaultURL(fileName: mock ? "journal-mock.sqlite" : "journal.sqlite")

let version = PulliProtocolVersion.build

func log(_ message: String) {
    FileHandle.standardError.write(Data("pulli-helper: \(message)\n".utf8))
}

let journal: Journal
do {
    journal = try Journal(url: journalURL)
} catch JournalError.locked {
    // Another helper already runs (launchd starts one per user); nothing to do.
    log("another helper is running; exiting")
    exit(0)
} catch {
    log("cannot open the journal: \(error)")
    exit(1)
}

let engine: HelperEngine
if mock {
    let phones = MockPhones.make()
    engine = HelperEngine(journal: journal, sink: POSIXFileSink(), connector: MockConnector(devices: phones.devices),
                          watcher: phones, version: version)
} else {
    engine = HelperEngine(journal: journal, sink: POSIXFileSink(), connector: WorkerConnector(executable: workerURL),
                          watcher: USBPhoneWatcher(), version: version)
}

if !mock && !FileManager.default.isExecutableFile(atPath: workerURL.path) {
    log("the phone worker is missing at \(workerURL.path)")
}

await engine.setUpdateHandler {
    log("replaced by another build; exiting")
    exit(0)
}

let server = XPCServer(engine: engine)
do {
    try await engine.start()
    try server.listen()
    log("listening on \(PulliXPC.machServiceName)\(mock ? " (simulated phone)" : ""), journal \(journalURL.path)")
} catch {
    log("failed to start: \(error)")
    exit(1)
}

// launchd sends SIGTERM on logout, shutdown and updates: stop at a clean point.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task {
        log("stopping")
        server.stop()
        await engine.stop(reason: "system request")
        exit(0)
    }
}
termination.resume()

while true {
    try? await Task.sleep(for: .seconds(3600))
}
