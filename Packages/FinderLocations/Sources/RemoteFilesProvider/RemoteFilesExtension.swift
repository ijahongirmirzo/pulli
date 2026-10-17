public import FileProvider
public import Foundation
public import RemoteFiles
import Synchronization
import UniformTypeIdentifiers

/// Reusable base class for an `NSFileProviderReplicatedExtension` backed by a `RemoteFileSource`.
open class RemoteFilesExtension: NSObject, NSFileProviderReplicatedExtension, @unchecked Sendable {
    /// The File Provider domain this extension instance serves.
    public let domain: NSFileProviderDomain

    /// Initialises the extension with the assigned domain.
    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    /// Factory method providing the remote file tree. Subclasses override to supply their source.
    open func makeSource() -> (any RemoteFileSource)? {
        nil
    }

    /// Whether this domain operates in read-only mode.
    open var readOnly: Bool {
        false
    }

    /// Display name of the root container shown in Finder.
    open var rootDisplayName: String {
        domain.displayName
    }

    // MARK: - NSFileProviderReplicatedExtension

    open func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest, completionHandler: @escaping ((any NSFileProviderItem)?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let complete = SingleCall(completionHandler)

        guard let path = RemoteProviderItem.path(for: identifier) else {
            complete((nil, NSFileProviderError(.noSuchItem)))
            return progress
        }
        guard let source = makeSource() else {
            complete((nil, NSFileProviderError(.serverUnreachable)))
            return progress
        }

        let readOnly = self.readOnly
        let displayName = self.rootDisplayName

        let task = Task {
            do {
                try Task.checkCancellation()
                let remoteItem = try await source.item(at: path)
                try Task.checkCancellation()
                let providerItem = RemoteProviderItem(item: remoteItem, readOnly: readOnly, displayName: displayName)
                progress.completedUnitCount = 1
                complete((providerItem, nil))
            } catch is CancellationError {
                complete((nil, CocoaError(.userCancelled)))
            } catch {
                complete((nil, mapFileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    open func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest, completionHandler: @escaping (URL?, (any NSFileProviderItem)?, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let complete = SingleCall(completionHandler)

        guard let path = RemoteProviderItem.path(for: itemIdentifier) else {
            complete((nil, nil, NSFileProviderError(.noSuchItem)))
            return progress
        }
        guard let source = makeSource() else {
            complete((nil, nil, NSFileProviderError(.serverUnreachable)))
            return progress
        }

        let tempDir = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString)
        let readOnly = self.readOnly
        let displayName = self.rootDisplayName

        let task = Task {
            do {
                try Task.checkCancellation()
                let remoteItem = try await source.download(path, to: tempURL) { done, total in
                    if let total {
                        progress.totalUnitCount = total
                    }
                    progress.completedUnitCount = done
                }
                try Task.checkCancellation()
                let providerItem = RemoteProviderItem(item: remoteItem, readOnly: readOnly, displayName: displayName)
                complete((tempURL, providerItem, nil))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: tempURL)
                complete((nil, nil, CocoaError(.userCancelled)))
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                complete((nil, nil, mapFileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    open func createItem(basedOn itemTemplate: any NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?, options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let complete = SingleCall(completionHandler)

        guard let parentPath = RemoteProviderItem.path(for: itemTemplate.parentItemIdentifier) else {
            complete((nil, [], false, NSFileProviderError(.noSuchItem)))
            return progress
        }
        guard let source = makeSource() else {
            complete((nil, [], false, NSFileProviderError(.serverUnreachable)))
            return progress
        }

        let targetPath = RemotePath.join(parentPath, itemTemplate.filename)
        let isFolder = itemTemplate.contentType == .folder || (itemTemplate.contentType?.conforms(to: .folder) ?? false)
        let readOnly = self.readOnly
        let displayName = self.rootDisplayName

        let task = Task {
            do {
                try Task.checkCancellation()
                let createdItem: RemoteItem
                if isFolder {
                    createdItem = try await source.makeFolder(targetPath)
                } else if let url {
                    createdItem = try await source.upload(url, to: targetPath)
                } else {
                    let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(".empty-\(UUID().uuidString)")
                    FileManager.default.createFile(atPath: emptyURL.path, contents: nil)
                    defer { try? FileManager.default.removeItem(at: emptyURL) }
                    createdItem = try await source.upload(emptyURL, to: targetPath)
                }
                try Task.checkCancellation()
                let providerItem = RemoteProviderItem(item: createdItem, readOnly: readOnly, displayName: displayName)
                progress.completedUnitCount = 1
                complete((providerItem, [], false, nil))
            } catch is CancellationError {
                complete((nil, [], false, CocoaError(.userCancelled)))
            } catch {
                complete((nil, [], false, mapFileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    open func modifyItem(_ item: any NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields, contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping ((any NSFileProviderItem)?, NSFileProviderItemFields, Bool, (any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let complete = SingleCall(completionHandler)

        guard let oldPath = RemoteProviderItem.path(for: item.itemIdentifier) else {
            complete((nil, [], false, NSFileProviderError(.noSuchItem)))
            return progress
        }
        guard let newParentPath = RemoteProviderItem.path(for: item.parentItemIdentifier) else {
            complete((nil, [], false, NSFileProviderError(.noSuchItem)))
            return progress
        }
        guard let source = makeSource() else {
            complete((nil, [], false, NSFileProviderError(.serverUnreachable)))
            return progress
        }

        let targetPath = RemotePath.join(newParentPath, item.filename)
        let readOnly = self.readOnly
        let displayName = self.rootDisplayName

        let task = Task {
            do {
                try Task.checkCancellation()
                var currentPath = oldPath
                var currentItem: RemoteItem?

                if oldPath != targetPath {
                    currentItem = try await source.move(oldPath, to: targetPath)
                    currentPath = targetPath
                }
                try Task.checkCancellation()
                if changedFields.contains(.contents), let newContents {
                    currentItem = try await source.upload(newContents, to: currentPath)
                }
                try Task.checkCancellation()
                let finalItem: RemoteItem
                if let currentItem {
                    finalItem = currentItem
                } else {
                    finalItem = try await source.item(at: currentPath)
                }
                let providerItem = RemoteProviderItem(item: finalItem, readOnly: readOnly, displayName: displayName)
                progress.completedUnitCount = 1
                complete((providerItem, [], false, nil))
            } catch is CancellationError {
                complete((nil, [], false, CocoaError(.userCancelled)))
            } catch {
                complete((nil, [], false, mapFileProviderError(error)))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    open func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion, options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest, completionHandler: @escaping ((any Error)?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let complete = SingleCall(completionHandler)

        guard let path = RemoteProviderItem.path(for: identifier) else {
            complete(NSFileProviderError(.noSuchItem))
            return progress
        }
        guard let source = makeSource() else {
            complete(NSFileProviderError(.serverUnreachable))
            return progress
        }

        let task = Task {
            do {
                try Task.checkCancellation()
                try await source.delete(path)
                progress.completedUnitCount = 1
                complete(nil)
            } catch is CancellationError {
                complete(CocoaError(.userCancelled))
            } catch {
                complete(mapFileProviderError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    open func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> any NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet {
            return RemoteEnumerator(path: nil, isWorkingSet: true, source: makeSource(), readOnly: readOnly, displayName: rootDisplayName)
        }
        if containerItemIdentifier == .trashContainer {
            // Sources here have no trash: an empty one, so the system stops retrying a missing one
            // (it asked again every few seconds and logged an error each time).
            return RemoteEnumerator(path: nil, isWorkingSet: true, source: makeSource(), readOnly: readOnly, displayName: rootDisplayName)
        }
        guard let path = RemoteProviderItem.path(for: containerItemIdentifier) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return RemoteEnumerator(path: path, isWorkingSet: false, source: makeSource(), readOnly: readOnly, displayName: rootDisplayName)
    }

    open func invalidate() {}
}

// MARK: - Error Mapping

/// Maps `RemoteFileError` instances into FileProvider or Cocoa errors.
public func mapFileProviderError(_ error: any Error) -> any Error {
    if let remoteError = error as? RemoteFileError {
        switch remoteError {
        case .notFound:
            return NSFileProviderError(.noSuchItem)
        case .unavailable:
            return NSFileProviderError(.serverUnreachable)
        case .insufficientSpace:
            return NSFileProviderError(.insufficientQuota)
        case .exists:
            return NSFileProviderError(.filenameCollision)
        case .notAllowed(let reason):
            return CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: reason])
        case .server:
            return NSFileProviderError(.cannotSynchronize)
        }
    }
    if let providerError = error as? NSFileProviderError {
        return providerError
    }
    if let cocoaError = error as? CocoaError {
        return cocoaError
    }
    return NSFileProviderError(.cannotSynchronize)
}

// MARK: - SingleCall Helper

/// Ensures a completion block is invoked at most once, and thread-safely.
final class SingleCall<Args>: @unchecked Sendable {
    private var handler: ((Args) -> Void)?
    // NSLock, not os_unfair_lock: a lock stored in a Swift property has no stable address.
    private let lock = NSLock()

    init(_ handler: @escaping (Args) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ args: Args) {
        let fn = lock.withLock {
            defer { handler = nil }
            return handler
        }
        fn?(args)
    }
}
