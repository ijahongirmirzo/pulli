import FileProvider
import Foundation
import RemoteFiles
import RemoteFilesProvider
import Synchronization
import Testing
import UniformTypeIdentifiers

private final class MockSource: RemoteFileSource, @unchecked Sendable {
    private let lock = Mutex<State>(State())

    struct State {
        var items: [String: RemoteItem] = [:]
        var deleted: [String] = []
        var moves: [(from: String, to: String)] = []
        var uploads: [(path: String, url: URL)] = []
        var makes: [String] = []
    }

    init() {
        lock.withLock { state in
            state.items["/"] = RemoteItem(path: "/", isFolder: true)
            state.items["/file.txt"] = RemoteItem(path: "/file.txt", isFolder: false, size: 10, version: "v1")
            state.items["/folder"] = RemoteItem(path: "/folder", isFolder: true)
        }
    }

    func item(at path: String) async throws -> RemoteItem {
        try lock.withLock { state in
            guard let item = state.items[path] else { throw RemoteFileError.notFound(path) }
            return item
        }
    }

    func list(_ folder: String) async throws -> [RemoteItem] {
        lock.withLock { state in
            state.items.values.filter { $0.path != folder && $0.parentPath == folder }
        }
    }

    func download(_ path: String, to destination: URL, progress: (@Sendable (Int64, Int64?) -> Void)? = nil) async throws -> RemoteItem {
        let item = try await self.item(at: path)
        try Data("mock content".utf8).write(to: destination)
        progress?(12, 12)
        return item
    }

    func upload(_ source: URL, to path: String) async throws -> RemoteItem {
        let item = RemoteItem(path: path, isFolder: false, size: 100, version: "new")
        lock.withLock { state in
            state.uploads.append((path, source))
            state.items[path] = item
        }
        return item
    }

    func makeFolder(_ path: String) async throws -> RemoteItem {
        let item = RemoteItem(path: path, isFolder: true)
        lock.withLock { state in
            state.makes.append(path)
            state.items[path] = item
        }
        return item
    }

    func delete(_ path: String) async throws {
        lock.withLock { state in
            state.deleted.append(path)
            state.items.removeValue(forKey: path)
        }
    }

    func move(_ path: String, to destination: String) async throws -> RemoteItem {
        try lock.withLock { state in
            guard let old = state.items.removeValue(forKey: path) else {
                throw RemoteFileError.notFound(path)
            }
            var updated = old
            updated.path = destination
            state.items[destination] = updated
            state.moves.append((path, destination))
            return updated
        }
    }
}

private final class TestExtension: RemoteFilesExtension, @unchecked Sendable {
    let mockSource: MockSource

    init(domain: NSFileProviderDomain, mockSource: MockSource) {
        self.mockSource = mockSource
        super.init(domain: domain)
    }

    required init(domain: NSFileProviderDomain) {
        self.mockSource = MockSource()
        super.init(domain: domain)
    }

    override func makeSource() -> (any RemoteFileSource)? {
        mockSource
    }

    override var rootDisplayName: String {
        "Test Extension"
    }
}

private final class DummyRequest: NSFileProviderRequest, @unchecked Sendable {}

private final class TestItemTemplate: NSObject, NSFileProviderItem, @unchecked Sendable {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType

    init(identifier: NSFileProviderItemIdentifier = NSFileProviderItemIdentifier(UUID().uuidString), parent: NSFileProviderItemIdentifier, filename: String, contentType: UTType) {
        self.itemIdentifier = identifier
        self.parentItemIdentifier = parent
        self.filename = filename
        self.contentType = contentType
        super.init()
    }
}

private final class ItemBox: @unchecked Sendable {
    let item: any NSFileProviderItem
    init(_ item: any NSFileProviderItem) {
        self.item = item
    }
}

private final class EnumerationObserver: NSObject, NSFileProviderEnumerationObserver, @unchecked Sendable {
    private let completion: (Result<[ItemBox], any Error>) -> Void
    private var accumulated: [ItemBox] = []

    init(completion: @escaping (Result<[ItemBox], any Error>) -> Void) {
        self.completion = completion
    }

    func didEnumerate(_ items: [any NSFileProviderItem]) {
        accumulated.append(contentsOf: items.map(ItemBox.init))
    }

    func finishEnumerating(upTo nextPage: NSFileProviderPage?) {
        completion(.success(accumulated))
    }

