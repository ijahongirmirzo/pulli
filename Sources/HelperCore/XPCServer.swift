import Foundation
public import PulliClient
import PulliProtocol
public import XPC

/// Serves a `HelperEngine` over XPC: each connected app is one engine client.
public final class XPCServer: @unchecked Sendable {
    private let engine: HelperEngine
    private var listener: XPCListener?

    public init(engine: HelperEngine) {
        self.engine = engine
    }

    /// Listens on the helper's Mach service (the helper runs under launchd).
    public func listen(machService: String = PulliXPC.machServiceName) throws {
        let handler = sessionHandler()
        listener = if let requirement = PulliXPC.peerRequirement() {
            try XPCListener(service: machService, requirement: requirement, incomingSessionHandler: handler)
        } else {
            try XPCListener(service: machService, incomingSessionHandler: handler)
        }
    }

    /// Listens anonymously and returns the endpoint to connect to (tests, previews).
    public func listenAnonymously() -> XPCEndpoint {
        // Listeners start active unless created with `.inactive`; activating again traps.
        let listener = XPCListener(incomingSessionHandler: sessionHandler())
        self.listener = listener
        return listener.endpoint
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func sessionHandler() -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { [engine] request in
            let peer = Peer(engine: engine)
            let (decision, session) = request.accept(incomingMessageHandler: { (message: XPCReceivedMessage) -> (any Encodable)? in
                let box = MessageBox(message)
                Task {
                    let reply: HelperReply
                    do {
                        let clientRequest = try box.message.decode(as: ClientRequest.self)
                        reply = await engine.handle(clientRequest, from: await peer.clientID())
                    } catch {
                        reply = .error(PulliError(.invalidRequest, "could not read the request: \(error)"))
                    }
                    box.reply(reply)
                }
                return nil
            }, cancellationHandler: { _ in
                Task { await peer.disconnect() }
            })
            Task { await peer.forwardEvents(to: SessionBox(session)) }
            return decision
        }
    }

    /// One connected app: its engine client id and the task pushing events to it.
    private actor Peer {
        let engine: HelperEngine
        private var id: UUID?
        private var events: AsyncStream<SequencedEvent>?
        private var forwarding: Task<Void, Never>?

        init(engine: HelperEngine) {
            self.engine = engine
        }

        func clientID() async -> UUID {
            if let id { return id }
            let (id, events) = await engine.connect()
            self.id = id
            self.events = events
            return id
        }

        func forwardEvents(to session: SessionBox) async {
            _ = await clientID()
            guard let events else { return }
            forwarding = Task {
                for await event in events {
                    do {
                        try session.session.send(event)
                    } catch {
                        break
                    }
                }
            }
        }

        func disconnect() async {
            forwarding?.cancel()
            if let id { await engine.disconnect(id) }
        }
    }

    /// `XPCReceivedMessage` is not Sendable; it is replied to exactly once, from one task.
    private final class MessageBox: @unchecked Sendable {
        let message: XPCReceivedMessage
        init(_ message: XPCReceivedMessage) { self.message = message }
        func reply(_ reply: HelperReply) { message.reply(reply) }
    }

    private final class SessionBox: @unchecked Sendable {
        let session: XPCSession
        init(_ session: XPCSession) { self.session = session }
    }
}
