public import Foundation

/// A WebDAV client implementing `RemoteFileSource`. Maps remote paths to WebDAV URLs relative
/// to a base URL, issues standard WebDAV requests (PROPFIND, GET, PUT, MKCOL, MOVE, DELETE),
/// and parses multistatus responses.
public struct WebDAVSource: RemoteFileSource {
    /// The root URL of the remote file tree.
    public let baseURL: URL

    /// The session used for network transfers.
    public let session: URLSession

    /// Initialises a WebDAV client pointing at `baseURL`.
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: RemoteFileSource

    /// Fetches metadata for an item at `path` via a Depth 0 PROPFIND request.
    public func item(at path: String) async throws -> RemoteItem {
        let normalized = RemotePath.normalize(path)
        let isFolder = normalized == "/"
        let targetURL = url(for: normalized, isFolder: isFolder)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody

        let (data, response) = try await execute(request, method: "PROPFIND", path: normalized)
        guard response.statusCode == 207 else {
            throw RemoteFileError.server(response.statusCode, "Expected 207 Multi-Status.")
        }

        let parser = WebDAVMultistatusParser(baseURL: baseURL)
        let items = try parser.parse(data: data)
        guard let item = items.first(where: { $0.path == normalized }) ?? items.first else {
            throw RemoteFileError.notFound(normalized)
        }
        return item
    }

    /// Lists direct children of `folder` via a Depth 1 PROPFIND request, excluding the folder itself.
    public func list(_ folder: String) async throws -> [RemoteItem] {
        let normalized = RemotePath.normalize(folder)
        let targetURL = url(for: normalized, isFolder: true)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.propfindBody

        let (data, response) = try await execute(request, method: "PROPFIND", path: normalized)
        guard response.statusCode == 207 else {
            throw RemoteFileError.server(response.statusCode, "Expected 207 Multi-Status.")
        }

        let parser = WebDAVMultistatusParser(baseURL: baseURL)
        let items = try parser.parse(data: data)
        return items.filter { $0.path != normalized }
    }

