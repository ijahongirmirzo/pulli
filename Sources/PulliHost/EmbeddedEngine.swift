public import Foundation
import HelperCore
import MockDevice
public import PulliClient
import TransferCore
import WorkerIPC

/// A HelperEngine running inside the app, used when the background helper is not installed.
/// The app talks to it through the same requests and events as over XPC, so the UI does not care
/// where the engine runs. Copies stop when the app quits and resume from the journal next time.
public final class EmbeddedEngine: Sendable {
    public let connection: any HelperConnection
    private let engine: HelperEngine

    public enum StartError: Error, CustomStringConvertible {
        /// The background helper holds the journal: connect to it over XPC instead.
        case helperRunning
        case failed(String)

        public var description: String {
            switch self {
            case .helperRunning: "the background helper is running"
            case .failed(let detail): detail
            }
        }
    }

    private init(engine: HelperEngine, connection: any HelperConnection) {
        self.engine = engine
        self.connection = connection
    }

    /// Starts the engine. Real phones go through `pulli-mtp-worker` processes found next to
    /// `workerURL`'s location; `mock` serves a simulated phone instead (and uses its own journal).
    public static func start(mock: Bool, workerURL: URL, version: String, journalURL: URL? = nil) async throws(StartError) -> EmbeddedEngine {
        let journalURL = journalURL ?? Journal.defaultURL(fileName: mock ? "journal-mock.sqlite" : "journal.sqlite")
        let journal: Journal
        do {
            journal = try Journal(url: journalURL)
        } catch JournalError.locked {
            throw .helperRunning
        } catch {
            throw .failed("cannot open the journal: \(error)")
        }
        let engine: HelperEngine
        if mock {
            let phones = MockPhones.make()
            engine = HelperEngine(journal: journal, sink: POSIXFileSink(), connector: MockConnector(devices: phones.devices),
                                  watcher: phones, version: version, pollInterval: .milliseconds(250))
        } else {
            let phones = PhoneBackend.fromEnvironment().devices(workerURL: workerURL)
            engine = HelperEngine(journal: journal, sink: POSIXFileSink(), connector: phones.connector,
                                  watcher: phones.watcher, version: version)
        }
        do {
            try await engine.start()
        } catch {
            throw .failed("cannot start the engine: \(error)")
        }
        let connection = await LoopbackConnection(engine: engine)
        return EmbeddedEngine(engine: engine, connection: connection)
    }

    /// Stops at a clean point: every running copy commits what it has.
    public func stop() async {
        await engine.stop(reason: "app quit")
    }
}
