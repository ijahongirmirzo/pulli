import FileProvider
import Foundation
import RemoteFiles
import RemoteFilesProvider
import Testing
import UniformTypeIdentifiers

@Suite struct RemoteFilesUnitTests {
    @Test func parsesMultistatusXML() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>http://127.0.0.1:52011/abc123/myGalaxy/DCIM/Camera/photo.jpg</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>photo.jpg</D:displayname>
                <D:resourcetype/>
                <D:getcontentlength>12345</D:getcontentlength>
                <D:getcontenttype>image/jpeg</D:getcontenttype>
                <D:getetag>"etag-12345"</D:getetag>
                <D:getlastmodified>Mon, 01 Jan 2024 12:00:00 GMT</D:getlastmodified>
                <D:creationdate>2024-01-01T12:00:00Z</D:creationdate>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/abc123/myGalaxy/My%20Documents/Trip%20Plan.pdf</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>Trip Plan.pdf</D:displayname>
                <D:resourcetype/>
                <D:getcontentlength>67890</D:getcontentlength>
                <D:getcontenttype>application/pdf</D:getcontenttype>
                <D:getetag>W/"weak-etag-67890"</D:getetag>
                <D:getlastmodified>Tue, 02 Jan 2024 15:30:00 GMT</D:getlastmodified>
                <D:creationdate>2024-01-02T15:30:00Z</D:creationdate>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/abc123/myGalaxy/Music/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>Music</D:displayname>
                <D:resourcetype><D:collection/></D:resourcetype>
                <D:getlastmodified>Wed, 03 Jan 2024 09:00:00 GMT</D:getlastmodified>
                <D:creationdate>2024-01-03T09:00:00Z</D:creationdate>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """

        let baseURL = URL(string: "http://127.0.0.1:52011/abc123/myGalaxy/")!
        let items = try WebDAVSource.parseMultistatus(Data(xml.utf8), baseURL: baseURL)

        #expect(items.count == 3)

        // 1. Absolute-URL href
        let photo = items[0]
        #expect(photo.path == "/DCIM/Camera/photo.jpg")
        #expect(photo.name == "photo.jpg")
        #expect(photo.parentPath == "/DCIM/Camera")
        #expect(photo.isFolder == false)
        #expect(photo.size == 12345)
        #expect(photo.contentType == "image/jpeg")
        #expect(photo.version == "etag-12345")
        #expect(photo.modified != nil)
        #expect(photo.created != nil)

        // 2. Percent-encoded name with space
        let doc = items[1]
        #expect(doc.path == "/My Documents/Trip Plan.pdf")
        #expect(doc.name == "Trip Plan.pdf")
        #expect(doc.parentPath == "/My Documents")
        #expect(doc.isFolder == false)
        #expect(doc.size == 67890)
        #expect(doc.contentType == "application/pdf")
        #expect(doc.version == "weak-etag-67890")

        // 3. Collection
        let music = items[2]
        #expect(music.path == "/Music")
        #expect(music.name == "Music")
        #expect(music.parentPath == "/")
        #expect(music.isFolder == true)
        #expect(music.size == nil)
        #expect(music.contentType == nil)
    }

    @Test func mapsPathToAndFromIdentifier() {
        #expect(RemoteProviderItem.identifier(for: "/") == .rootContainer)
        #expect(RemoteProviderItem.path(for: .rootContainer) == "/")

        let photoPath = "/DCIM/Camera/a.jpg"
        let photoId = RemoteProviderItem.identifier(for: photoPath)
        #expect(photoId.rawValue == photoPath)
        #expect(RemoteProviderItem.path(for: photoId) == photoPath)

        #expect(RemoteProviderItem.path(for: .workingSet) == nil)
        #expect(RemoteProviderItem.path(for: .trashContainer) == nil)
        #expect(RemoteProviderItem.path(for: NSFileProviderItemIdentifier("relative/path")) == nil)
    }

    @Test func remoteProviderItemFieldsAndCapabilities() {
        let modified = Date(timeIntervalSince1970: 1700000000)
        let created = Date(timeIntervalSince1970: 1690000000)
        let file = RemoteItem(
            path: "/Photos/beach.jpeg",
            isFolder: false,
            size: 4567,
            modified: modified,
            created: created,
            contentType: "image/jpeg",
            version: "etag123"
        )

        // Read-write item
        let rw = RemoteProviderItem(item: file, readOnly: false)
        #expect(rw.itemIdentifier == NSFileProviderItemIdentifier("/Photos/beach.jpeg"))
        #expect(rw.parentItemIdentifier == NSFileProviderItemIdentifier("/Photos"))
        #expect(rw.filename == "beach.jpeg")
        #expect(rw.contentType == .jpeg)
        #expect(rw.documentSize == 4567)
        #expect(rw.contentModificationDate == modified)
        #expect(rw.creationDate == created)
        #expect(rw.itemVersion.contentVersion == Data("etag123".utf8))
        #expect(rw.itemVersion.metadataVersion == Data("etag123beach.jpeg".utf8))

        #expect(rw.capabilities.contains(.allowsReading))
        #expect(rw.capabilities.contains(.allowsContentEnumerating))
        #expect(rw.capabilities.contains(.allowsWriting))
        #expect(rw.capabilities.contains(.allowsAddingSubItems))
        #expect(rw.capabilities.contains(.allowsRenaming))
        #expect(rw.capabilities.contains(.allowsReparenting))
        #expect(rw.capabilities.contains(.allowsDeleting))

        // Read-only item
        let ro = RemoteProviderItem(item: file, readOnly: true)
        #expect(ro.capabilities.contains(.allowsReading))
        #expect(ro.capabilities.contains(.allowsContentEnumerating))
        #expect(!ro.capabilities.contains(.allowsWriting))
        #expect(!ro.capabilities.contains(.allowsAddingSubItems))
        #expect(!ro.capabilities.contains(.allowsRenaming))
        #expect(!ro.capabilities.contains(.allowsReparenting))
        #expect(!ro.capabilities.contains(.allowsDeleting))

        // Root item
        let root = RemoteItem(path: "/", isFolder: true)
        let providerRoot = RemoteProviderItem(item: root, readOnly: false, displayName: "My Galaxy")
        #expect(providerRoot.itemIdentifier == .rootContainer)
        #expect(providerRoot.parentItemIdentifier == .rootContainer)
        #expect(providerRoot.filename == "My Galaxy")
        #expect(providerRoot.contentType == .folder)
        #expect(providerRoot.documentSize == nil)
        #expect(providerRoot.contentModificationDate == nil)
        #expect(providerRoot.creationDate == nil)

        // Item with epoch dates: treated as unknown (nil)
        let epochItem = RemoteItem(
            path: "/Photos/undated.jpeg",
            isFolder: false,
            modified: Date(timeIntervalSince1970: 0),
            created: Date(timeIntervalSince1970: 0)
        )
        let providerEpoch = RemoteProviderItem(item: epochItem)
        #expect(providerEpoch.contentModificationDate == nil)
        #expect(providerEpoch.creationDate == nil)
    }

    @Test func parsesUndatedAndEpochMultistatusItems() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:multistatus xmlns:D="DAV:">
          <D:response>
            <D:href>/abc123/myGalaxy/EmptyFolder/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>EmptyFolder</D:displayname>
                <D:resourcetype><D:collection/></D:resourcetype>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
          <D:response>
            <D:href>/abc123/myGalaxy/EpochFolder/</D:href>
            <D:propstat>
              <D:prop>
                <D:displayname>EpochFolder</D:displayname>
                <D:resourcetype><D:collection/></D:resourcetype>
                <D:getlastmodified>Thu, 01 Jan 1970 00:00:00 GMT</D:getlastmodified>
                <D:creationdate>1970-01-01T00:00:00Z</D:creationdate>
              </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>
        </D:multistatus>
        """
        let baseURL = URL(string: "http://127.0.0.1:52011/abc123/myGalaxy/")!
        let items = try WebDAVSource.parseMultistatus(Data(xml.utf8), baseURL: baseURL)
        #expect(items.count == 2)
        #expect(items[0].modified == nil)
        #expect(items[0].created == nil)
        #expect(items[1].modified == nil)
        #expect(items[1].created == nil)