    /// Downloads the remote file to `destination` using streaming bytes, reporting progress.
    public func download(_ path: String, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> RemoteItem {
        let normalized = RemotePath.normalize(path)
        let targetURL = url(for: normalized, isFolder: false)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "GET"

        do {
            let (asyncBytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteFileError.unavailable("Non-HTTP response received.")
            }
            if !(200...299).contains(http.statusCode) {
                var errorBody = Data()
                for try await byte in asyncBytes {
                    errorBody.append(byte)
                    if errorBody.count >= 4096 { break }
                }
                try checkStatus(http, data: errorBody, method: "GET", path: normalized)
            }

            let total: Int64? = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            let parentDir = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            let tempURL = parentDir.appendingPathComponent(".download-\(UUID().uuidString)")

            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let fileHandle = try FileHandle(forWritingTo: tempURL)

            var bytesSoFar: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(65536)

            do {
                for try await byte in asyncBytes {
                    buffer.append(byte)
                    if buffer.count >= 65536 {
                        try fileHandle.write(contentsOf: buffer)
                        bytesSoFar += Int64(buffer.count)
                        progress?(bytesSoFar, total)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty {
                    try fileHandle.write(contentsOf: buffer)
                    bytesSoFar += Int64(buffer.count)
                    progress?(bytesSoFar, total)
                }
                if bytesSoFar == 0 {
                    progress?(0, total)
                }
                try fileHandle.close()
            } catch {
                try? fileHandle.close()
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }

            _ = try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            if let item = Self.makeItemFromHeaders(http, path: normalized, size: bytesSoFar) {
                return item
            }
            return try await item(at: normalized)
        } catch let error as RemoteFileError {
            throw error
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw RemoteFileError.unavailable(error.localizedDescription)
        }
    }

    /// Uploads a local file to `path` using a PUT request, replacing what is there.
    public func upload(_ source: URL, to path: String) async throws -> RemoteItem {
        let normalized = RemotePath.normalize(path)
        let targetURL = url(for: normalized, isFolder: false)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "PUT"

        do {
            let (data, response) = try await session.upload(for: request, fromFile: source)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteFileError.unavailable("Non-HTTP response received.")
            }
            try checkStatus(http, data: data, method: "PUT", path: normalized)
            return try await item(at: normalized)
        } catch let error as RemoteFileError {
            throw error
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw RemoteFileError.unavailable(error.localizedDescription)
        }
    }

    /// Creates a collection at `path` using an MKCOL request.
    public func makeFolder(_ path: String) async throws -> RemoteItem {
        let normalized = RemotePath.normalize(path)
        let targetURL = url(for: normalized, isFolder: true)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "MKCOL"

        _ = try await execute(request, method: "MKCOL", path: normalized)
        return try await item(at: normalized)
    }

    /// Deletes a resource at `path` using a DELETE request.
    public func delete(_ path: String) async throws {
        let normalized = RemotePath.normalize(path)
        let targetURL = url(for: normalized, isFolder: false)

        var request = URLRequest(url: targetURL)
        request.httpMethod = "DELETE"

        _ = try await execute(request, method: "DELETE", path: normalized)
    }

    /// Moves or renames a resource within the source with `Overwrite: F`.
    public func move(_ path: String, to destination: String) async throws -> RemoteItem {
        let fromNormalized = RemotePath.normalize(path)
        let toNormalized = RemotePath.normalize(destination)
        let sourceURL = url(for: fromNormalized, isFolder: false)
        let destinationURL = url(for: toNormalized, isFolder: false)

        var request = URLRequest(url: sourceURL)
        request.httpMethod = "MOVE"
        request.setValue(destinationURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")

        _ = try await execute(request, method: "MOVE", path: fromNormalized, destination: toNormalized)
        return try await item(at: toNormalized)
    }

    // MARK: URL Mapping

    /// Converts a normalized remote path to a full URL relative to `baseURL`.
    private func url(for path: String, isFolder: Bool = false) -> URL {
        let normalized = RemotePath.normalize(path)
        var baseString = baseURL.absoluteString
        if !baseString.hasSuffix("/") {
            baseString += "/"
        }
        if normalized == "/" {
            return URL(string: baseString) ?? baseURL
        }
        let segments = normalized.split(separator: "/", omittingEmptySubsequences: true)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#[]@!$&'()*+,;="))
        let encoded = segments.map { segment in
            segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(segment)
        }
        var full = baseString + encoded.joined(separator: "/")
        if isFolder && !full.hasSuffix("/") {
            full += "/"
        }
        return URL(string: full) ?? baseURL
    }

    // MARK: HTTP Helpers

    private static let propfindBody = Data("<D:propfind xmlns:D=\"DAV:\"><D:allprop/></D:propfind>".utf8)

    /// Parses a 207 multistatus XML response body.
    public static func parseMultistatus(_ data: Data, baseURL: URL) throws -> [RemoteItem] {
        let parser = WebDAVMultistatusParser(baseURL: baseURL)
        return try parser.parse(data: data)
    }

    private func execute(_ request: URLRequest, method: String, path: String, destination: String? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteFileError.unavailable("Non-HTTP response received.")
            }
            try checkStatus(http, data: data, method: method, path: path, destination: destination)
            return (data, http)
        } catch let error as RemoteFileError {
            throw error
        } catch let error as URLError {
            throw mapURLError(error)
        } catch {
            throw RemoteFileError.unavailable(error.localizedDescription)
        }
    }

    private func checkStatus(_ http: HTTPURLResponse, data: Data, method: String, path: String, destination: String? = nil) throws {
        guard !(200...299).contains(http.statusCode) else { return }
        let body = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch http.statusCode {
        case 404:
            throw RemoteFileError.notFound(path)
        case 401, 403:
            throw RemoteFileError.notAllowed(body.isEmpty ? "Operation not permitted." : body)
        case 405 where method == "MKCOL":
            throw RemoteFileError.exists(path)
        case 412 where method == "MOVE":
            throw RemoteFileError.exists(destination ?? path)
        case 507:
            throw RemoteFileError.insufficientSpace
        default:
            throw RemoteFileError.server(http.statusCode, body)
        }
    }

    private func mapURLError(_ error: URLError) -> RemoteFileError {
        switch error.code {
        case .cannotConnectToHost, .networkConnectionLost, .timedOut,
             .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable:
            return .unavailable(error.localizedDescription)
        default:
            return .unavailable(error.localizedDescription)
        }
    }

    private static func makeItemFromHeaders(_ http: HTTPURLResponse, path: String, size: Int64) -> RemoteItem? {
        let headers = http.allHeaderFields
        var modified: Date?
        if let lastModString = (headers["Last-Modified"] ?? headers["last-modified"]) as? String {
            modified = WebDAVMultistatusParser.parseRFC1123(lastModString)
        }
        let contentType = (headers["Content-Type"] ?? headers["content-type"]) as? String
        var etag = (headers["ETag"] ?? headers["etag"]) as? String
        if let raw = etag {
            etag = WebDAVMultistatusParser.cleanETag(raw)
        }
        let version: String
        if let etag, !etag.isEmpty {
            version = etag
        } else {
            let m = modified.map { Int64($0.timeIntervalSince1970) } ?? 0
            version = "\(size)-\(m)"
        }
        return RemoteItem(
            path: path,
            isFolder: false,
            size: size,
            modified: modified,
            created: nil,
            contentType: contentType,
            version: version
        )
    }
}

// MARK: - WebDAV Multistatus XML Parser

/// Parses WebDAV 207 multistatus XML responses using Foundation's XMLParser.
final class WebDAVMultistatusParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    private let baseURL: URL
    private var items: [RemoteItem] = []

