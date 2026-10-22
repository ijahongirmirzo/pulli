public import DeviceAPI
public import Foundation

/// One file in ImageCaptureCore's flat catalogue, reduced to what the folder synthesis needs.
public struct ICCCatalogueItem: Sendable, Hashable {
    /// Stable for the session: the same item keeps its ID when the catalogue changes.
    public var id: Int
    /// The folders and name Image Capture reports (`["DCIM", "Camera", "IMG_0001.jpg"]`).
    public var components: [String]
    public var size: UInt64
    /// The phone's wall-clock modification time, encoded as if it were UTC (D-005).
    public var modifiedWallClock: Int64

    public init(id: Int, components: [String], size: UInt64, modifiedWallClock: Int64) {
        self.id = id
        self.components = components
        self.size = size
        self.modifiedWallClock = modifiedWallClock
    }

    /// The wall clock the engine stores for a date Image Capture gives as an absolute time.
    ///
    /// Image Capture parses the phone's local "YYYYMMDDThhmmss" into a `Date` in the Mac's time
    /// zone, so adding that zone's offset back recovers the time the phone showed, the same
    /// number libmtp gives for the same file. `timeZone` must be the Mac's real zone (pulli-cli
    /// switches the process to UTC for libmtp).
    public static func wallClock(_ date: Date?, timeZone: TimeZone) -> Int64 {
        guard let date else { return 0 }
        return Int64(date.timeIntervalSince1970.rounded(.down)) + Int64(timeZone.secondsFromGMT(for: date))
    }
}

/// Folders synthesised from the flat catalogue: Image Capture hands over one list of files, each
/// knowing its folder path, while the engine browses and copies folder by folder.
///
/// Pure, so it can be tested without a phone. Names are compared byte for byte (`ExactName`), as
/// everywhere else. Two items at the same path (a phone's internal storage and SD card can both
/// have `DCIM/Camera/IMG_0001.jpg`), or a file named like a folder, keep both: later ones in
/// catalogue order get " (2)", " (3)" … before the extension, so every item stays reachable and,
/// since the phone lists in the same order every session, keeps its path between sessions.
public struct ICCFolderIndex: Sendable {
    public struct Entry: Sendable, Hashable {
        public var name: String
        /// Nil for a folder.
        public var itemID: Int?

        public var isFolder: Bool { itemID == nil }
    }

    public enum Node: Sendable, Hashable {
        case folder
        case file(itemID: Int)
    }

    /// Children of every folder, the root included, sorted: folders first, then files, each by
    /// name as Finder sorts ("IMG_2" before "IMG_10").
    public private(set) var folders: [RemotePath: [Entry]] = [.root: []]
    /// The newest modification date of anything inside each folder (recursively), or 0 if undated.
    public private(set) var folderModified: [RemotePath: Int64] = [:]
    /// Where each item ended up, after any renaming for duplicates.
    public private(set) var paths: [Int: RemotePath] = [:]
    public private(set) var items: [Int: ICCCatalogueItem] = [:]
    /// Every path, for `stat` without scanning a folder of thousands of photos.
    private var nodes: [RemotePath: Node] = [.root: .folder]

    public init(_ catalogue: [ICCCatalogueItem]) {
        var children: [RemotePath: [ExactName: Entry]] = [.root: [:]]
        let cleaned = catalogue.map { item -> (ICCCatalogueItem, [String]) in
            var parts = item.components.filter { !$0.isEmpty }.map(Self.safeName)
            if parts.isEmpty { parts = ["Untitled"] }
            return (item, parts)
        }

        // Folders first, so a folder keeps its name when a file elsewhere in the list shares it.
        for (_, parts) in cleaned {
            var parent = RemotePath.root
            for name in parts.dropLast() {
                children[parent, default: [:]][ExactName(name)] = Entry(name: name, itemID: nil)
                parent = parent.appending(name)
                nodes[parent] = .folder
                if children[parent] == nil { children[parent] = [:] }
            }
        }
        for (item, parts) in cleaned {
            let parent = RemotePath(components: Array(parts.dropLast()))
            var name = parts.last!
            var copy = 2
            while children[parent]?[ExactName(name)] != nil {
                name = Self.numbered(parts.last!, copy)
                copy += 1
            }
            children[parent, default: [:]][ExactName(name)] = Entry(name: name, itemID: item.id)
            paths[item.id] = parent.appending(name)
            nodes[parent.appending(name)] = .file(itemID: item.id)
            items[item.id] = item
        }
        folders = children.mapValues { $0.values.sorted(by: Self.order) }

        var folderMax: [RemotePath: Int64] = [:]
        for (item, parts) in cleaned {
            guard item.modifiedWallClock > 0 else { continue }
            var current = RemotePath(components: Array(parts.dropLast()))
            while true {
                folderMax[current] = max(folderMax[current] ?? 0, item.modifiedWallClock)
                if current.isRoot { break }
                current = current.parent
            }
        }
        folderModified = folderMax
    }

    public var isEmpty: Bool { items.isEmpty }

    /// The newest modification date of anything inside the folder, or 0 if undated.
    public func modifiedWallClock(for folder: RemotePath) -> Int64 {
        folderModified[folder] ?? 0
    }

    public func node(at path: RemotePath) -> Node? {
        nodes[path]
    }

    /// Folders first; then Finder's order; byte order only to keep equal-looking names stable.
    static func order(_ a: Entry, _ b: Entry) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a.name.utf8.lexicographicallyPrecedes(b.name.utf8)
        }
    }

    /// "IMG_0001.jpg" → "IMG_0001 (2).jpg"; a leading dot is part of the name, not an extension.
    static func numbered(_ name: String, _ copy: Int) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "\(name) (\(copy))" }
        return "\(name[..<dot]) (\(copy))\(name[dot...])"
    }

    /// A slash would split the name when the path is read back from the journal.
    static func safeName(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "_")
    }
}
