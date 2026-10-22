public import Foundation

// A remote file tree (a device, a server) as plain values and one protocol: the reusable core
// behind a Finder location, kept generic so any application can use it as is.

/// A file or folder on the remote side. Paths are absolute, "/" separated, with no trailing
/// slash; the root is "/".
public struct RemoteItem: Sendable, Hashable, Codable {
    public var path: String
    public var isFolder: Bool
    /// Bytes; nil for folders and unknown sizes.
    public var size: Int64?
    public var modified: Date?
    public var created: Date?
    /// MIME type when the source knows it ("image/jpeg").
    public var contentType: String?
    /// Changes whenever the content changes (an ETag, or size and date): what tells a cache
    /// its copy is stale.
    public var version: String?

    /// Dates before 1990 are treated as unknown, so Finder shows "--" instead of 1 January 1970.
    public static let earliestRealDate = Date(timeIntervalSince1970: 631_152_000)

    public init(path: String, isFolder: Bool, size: Int64? = nil, modified: Date? = nil, created: Date? = nil,
                contentType: String? = nil, version: String? = nil) {
        self.path = path
        self.isFolder = isFolder
        self.size = size
        self.modified = modified
        self.created = created
        self.contentType = contentType
        self.version = version
    }

    /// The last path component ("" for the root).
    public var name: String { path == "/" ? "" : String(path.split(separator: "/").last ?? "") }

    /// The folder holding this item ("/" for the root's children and the root itself).
    public var parentPath: String { RemotePath.parent(of: path) }
}

public enum RemotePath {
    public static let root = "/"

    /// "/a/b" from "/a/b/", "a/b", "//a//b".
    public static func normalize(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.joined(separator: "/")
    }

    public static func parent(of path: String) -> String {
        let parts = normalize(path).split(separator: "/")
        return parts.count <= 1 ? root : "/" + parts.dropLast().joined(separator: "/")
    }

    public static func join(_ folder: String, _ name: String) -> String {
        normalize(normalize(folder) + "/" + name)
    }
}

public enum RemoteFileError: Error, Sendable, Equatable {
    case notFound(String)
    /// The source refuses (deleting turned off, a read-only folder): the reason, for people.
    case notAllowed(String)
    /// The source cannot be reached right now (the phone unplugged, the server gone).
    case unavailable(String)
    /// Something is already there.
    case exists(String)
    case insufficientSpace
    /// Anything else the server said (HTTP status and text).
    case server(Int, String)
}

/// A remote file tree. Every call may take a while (a phone over USB, a server over Wi-Fi) and
/// may throw `RemoteFileError`.
public protocol RemoteFileSource: Sendable {
    func item(at path: String) async throws -> RemoteItem
    /// The folder's direct children.
    func list(_ folder: String) async throws -> [RemoteItem]
    /// Downloads the whole file to `destination` (created or replaced). `progress` gets bytes
    /// done and the total when known.
    func download(_ path: String, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> RemoteItem
    /// Uploads a local file to `path`, replacing what is there.
    func upload(_ source: URL, to path: String) async throws -> RemoteItem
    func makeFolder(_ path: String) async throws -> RemoteItem
    func delete(_ path: String) async throws
    /// Renames or moves within the source.
    func move(_ path: String, to destination: String) async throws -> RemoteItem
}