    private var inResponse = false
    private var inResourceType = false
    private var currentHref = ""
    private var isFolder = false
    private var currentText = ""
    private var contentLength: String?
    private var lastModified: String?
    private var creationDate: String?
    private var contentType: String?
    private var etag: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(data: Data) throws -> [RemoteItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            if let error = parser.parserError {
                throw error
            }
            throw RemoteFileError.server(207, "Invalid XML in multistatus response.")
        }
        return items
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let local = elementName.lowercased()
        currentText = ""
        switch local {
        case "response":
            inResponse = true
            currentHref = ""
            isFolder = false
            contentLength = nil
            lastModified = nil
            creationDate = nil
            contentType = nil
            etag = nil
        case "resourcetype":
            inResourceType = true
        case "collection":
            if inResourceType || inResponse {
                isFolder = true
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local {
        case "href":
            currentHref = trimmed
        case "resourcetype":
            inResourceType = false
        case "getcontentlength":
            contentLength = trimmed
        case "getlastmodified":
            lastModified = trimmed
        case "creationdate":
            creationDate = trimmed
        case "getcontenttype":
            contentType = trimmed
        case "getetag":
            etag = trimmed
        case "response":
            if inResponse {
                inResponse = false
                if let item = makeItem() {
                    items.append(item)
                }
            }
        default:
            break
        }
    }

    private func makeItem() -> RemoteItem? {
        guard !currentHref.isEmpty else { return nil }
        let path = Self.remotePath(from: currentHref, baseURL: baseURL)
        let folder = isFolder || path == "/" || currentHref.hasSuffix("/")

        let size: Int64? = folder ? nil : (contentLength.flatMap(Int64.init))
        let modified = lastModified.flatMap(Self.parseRFC1123)
        let created = creationDate.flatMap(Self.parseISO8601)

        let clean = etag.flatMap(Self.cleanETag)
        let version: String?
        if let clean, !clean.isEmpty {
            version = clean
        } else {
            let s = size ?? 0
            let m = modified.map { Int64($0.timeIntervalSince1970) } ?? 0
            version = "\(s)-\(m)"
        }

        return RemoteItem(
            path: path,
            isFolder: folder,
            size: size,
            modified: modified,
            created: created,
            contentType: folder ? nil : (contentType?.isEmpty == false ? contentType : nil),
            version: version
        )
    }

    static func cleanETag(_ raw: String) -> String {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("W/\"") && clean.hasSuffix("\"") {
            clean = String(clean.dropFirst(3).dropLast(1))
        } else if clean.hasPrefix("\"") && clean.hasSuffix("\"") {
            clean = String(clean.dropFirst(1).dropLast(1))
        }
        return clean
    }

    static func remotePath(from href: String, baseURL: URL) -> String {
        var basePath = baseURL.path
        while basePath.count > 1 && basePath.hasSuffix("/") {
            basePath.removeLast()
        }
        let decodedPath: String
        if let path = URL(string: href, relativeTo: baseURL)?.path {
            decodedPath = path
        } else {
            decodedPath = href.removingPercentEncoding ?? href
        }

        let path: String
        if decodedPath == basePath {
            path = "/"
        } else if decodedPath.hasPrefix(basePath + "/") {
            path = String(decodedPath.dropFirst(basePath.count))
        } else if basePath == "/" {
            path = decodedPath
        } else {
            path = decodedPath
        }
        return RemotePath.normalize(path)
    }

    /// Dates before 1990 are a source's way of saying "no date" (phones report folders at the
    /// Unix epoch): treated as unknown, so Finder shows "--" instead of 1 January 1970.
    static let earliestRealDate = Date(timeIntervalSince1970: 631_152_000)

    static func parseRFC1123(_ string: String) -> Date? {
        DateParsers.shared.parseRFC1123(string).flatMap { $0 < earliestRealDate ? nil : $0 }
    }

    static func parseISO8601(_ string: String) -> Date? {
        DateParsers.shared.parseISO8601(string).flatMap { $0 < earliestRealDate ? nil : $0 }
    }
}

private final class DateParsers: @unchecked Sendable {
    static let shared = DateParsers()
    private let lock = NSLock()

    private let rfc1123Formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "EEE, d MMM yyyy HH:mm:ss 'GMT'",
            "EEE, d MMM yyyy HH:mm:ss z"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = fmt
            return f
        }
    }()

    private let iso8601Formatter = ISO8601DateFormatter()
    private let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func parseRFC1123(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        for formatter in rfc1123Formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    func parseISO8601(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = iso8601FractionalFormatter.date(from: string) {
            return date
        }
        return iso8601Formatter.date(from: string)
    }
}