        let p0 = RemoteProviderItem(item: items[0])
        #expect(p0.contentModificationDate == nil)
        #expect(p0.creationDate == nil)
        let p1 = RemoteProviderItem(item: items[1])
        #expect(p1.contentModificationDate == nil)
        #expect(p1.creationDate == nil)
    }

    @Test func mapsFileProviderErrors() {
        let notFound = mapFileProviderError(RemoteFileError.notFound("/missing"))
        #expect((notFound as? NSFileProviderError)?.code == .noSuchItem)

        let unavailable = mapFileProviderError(RemoteFileError.unavailable("connection lost"))
        #expect((unavailable as? NSFileProviderError)?.code == .serverUnreachable)

        let insufficient = mapFileProviderError(RemoteFileError.insufficientSpace)
        #expect((insufficient as? NSFileProviderError)?.code == .insufficientQuota)

        let exists = mapFileProviderError(RemoteFileError.exists("/already_there"))
        #expect((exists as? NSFileProviderError)?.code == .filenameCollision)

        let notAllowed = mapFileProviderError(RemoteFileError.notAllowed("Deleting disabled"))
        let cocoa = notAllowed as? CocoaError
        #expect(cocoa?.code == .fileWriteNoPermission)
        #expect(cocoa?.userInfo[NSLocalizedDescriptionKey] as? String == "Deleting disabled")

        let server = mapFileProviderError(RemoteFileError.server(500, "Internal Server Error"))
        #expect((server as? NSFileProviderError)?.code == .cannotSynchronize)

        let generic = mapFileProviderError(URLError(.badURL))
        #expect((generic as? NSFileProviderError)?.code == .cannotSynchronize)
    }

    @Test func domainStoreRoundTripsSettings() {
        let suite = "test.suite.\(UUID().uuidString)"
        let store = RemoteFilesDomainStore(suiteName: suite)
        let settings = RemoteFilesDomainSettings(
            baseURL: URL(string: "http://127.0.0.1:52011/abc/phone/")!,
            readOnly: false,
            displayName: "Test Phone"
        )

        let domainID = "domain-123"
        #expect(store.settings(for: domainID) == nil)

        store.set(settings, for: domainID)
        #expect(store.settings(for: domainID) == settings)

        store.remove(domainID)
        #expect(store.settings(for: domainID) == nil)
    }
}
