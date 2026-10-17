public import FileProvider
public import Foundation
public import RemoteFiles
public import UniformTypeIdentifiers

/// Adapts a `RemoteItem` into an `NSFileProviderItem` for the macOS File Provider system.
public final class RemoteProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    /// The underlying remote item.
    public let item: RemoteItem

    /// Whether this item belongs to a read-only domain.
    public let readOnly: Bool

    /// Display name used for the root container.
    public let displayName: String

    /// Initialises a provider item from a `RemoteItem`.
    public init(item: RemoteItem, readOnly: Bool = false, displayName: String = "") {
        self.item = item
        self.readOnly = readOnly
        self.displayName = displayName
        super.init()
    }

    /// Converts an `NSFileProviderItemIdentifier` back to a remote path, or `nil` for working set or trash.
    public static func path(for identifier: NSFileProviderItemIdentifier) -> String? {
        if identifier == .rootContainer {
            return RemotePath.root
        }
        if identifier == .workingSet || identifier == .trashContainer {
            return nil
        }
        let raw = identifier.rawValue
        guard raw.hasPrefix("/") else { return nil }
        return RemotePath.normalize(raw)
    }

    /// Converts a remote path to an `NSFileProviderItemIdentifier`.
    public static func identifier(for path: String) -> NSFileProviderItemIdentifier {
        let normalized = RemotePath.normalize(path)
        if normalized == RemotePath.root {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(normalized)
    }

    // MARK: NSFileProviderItem

    public var itemIdentifier: NSFileProviderItemIdentifier {
        Self.identifier(for: item.path)
    }

    public var parentItemIdentifier: NSFileProviderItemIdentifier {
        if item.path == RemotePath.root {
            return .rootContainer
        }
        let parent = item.parentPath
        return parent == RemotePath.root ? .rootContainer : Self.identifier(for: parent)
    }

    public var filename: String {
        if item.path == RemotePath.root {
            return displayName.isEmpty ? "/" : displayName
        }
        return item.name
    }

    public var contentType: UTType {
        if item.isFolder {
            return .folder
        }
        let ext = (item.name as NSString).pathExtension
        if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
            return ut
        }
        if let mime = item.contentType, let ut = UTType(mimeType: mime) {
            return ut
        }
        return .data
    }

    public var documentSize: NSNumber? {
        guard !item.isFolder, let size = item.size else { return nil }
        return NSNumber(value: size)
    }

    public var contentModificationDate: Date? {
        item.modified
    }

    public var creationDate: Date? {
        item.created
    }

    public var itemVersion: NSFileProviderItemVersion {
        let ver = item.version ?? ""
        let contentData = Data(ver.utf8)
        let metaData = Data((ver + item.name).utf8)
        return NSFileProviderItemVersion(contentVersion: contentData, metadataVersion: metaData)
    }

    public var capabilities: NSFileProviderItemCapabilities {
        var caps: NSFileProviderItemCapabilities = [.allowsReading, .allowsContentEnumerating]
        if !readOnly {
            caps.insert([.allowsWriting, .allowsAddingSubItems, .allowsRenaming, .allowsReparenting, .allowsDeleting])
        }
        return caps
    }
}
