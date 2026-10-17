import Foundation
public import PulliProtocol
public import XPC
import Security
import Synchronization

/// Where the helper listens, and how each side checks the other (docs/DECISIONS.md, D-010).
public enum PulliXPC {
    /// The helper's Mach service. Must match the LaunchAgent plist's `Label` and `MachServices`.
    public static let machServiceName = "app.pulli.mac.helper"

    /// The peer requirement both sides use: same Apple Developer team as ourselves. Returns nil
    /// when this process is not team-signed (local development builds are signed ad hoc); the
    /// service then only accepts processes of the same user, which launchd's per-user domain
    /// already guarantees. Release builds are always team-signed (scripts/sign.sh checks).
    public static func peerRequirement() -> XPCPeerRequirement? {
        ownTeamIdentifier().map { _ in XPCPeerRequirement.isFromSameTeam() }
    }

    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The app's connection to the helper over XPC.
///
/// Requests are Codable `ClientRequest`s answered by one `HelperReply`; events arrive as
/// `SequencedEvent` messages. Connecting starts the helper on demand (launchd).
public final class XPCHelperConnection: HelperConnection, @unchecked Sendable {
    private let session: XPCSession
    public let events: AsyncStream<SequencedEvent>
    private let continuation: AsyncStream<SequencedEvent>.Continuation
    private let timeout: Duration

    /// Connects to the helper's Mach service.
    public convenience init(machService: String = PulliXPC.machServiceName, timeout: Duration = .seconds(30)) throws {
        let (events, continuation) = AsyncStream<SequencedEvent>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
        let handler = Self.handler(continuation)
        let session: XPCSession = if let requirement = PulliXPC.peerRequirement() {
            try XPCSession(machService: machService, requirement: requirement, incomingMessageHandler: handler,
                           cancellationHandler: { _ in continuation.finish() })
        } else {
            try XPCSession(machService: machService, incomingMessageHandler: handler,
                           cancellationHandler: { _ in continuation.finish() })
        }
        self.init(session: session, events: events, continuation: continuation, timeout: timeout)
    }

    /// Connects to an anonymous listener (tests).
    public convenience init(endpoint: XPCEndpoint, timeout: Duration = .seconds(30)) throws {
        let (events, continuation) = AsyncStream<SequencedEvent>.makeStream(bufferingPolicy: .bufferingNewest(4_096))
        let session = try XPCSession(endpoint: endpoint, incomingMessageHandler: Self.handler(continuation),
                                     cancellationHandler: { _ in continuation.finish() })
        self.init(session: session, events: events, continuation: continuation, timeout: timeout)
    }

    private init(session: XPCSession, events: AsyncStream<SequencedEvent>, continuation: AsyncStream<SequencedEvent>.Continuation,
                 timeout: Duration) {
        self.session = session
        self.events = events
        self.continuation = continuation
        self.timeout = timeout
    }

    private static func handler(_ continuation: AsyncStream<SequencedEvent>.Continuation) -> @Sendable (SequencedEvent) -> (any Encodable)? {
        { event in
            continuation.yield(event)
            return nil
        }
    }

    /// Sends a request and waits for its reply, at most `timeout`. The XPC reply callback cannot
    /// be cancelled (a helper launchd refuses to start never answers), so the reply and the
    /// timeout race and whichever comes first resumes the caller.
    public func send(_ request: ClientRequest) async throws -> HelperReply {
        try await send(request, timeout: timeout)
    }

    public func send(_ request: ClientRequest, timeout: Duration) async throws -> HelperReply {
        let once = ResumeOnce<HelperReply>()
        let timer = Task {
            try? await Task.sleep(for: timeout)
            once.resume(with: .failure(PulliError(.deviceUnavailable, "the helper did not answer within \(timeout)")))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            do {
                try session.send(request) { (result: Result<HelperReply, any Error>) in once.resume(with: result) }
            } catch {
                once.resume(with: .failure(error))
            }
        }
    }

    public func close() async {
        session.cancel(reason: "client closed")
        continuation.finish()
    }
}

/// Resumes a continuation exactly once, from whichever side gets there first. A result that
/// arrives before the continuation is set is kept and delivered when it is.
private final class ResumeOnce<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var early: Result<Value, any Error>?
        var done = false
    }

    private let state = Mutex(State())

    func set(_ continuation: CheckedContinuation<Value, any Error>) {
        let early: Result<Value, any Error>? = state.withLock { state in
            if let early = state.early {
                state.done = true
                return early
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func resume(with result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            guard !state.done else { return nil }
            guard let continuation = state.continuation else {
                if state.early == nil { state.early = result }
                return nil
            }
            state.done = true
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
