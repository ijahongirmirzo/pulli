import Foundation
public import PulliClient
public import PulliProtocol

/// An in-process connection to a `HelperEngine`: the same requests and events as XPC, for tests
/// and for the app's previews on MockDevice (Phase 4 before real USB).
public final class LoopbackConnection: HelperConnection {
    private let engine: HelperEngine
    private let clientID: UUID
    public let events: AsyncStream<SequencedEvent>

    public init(engine: HelperEngine) async {
        self.engine = engine
        let (id, events) = await engine.connect()
        self.clientID = id
        self.events = events
    }

    public func send(_ request: ClientRequest) async throws -> HelperReply {
        await engine.handle(request, from: clientID)
    }

    public func close() async {
        await engine.disconnect(clientID)
    }
}
