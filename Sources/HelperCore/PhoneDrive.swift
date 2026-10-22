public import DeviceAPI
public import Foundation
public import PulliProtocol

/// The phone as a drive in Finder (owner request, 2026-09-27): a WebDAV server on 127.0.0.1 that
/// Finder mounts like a network volume. Everything maps to MTP:
///
/// - PROPFIND lists a folder. Listings are cached for 3 s, because Finder asks often.
/// - GET reads byte ranges straight from the phone, so opening or playing a file does not copy it.
/// - PUT sends a file, MKCOL makes a folder.
/// - DELETE and MOVE (rename) work only with Settings › Allow deleting and renaming in Finder,
///   except on files Finder itself created through this drive in this session.
/// - Finder's own bookkeeping files (`._*`, `.DS_Store` and other dot files it writes) are kept in
///   memory and never written to the phone.
///
/// Reachable only from this Mac, and only under a random path segment.
public actor PhoneDrive {
    let deviceID: String
    let storageID: StorageID
    public let token: String
    public let volume: String
    private let hub: DeviceHub
    private let allowChanges: @Sendable () -> Bool
    private var listings: [String: (at: ContinuousClock.Instant, entries: [RemoteEntry])] = [:]
    /// Finder's files (`._x`, `.DS_Store`), by phone path.
    private var sidecars: [String: Data] = [:]
    /// Files created empty (Finder's first PUT) that have no content on the phone yet.
    private var placeholders: [String: Date] = [:]
    /// Files created through this drive in this session: Finder may replace or remove them.
    private var ours: Set<String> = []

    init(deviceID: String, storageID: StorageID, volume: String, hub: DeviceHub, allowChanges: @escaping @Sendable () -> Bool) {
        self.deviceID = deviceID
        self.storageID = storageID
        self.volume = volume
        self.hub = hub
        self.allowChanges = allowChanges
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20).description
    }

    var prefix: String { "/\(token)/\(volume)" }

    // MARK: Requests

    public func handle(_ request: HTTPServer.Request) async -> HTTPServer.Response {
        guard let path = phonePath(request.path) else { return .text(404) }
        do {
            switch request.method {
            case "OPTIONS":
                return HTTPServer.Response(status: 200, headers: [("DAV", "1, 2"), ("MS-Author-Via", "DAV"),
                                                                  ("Allow", "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, MOVE, LOCK, UNLOCK")])
            case "PROPFIND": return try await propfind(path, depth: request.headers["depth"] ?? "1")
            case "GET", "HEAD": return try await get(path, range: request.headers["range"])
            case "PUT": return try await put(path, request)
            case "MKCOL": return try await mkcol(path)
            case "DELETE": return try await delete(path)
            case "MOVE": return try await move(path, destination: request.headers["destination"], overwrite: request.headers["overwrite"] != "F")
            case "LOCK": return lock(request.path)
            case "UNLOCK": return HTTPServer.Response(status: 204)
            case "PROPPATCH": return proppatch(request.path)
            case "COPY": return .text(403, "Copying on the phone is not supported; copy through the Mac.")
            default: return .text(405)
            }
        } catch let error as DeviceError {
            return .text(error == .deviceGone ? 503 : 409, error.description)
        } catch {
            return .text(500, "\(error)")
        }
    }

    /// "/token/Volume/DCIM/Camera" → "/DCIM/Camera"; nil outside this drive.
    private func phonePath(_ raw: String) -> String? {
        guard let decoded = raw.removingPercentEncoding else { return nil }
        guard decoded == prefix || decoded.hasPrefix(prefix + "/") else { return nil }
        var rest = String(decoded.dropFirst(prefix.count))
        while rest.count > 1, rest.hasSuffix("/") { rest.removeLast() }
        return rest.isEmpty ? "/" : rest
    }

    private func href(_ path: String, folder: Bool) -> String {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#[]@!$&'()*+,;="))) ?? String($0) }
        let volume = self.volume.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self.volume
        let joined = "/\(token)/\(volume)" + (encoded.isEmpty ? "" : "/" + encoded.joined(separator: "/"))
        return folder ? joined + "/" : joined
    }

    private static func isFinderFile(_ name: String) -> Bool { name.hasPrefix(".") }

    // MARK: Phone access

    private func withSession<T>(_ body: (any DeviceSession) async throws -> T) async throws -> T {
        guard let key = await hub.key(forID: deviceID) else { throw DeviceError.deviceGone }
        let session = try await hub.open(key)
        defer { Task { await session.close() } }
        return try await body(session)
    }

    private func list(_ folder: String, fresh: Bool = false) async throws -> [RemoteEntry] {
        if !fresh, let cached = listings[folder], ContinuousClock.now - cached.at < .seconds(3) { return cached.entries }
        let entries = try await withSession { session in
            var all: [RemoteEntry] = []
            for try await page in session.list(RemotePath(folder), storage: storageID) { all += page }
            return all
        }
        listings[folder] = (.now, entries)
        return entries
    }

    private func forget(_ folder: String) { listings[folder] = nil }

    private enum Item {
        case folder(name: String, modified: Int64)
        case file(RemoteEntry)
        case placeholder(Date)
        case finderFile(Data)
    }

    private func item(_ path: String) async throws -> Item? {
        if path == "/" { return .folder(name: volume, modified: 0) }
        if let data = sidecars[path] { return .finderFile(data) }
        if let created = placeholders[path] { return .placeholder(created) }
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        do {
            guard let entry = try await list(parent.isEmpty ? "/" : parent).first(where: { $0.name == name }) else { return nil }
            return entry.isFolder ? .folder(name: entry.name, modified: entry.modifiedWallClock) : .file(entry)
        } catch DeviceError.notFound {
            return nil
        }
    }

    // MARK: PROPFIND

    private func propfind(_ path: String, depth: String) async throws -> HTTPServer.Response {
        guard let target = try await item(path) else { return .text(404) }
        var responses = [response(for: path, target)]
        if case .folder = target, depth != "0" {
            for entry in try await list(path) where !entry.name.isEmpty {
                let child = path == "/" ? "/" + entry.name : path + "/" + entry.name
                responses.append(response(for: child, entry.isFolder ? .folder(name: entry.name, modified: entry.modifiedWallClock) : .file(entry)))
            }
            let prefix = path == "/" ? "/" : path + "/"
            for (child, created) in placeholders where child.hasPrefix(prefix) && !child.dropFirst(prefix.count).contains("/") {
                responses.append(response(for: child, .placeholder(created)))
            }
        }
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n" + responses.joined() + "</D:multistatus>\n"
        return HTTPServer.Response(status: 207, headers: [("Content-Type", "application/xml; charset=utf-8")], body: .data(Data(body.utf8)))
    }

    private func response(for path: String, _ item: Item) -> String {
        let name = path == "/" ? volume : (path as NSString).lastPathComponent
        var props = "<D:displayname>\(Self.xml(name))</D:displayname>"
        switch item {
        case .folder(_, let modified):
            props += "<D:resourcetype><D:collection/></D:resourcetype>"
            props += Self.dates(Self.date(wallClock: modified))
            if path == "/", let space = storageSpace {
                props += "<D:quota-available-bytes>\(space.free)</D:quota-available-bytes><D:quota-used-bytes>\(space.used)</D:quota-used-bytes>"
            }
        case .file(let entry):
            props += "<D:resourcetype/><D:getcontentlength>\(entry.size)</D:getcontentlength>"
            props += "<D:getcontenttype>\(Self.contentType(entry.name))</D:getcontenttype>"
            props += "<D:getetag>\"\(entry.size)-\(entry.modifiedWallClock)\"</D:getetag>"
            props += Self.dates(Self.date(wallClock: entry.modifiedWallClock))
        case .placeholder(let created):
            props += "<D:resourcetype/><D:getcontentlength>0</D:getcontentlength>" + Self.dates(created)
        case .finderFile(let data):
            props += "<D:resourcetype/><D:getcontentlength>\(data.count)</D:getcontentlength>" + Self.dates(Date())
        }
        let folder: Bool = if case .folder = item { true } else { false }
        return "<D:response><D:href>\(Self.xml(href(path, folder: folder)))</D:href><D:propstat><D:prop>\(props)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
    }

    private var storageSpace: (free: UInt64, used: UInt64)?

    /// The drive's size for Finder (called when the drive starts).
    func refreshSpace() async {
        guard let storages = try? await withSession({ try await $0.storages() }),
              let storage = storages.first(where: { $0.id == storageID }) ?? storages.first,
              let free = storage.freeBytes, let capacity = storage.capacityBytes else { return }
        storageSpace = (free, capacity > free ? capacity - free : 0)
    }

    /// The phone's wall clock is encoded as UTC; Finder wants the real instant, or nil when undated.
    static func date(wallClock: Int64) -> Date? {
        guard wallClock > 0 else { return nil }
        let naive = Date(timeIntervalSince1970: TimeInterval(wallClock))
        return naive.addingTimeInterval(-TimeInterval(TimeZone.current.secondsFromGMT(for: naive)))
    }

    private static let httpDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    private static func dates(_ date: Date?) -> String {
        guard let date else { return "" }
        return "<D:getlastmodified>\(httpDate.string(from: date))</D:getlastmodified><D:creationdate>\(ISO8601DateFormatter().string(from: date))</D:creationdate>"
    }

    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func contentType(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        case "gif": "image/gif"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        default: "application/octet-stream"
        }
    }

    // MARK: GET

    private func get(_ path: String, range: String?) async throws -> HTTPServer.Response {
        guard let target = try await item(path) else { return .text(404) }
        switch target {
        case .folder: return .text(405, "Folders cannot be read directly.")
        case .placeholder: return HTTPServer.Response(status: 200)
        case .finderFile(let data): return HTTPServer.Response(status: 200, body: .data(data))
        case .file(let entry):
            var start: UInt64 = 0
            var end: UInt64 = entry.size == 0 ? 0 : entry.size - 1
            var status = 200
            if let range, let spec = range.split(separator: "=").last, range.hasPrefix("bytes=") {
                let bounds = spec.split(separator: ",").first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
                if bounds.count == 2 {
                    if bounds[0].isEmpty, let suffix = UInt64(bounds[1]) {
                        start = entry.size > suffix ? entry.size - suffix : 0
                    } else {
                        start = UInt64(bounds[0]) ?? 0
                        if let last = UInt64(bounds[1]) { end = min(last, end) }
                    }
                    guard start < entry.size else {
                        return HTTPServer.Response(status: 416, headers: [("Content-Range", "bytes */\(entry.size)")])
                    }
                    status = 206
                }
            }
            let length = entry.size == 0 ? 0 : end - start + 1
            var headers = [("Content-Type", Self.contentType(entry.name)), ("Accept-Ranges", "bytes"),
                           ("ETag", "\"\(entry.size)-\(entry.modifiedWallClock)\"")]
            if let date = Self.date(wallClock: entry.modifiedWallClock) {
                headers.append(("Last-Modified", Self.httpDate.string(from: date)))
            }
            if status == 206 { headers.append(("Content-Range", "bytes \(start)-\(end)/\(entry.size)")) }
            let hub = self.hub, deviceID = self.deviceID, ref = entry.ref, first = start
            return HTTPServer.Response(status: status, headers: headers, body: .stream(length: length) { send in
                guard let key = await hub.key(forID: deviceID) else { throw DeviceError.deviceGone }
                let session = try await hub.open(key)
                defer { Task { await session.close() } }
                var offset = first
                while offset < first + length {
                    let data = try await session.read(ref, offset: offset, maxLength: Int(min(4 << 20, first + length - offset)))
                    if data.isEmpty { break }
                    try await send(data)
                    offset += UInt64(data.count)
                }
            })
        }
    }

    // MARK: Changes

    private func put(_ path: String, _ request: HTTPServer.Request) async throws -> HTTPServer.Response {
        let name = (path as NSString).lastPathComponent
        let parent = (path as NSString).deletingLastPathComponent
        if Self.isFinderFile(name) {
            sidecars[path] = request.bodyFile.flatMap { try? Data(contentsOf: $0) } ?? request.body
            return HTTPServer.Response(status: 201)
        }
        guard case .folder? = try await item(parent.isEmpty ? "/" : parent) else { return .text(409, "No such folder on the phone.") }
        let existing = try await item(path)
        let isNew: Bool = if case .none = existing { true } else { false }
        let mayReplace = ours.contains(path) || placeholders[path] != nil || allowChanges()
        if !isNew, !mayReplace {
            return .text(403, "Replacing files on the phone is off. Turn on Settings › Allow deleting and renaming in Finder.")
        }
        guard let file = request.bodyFile, request.bodyLength > 0 else {
            // Finder creates the file empty first, then sends its content: remember it for now.
            if case .file = existing {} else { placeholders[path] = Date() }
            ours.insert(path)
            return HTTPServer.Response(status: 201)
        }
        try await withSession { session in
            if case .file(let old) = existing {
                // Send the new content under a temporary name first, so a failed upload never
                // loses the old file.
                let temporary = ".pulli-\(UUID().uuidString.prefix(8))-\(name)"
                let sent = try await session.upload(file, as: temporary, into: RemotePath(parent.isEmpty ? "/" : parent), storage: storageID) { _ in }
                try await session.delete(old.ref)
                try await session.rename(sent.ref, to: name)
            } else {
                _ = try await session.upload(file, as: name, into: RemotePath(parent.isEmpty ? "/" : parent), storage: storageID) { _ in }
            }
        }
        placeholders[path] = nil
        ours.insert(path)
        forget(parent.isEmpty ? "/" : parent)
        return HTTPServer.Response(status: isNew ? 201 : 204)
    }

    private func mkcol(_ path: String) async throws -> HTTPServer.Response {
        if case .some = try await item(path) { return .text(405, "Already there.") }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard case .folder? = try await item(parent.isEmpty ? "/" : parent) else { return .text(409) }
        _ = try await withSession { try await $0.makeFolder(name, in: RemotePath(parent.isEmpty ? "/" : parent), storage: storageID) }
        ours.insert(path)
        forget(parent.isEmpty ? "/" : parent)
        return HTTPServer.Response(status: 201)
    }

    private func delete(_ path: String) async throws -> HTTPServer.Response {
        if sidecars.removeValue(forKey: path) != nil { return HTTPServer.Response(status: 204) }
        if placeholders.removeValue(forKey: path) != nil { ours.remove(path); return HTTPServer.Response(status: 204) }
        guard path != "/" else { return .text(403) }
        guard ours.contains(path) || allowChanges() else {
            return .text(403, "Deleting on the phone from Finder is off. Turn on Settings › Allow deleting and renaming in Finder.")
        }
        guard let target = try await item(path) else { return .text(404) }
        let ref: ObjectRef? = switch target {
        case .file(let entry): entry.ref
        case .folder: try await withSession { try await $0.stat(RemotePath(path), storage: storageID)?.ref }
        default: nil
        }
        guard let ref else { return .text(404) }
        try await withSession { try await $0.delete(ref) }
        ours.remove(path)
        let parent = (path as NSString).deletingLastPathComponent
        forget(parent.isEmpty ? "/" : parent)
        return HTTPServer.Response(status: 204)
    }

    private func move(_ path: String, destination: String?, overwrite: Bool) async throws -> HTTPServer.Response {
        guard let destination, let url = URL(string: destination), let target = phonePath(url.path(percentEncoded: true)) else { return .text(400) }
        if let data = sidecars.removeValue(forKey: path) {
            sidecars[target] = data
            return HTTPServer.Response(status: 201)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard parent == (target as NSString).deletingLastPathComponent else {
            return .text(403, "Moving between folders on the phone is not supported yet.")
        }
        guard ours.contains(path) || allowChanges() else {
            return .text(403, "Renaming on the phone from Finder is off. Turn on Settings › Allow deleting and renaming in Finder.")
        }
        if let created = placeholders.removeValue(forKey: path) {
            placeholders[target] = created
            ours.insert(target)
            return HTTPServer.Response(status: 201)
        }
        guard let source = try await item(path) else { return .text(404) }
        let existing = try await item(target)
        let isNew: Bool = if case .none = existing { true } else { false }
        if !isNew, !overwrite { return .text(412) }
        try await withSession { session in
            if case .file(let old)? = existing { try await session.delete(old.ref) }
            guard let entry = try await session.stat(RemotePath(path), storage: storageID) else { throw DeviceError.notFound(RemotePath(path)) }
            try await session.rename(entry.ref, to: (target as NSString).lastPathComponent)
        }
        _ = source
        ours.remove(path)
        ours.insert(target)
        forget(parent.isEmpty ? "/" : parent)
        return HTTPServer.Response(status: isNew ? 201 : 204)
    }

    // MARK: Locks (Finder writes only to servers that accept them)

    private func lock(_ rawPath: String) -> HTTPServer.Response {
        let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>\
        <D:depth>0</D:depth><D:timeout>Second-600</D:timeout><D:locktoken><D:href>\(token)</D:href></D:locktoken>\
        <D:lockroot><D:href>\(Self.xml(rawPath))</D:href></D:lockroot></D:activelock></D:lockdiscovery></D:prop>
        """
        return HTTPServer.Response(status: 200, headers: [("Content-Type", "application/xml; charset=utf-8"), ("Lock-Token", "<\(token)>")],
                                   body: .data(Data(body.utf8)))
    }

    private func proppatch(_ rawPath: String) -> HTTPServer.Response {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(Self.xml(rawPath))</D:href><D:propstat><D:prop/>\
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """
        return HTTPServer.Response(status: 207, headers: [("Content-Type", "application/xml; charset=utf-8")], body: .data(Data(body.utf8)))
    }
}

