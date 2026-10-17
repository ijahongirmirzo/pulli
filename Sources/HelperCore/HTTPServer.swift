public import Foundation
@preconcurrency import Network

/// A small HTTP/1.1 server for the phone drive (WebDAV), on 127.0.0.1 only. Persistent
/// connections, `Expect: 100-continue`, fixed-length and chunked request bodies (written to a
/// temporary file, so large PUTs do not sit in memory), and streamed responses.
public final class HTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        /// Percent-encoded, without the query.
        public var path: String
        /// Header names in lower case.
        public var headers: [String: String]
        public var body: Data
        /// PUT bodies are written here instead of `body`.
        public var bodyFile: URL?
        public var bodyLength: UInt64
    }

    public struct Response: Sendable {
        public enum Body: Sendable {
            case data(Data)
            /// `length` bytes produced by `write`, which is handed a send function.
            case stream(length: UInt64, write: @Sendable (@Sendable (Data) async throws -> Void) async throws -> Void)
        }

        public var status: Int
        public var headers: [(String, String)]
        public var body: Body

        public init(status: Int, headers: [(String, String)] = [], body: Body = .data(Data())) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func text(_ status: Int, _ text: String = "") -> Response {
            Response(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: .data(Data(text.utf8)))
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "pulli.drive.http")

    public init(handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    /// Starts listening and returns the port.
    public func start() async throws -> UInt16 {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeFlag()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                Task { await self.serve(connection) }
            }
            listener.start(queue: queue)
        }
        return port
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: Connections

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()
        defer { connection.cancel() }
        while true {
            do {
                guard let request = try await readRequest(connection, buffer: &buffer) else { return }
                let response = await handler(request)
                if ProcessInfo.processInfo.environment["PULLI_HTTP_TRACE"] == "1" {
                    print("HTTP \(Date().timeIntervalSince1970) \(request.method) \(request.path) depth=\(request.headers["depth"] ?? "-") → \(response.status)")
                }
                if let file = request.bodyFile { try? FileManager.default.removeItem(at: file) }
                try await write(response, method: request.method, to: connection)
                if request.headers["connection"]?.lowercased() == "close" { return }
            } catch {
                return
            }
        }
    }

    private func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) }
                else { continuation.resume(returning: Data()) }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static let headEnd = Data("\r\n\r\n".utf8)
    private static let lineEnd = Data("\r\n".utf8)

    private func readRequest(_ connection: NWConnection, buffer: inout Data) async throws -> Request? {
        while buffer.range(of: Self.headEnd) == nil {
            guard let data = try await receive(connection) else { return nil }
            buffer += data
            if buffer.count > 256 << 10 { return nil }
        }
        let end = buffer.range(of: Self.headEnd)!
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        var request = Request(method: method, path: path, headers: headers, body: Data(), bodyFile: nil, bodyLength: 0)

        if headers["expect"]?.lowercased() == "100-continue" {
            try await send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), to: connection)
        }
        // Bodies: PUT goes to a file; anything else (XML) stays in memory.
        var sink: FileHandle?
        if method == "PUT" {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("pulli-put-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            sink = try FileHandle(forWritingTo: file)
            request.bodyFile = file
        }
        defer { try? sink?.close() }
        func take(_ data: Data) throws {
            request.bodyLength += UInt64(data.count)
            if let sink { try sink.write(contentsOf: data) } else { request.body += data }
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                while buffer.range(of: Self.lineEnd) == nil {
                    guard let data = try await receive(connection) else { return nil }
                    buffer += data
                }
                let lineRange = buffer.range(of: Self.lineEnd)!
                let sizeText = String(decoding: buffer[buffer.startIndex..<lineRange.lowerBound], as: UTF8.self).split(separator: ";").first ?? "0"
                buffer = Data(buffer[lineRange.upperBound...])
                guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                if size == 0 {
                    // Trailers end with an empty line.
                    while buffer.range(of: Self.lineEnd) == nil {
                        guard let data = try await receive(connection) else { return nil }
                        buffer += data
                    }
                    buffer = Data(buffer[buffer.range(of: Self.lineEnd)!.upperBound...])
                    break
                }
                while buffer.count < size + 2 {
                    guard let data = try await receive(connection) else { return nil }
                    buffer += data
                }
                try take(Data(buffer.prefix(size)))
                buffer = Data(buffer.dropFirst(size + 2))
            }
        } else if let length = headers["content-length"].flatMap(UInt64.init), length > 0 {
            var remaining = length
            let first = Data(buffer.prefix(Int(min(remaining, UInt64(buffer.count)))))
            buffer = Data(buffer.dropFirst(first.count))
            try take(first)
            remaining -= UInt64(first.count)
            while remaining > 0 {
                guard var data = try await receive(connection) else { return nil }
                if UInt64(data.count) > remaining {
                    buffer = Data(data.dropFirst(Int(remaining)))
                    data = Data(data.prefix(Int(remaining)))
                }
                try take(data)
                remaining -= UInt64(data.count)
            }
        }
        return request
    }

    private func write(_ response: Response, method: String, to connection: NWConnection) async throws {
        let length: UInt64 = switch response.body {
        case .data(let data): UInt64(data.count)
        case .stream(let length, _): length
        }
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(length)\r\nServer: Pulli\r\n\r\n"
        try await send(Data(head.utf8), to: connection)
        guard method != "HEAD" else { return }
        switch response.body {
        case .data(let data):
            if !data.isEmpty { try await send(data, to: connection) }
        case .stream(_, let produce):
            try await produce { [weak self] data in try await self?.send(data, to: connection) }
        }
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 206: "Partial Content"
        case 207: "Multi-Status"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 412: "Precondition Failed"
        case 416: "Range Not Satisfiable"
        case 423: "Locked"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 507: "Insufficient Storage"
        default: "Status"
        }
    }
}

private final class ResumeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