    func finishEnumeratingWithError(_ error: any Error) {
        completion(.failure(error))
    }
}

@Suite struct RemoteProviderExtensionTests {
    @Test func fetchesItemMetadata() async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test.domain"), displayName: "Test Domain")
        let source = MockSource()
        let ext = TestExtension(domain: domain, mockSource: source)
        let req = DummyRequest()

        let itemResult = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ItemBox, any Error>) in
            _ = ext.item(for: NSFileProviderItemIdentifier("/file.txt"), request: req) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: ItemBox(item))
                }
            }
        }

        #expect(itemResult.item.filename == "file.txt")
        #expect(itemResult.item.documentSize == 10)
    }

    @Test func createsFolderAndFile() async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test.domain"), displayName: "Test Domain")
        let source = MockSource()
        let ext = TestExtension(domain: domain, mockSource: source)
        let req = DummyRequest()

        // Create folder
        let folderTemplate = TestItemTemplate(parent: .rootContainer, filename: "NewFolder", contentType: .folder)
        let createdFolder = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ItemBox, any Error>) in
            _ = ext.createItem(basedOn: folderTemplate, fields: [], contents: nil, options: [], request: req) { item, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: ItemBox(item))
                }
            }
        }
        #expect(createdFolder.item.filename == "NewFolder")
        #expect(createdFolder.item.contentType == .folder)

        // Create file
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).txt")
        try Data("new content".utf8).write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let fileTemplate = TestItemTemplate(parent: .rootContainer, filename: "uploaded.txt", contentType: .plainText)
        let createdFile = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ItemBox, any Error>) in
            _ = ext.createItem(basedOn: fileTemplate, fields: [], contents: tempFile, options: [], request: req) { item, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: ItemBox(item))
                }
            }
        }
        #expect(createdFile.item.filename == "uploaded.txt")
        #expect(createdFile.item.documentSize == 100)
    }

    @Test func modifiesAndDeletesItem() async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test.domain"), displayName: "Test Domain")
        let source = MockSource()
        let ext = TestExtension(domain: domain, mockSource: source)
        let req = DummyRequest()

        // Modify: rename /file.txt to /moved_file.txt
        let modifiedTemplate = TestItemTemplate(identifier: NSFileProviderItemIdentifier("/file.txt"), parent: .rootContainer, filename: "moved_file.txt", contentType: .plainText)
        let movedItem = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ItemBox, any Error>) in
            let version = NSFileProviderItemVersion(contentVersion: Data("v1".utf8), metadataVersion: Data("v1file.txt".utf8))
            _ = ext.modifyItem(modifiedTemplate, baseVersion: version, changedFields: [.filename], contents: nil, options: [], request: req) { item, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: ItemBox(item))
                }
            }
        }
        #expect(movedItem.item.filename == "moved_file.txt")

        // Delete
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let version = NSFileProviderItemVersion(contentVersion: Data("v1".utf8), metadataVersion: Data("v1file.txt".utf8))
            _ = ext.deleteItem(identifier: NSFileProviderItemIdentifier("/moved_file.txt"), baseVersion: version, options: [], request: req) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        await #expect(throws: RemoteFileError.notFound("/moved_file.txt")) {
            try await source.item(at: "/moved_file.txt")
        }
    }

    @Test func enumeratorListsAndHandlesWorkingSet() async throws {
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("test.domain"), displayName: "Test Domain")
        let source = MockSource()
        let ext = TestExtension(domain: domain, mockSource: source)
        let req = DummyRequest()

        // Working set returns empty enumeration
        let wsEnum = try ext.enumerator(for: .workingSet, request: req)
        let wsItems = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ItemBox], any Error>) in
            let obs = EnumerationObserver { result in
                continuation.resume(with: result)
            }
            wsEnum.enumerateItems(for: obs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        }
        #expect(wsItems.isEmpty)

        // Root folder returns children
        let rootEnum = try ext.enumerator(for: .rootContainer, request: req)
        let rootItems = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[ItemBox], any Error>) in
            let obs = EnumerationObserver { result in
                continuation.resume(with: result)
            }
            rootEnum.enumerateItems(for: obs, startingAt: NSFileProviderPage(NSFileProviderPage.initialPageSortedByName as Data))
        }
        #expect(rootItems.count == 2)
        #expect(rootItems.contains(where: { $0.item.filename == "file.txt" }))
        #expect(rootItems.contains(where: { $0.item.filename == "folder" }))
    }
}
