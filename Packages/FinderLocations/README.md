# FinderLocations

Show any remote file tree as a location in Finder's sidebar on macOS.

FinderLocations provides the building blocks to present remote file hierarchies (servers, network shares, attached devices) directly in Finder using Apple's replicated File Provider framework (`NSFileProviderReplicatedExtension`). Locations appear in Finder's sidebar under **Locations**, with user-configured display names, support for read-write or read-only modes, on-demand downloading, and full compatibility with system Open and Save panels. A WebDAV client implementation (`WebDAVSource`) is included out of the box.

## Architecture

The package is split into three library products:

- **`RemoteFiles`**: The core data types (`RemoteItem`, `RemotePath`, `RemoteFileError`), the `RemoteFileSource` protocol, the `WebDAVSource` client, and `RemoteFilesDomainStore` for persisting per-domain configuration across processes in a shared App Group.
- **`RemoteFilesProvider`**: The File Provider extension base class (`RemoteFilesExtension`), adapted items (`RemoteProviderItem`), and directory enumerator (`RemoteEnumerator`).
- **`FinderLocations`**: Application-side coordination (`FinderLocationManager`) to add, reset, and remove domains, inspect extension approval status, and perform health checks (`FinderLocationHealth`) to detect and recover from unresponsive `fileproviderd` domains.

## Requirements

- **macOS 15.0 or later**.
- **An App Group**: shared between your host application and your File Provider extension so the application can communicate domain endpoints and settings to the extension via `RemoteFilesDomainStore`.
- **A File Provider extension target**:
  - Extension point: `com.apple.fileprovider-nonui`
  - Linker flags: `-Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension`
  - Info.plist configuration:
    - `NSExtensionPointIdentifier`: `com.apple.fileprovider-nonui`
    - `NSExtensionPrincipalClass`: Your `RemoteFilesExtension` subclass name
    - `NSExtensionFileProviderDocumentGroup`: Your shared App Group identifier
    - `NSExtensionFileProviderSupportsEnumeration`: `true`
  - Entitlements:
    - `com.apple.security.app-sandbox`: `true`
    - `com.apple.security.application-groups`: Array containing your App Group
    - `com.apple.security.network.client`: `true` (if reaching network or localhost endpoints)

## Usage Example

### 1. File Provider Extension

Subclass `RemoteFilesExtension` in your extension target and override `makeSource()`:

```swift
import FileProvider
import Foundation
import RemoteFiles
import RemoteFilesProvider

@objc(ExampleFileProviderExtension)
final class ExampleFileProviderExtension: RemoteFilesExtension, @unchecked Sendable {
    static let appGroup = "group.com.example.remote-files"

    private var settings: RemoteFilesDomainSettings? {
        RemoteFilesDomainStore(suiteName: Self.appGroup).settings(for: domain.identifier.rawValue)
    }

    override func makeSource() -> (any RemoteFileSource)? {
        settings.map { WebDAVSource(baseURL: $0.baseURL) }
    }

    override var readOnly: Bool {
        settings?.readOnly ?? false
    }

    override var rootDisplayName: String {
        settings?.displayName ?? domain.displayName
    }
}
```

### 2. Application

Use `FinderLocationManager` in your host application to register domains and reveal them in Finder:

```swift
import AppKit
import FileProvider
import FinderLocations
import Foundation
import RemoteFiles

@MainActor
final class StorageController {
    let manager = FinderLocationManager(
        appGroup: "group.com.example.remote-files",
        identifierPrefix: "server-"
    )

    func openLocation(serverID: String, name: String, serverURL: URL) async throws {
        let settings = RemoteFilesDomainSettings(
            baseURL: serverURL,
            readOnly: false,
            displayName: name
        )

        // Add the domain first: macOS lists the extension in System Settings only once a
        // domain exists, so check approval after adding, never before.
        let rootURL = try await manager.add(id: serverID, name: name, settings: settings)
        guard await manager.isExtensionEnabled() else {
            // Ask the user to switch the extension on (System Settings › General ›
            // Login Items & Extensions › File Providers), then call this again.
            return
        }

        // fileproviderd can lose a domain's state; one reset brings it back.
        if await FinderLocationHealth.check(root: rootURL) {
            NSWorkspace.shared.open(rootURL)
        } else {
            let resetURL = try await manager.reset(id: serverID, name: name)
            NSWorkspace.shared.open(resetURL)
        }
    }

    func disconnect(serverID: String) async {
        await manager.remove(id: serverID)
    }
}
```

## System Settings Approval

Before a File Provider extension can serve domains, macOS requires the user to enable it under:
**System Settings › General › Login Items & Extensions › File Providers**.

The `manager.isExtensionEnabled()` method checks whether any domain has been approved by the user (`domain.userEnabled == true`), allowing your application to show guidance or prompt the user accordingly.

## Licence

Apache License 2.0: see [LICENSE](LICENSE). Use it in open or closed apps; ship the [NOTICE](NOTICE)
file's text with your app (an Acknowledgements screen is the usual place).
