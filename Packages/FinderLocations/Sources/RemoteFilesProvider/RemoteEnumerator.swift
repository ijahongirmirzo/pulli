public import FileProvider
import Foundation
public import RemoteFiles
import Synchronization

/// An enumerator that lists folder contents or changes from a `RemoteFileSource`.
public final class RemoteEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    /// The folder path being enumerated, or `nil` for special containers like the working set.
    public let path: String?

    /// Whether this enumerator represents the working set container.
    public let isWorkingSet: Bool

    /// The remote file source providing items.
    public let source: (any RemoteFileSource)?

    /// Whether items should be presented as read-only.
    public let readOnly: Bool

    /// The display name for the root container.
    public let displayName: String

    private let cachedListing = Mutex<Set<String>>([])

    /// Initialises an enumerator for a given folder path or working set.
    public init(path: String?, isWorkingSet: Bool = false, source: (any RemoteFileSource)?, readOnly: Bool = false, displayName: String = "") {
        self.path = path
        self.isWorkingSet = isWorkingSet
        self.source = source
        self.readOnly = readOnly
        self.displayName = displayName
        super.init()
    }

    public func invalidate() {}

    /// Generates a sync anchor using the current millisecond timestamp in UTF-8 bytes.
    public static func makeAnchor() -> NSFileProviderSyncAnchor {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return NSFileProviderSyncAnchor(Data("\(ms)".utf8))
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(Self.makeAnchor())
    }

    public func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        if isWorkingSet {
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }

        guard let path else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }

        guard let source else {
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }

        let offset: Int
        if (page.rawValue as NSData) == NSFileProviderPage.initialPageSortedByName || (page.rawValue as NSData) == NSFileProviderPage.initialPageSortedByDate {
            offset = 0
        } else {
            offset = Int(String(decoding: page.rawValue, as: UTF8.self)) ?? 0
        }

        let observerBox = UncheckedBox(observer)
        Task {
            let obs = observerBox.value
            do {
                let items = try await source.list(path)
                let itemPaths = Set(items.map(\.path))
                self.cachedListing.withLock { $0 = itemPaths }

                let pageSize = 500
                let pageItems = items.dropFirst(offset).prefix(pageSize)
                let providerItems = pageItems.map {
                    RemoteProviderItem(item: $0, readOnly: self.readOnly, displayName: self.displayName)
                }

                obs.didEnumerate(providerItems)
                if offset + pageItems.count < items.count {
                    let nextPage = NSFileProviderPage(Data("\(offset + pageItems.count)".utf8))
                    obs.finishEnumerating(upTo: nextPage)
                } else {
                    obs.finishEnumerating(upTo: nil)
                }
            } catch {
                obs.finishEnumeratingWithError(mapFileProviderError(error))
            }
        }
    }

    public func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        if isWorkingSet {
            observer.finishEnumeratingChanges(upTo: Self.makeAnchor(), moreComing: false)
            return
        }

        guard let path else {
            observer.finishEnumeratingWithError(NSFileProviderError(.noSuchItem))
            return
        }

        guard let source else {
            observer.finishEnumeratingWithError(NSFileProviderError(.serverUnreachable))
            return
        }

        let observerBox = UncheckedBox(observer)
        Task {
            let obs = observerBox.value
            do {
                let currentItems = try await source.list(path)
                let currentPaths = Set(currentItems.map(\.path))

                let previousPaths = self.cachedListing.withLock { listing -> Set<String> in
                    let old = listing
                    listing = currentPaths
                    return old
                }

                let updatedProviderItems = currentItems.map {
                    RemoteProviderItem(item: $0, readOnly: self.readOnly, displayName: self.displayName)
                }
                obs.didUpdate(updatedProviderItems)

                let deletedPaths = previousPaths.subtracting(currentPaths)
                let deletedIdentifiers = deletedPaths.map {
                    RemoteProviderItem.identifier(for: $0)
                }
                if !deletedIdentifiers.isEmpty {
                    obs.didDeleteItems(withIdentifiers: deletedIdentifiers)
                }

                obs.finishEnumeratingChanges(upTo: Self.makeAnchor(), moreComing: false)
            } catch {
                obs.finishEnumeratingWithError(mapFileProviderError(error))
            }
        }
    }
}

private final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}
