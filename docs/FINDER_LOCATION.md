# The phone as a Finder location (File Provider)

Status: in progress, 2026-10-14. Replaces the WebDAV mount (`mount_webdav`, D-029) as the way a
phone shows in Finder; the mount stays as the fallback.

## Why

Mounted with `mount_webdav`, the phone shows in Finder as a server named "127.0.0.1", "Connected
as: WebDAV", with a generic server icon. A File Provider extension (Apple's
`NSFileProviderReplicatedExtension`, as Google Drive and iCloud Drive use) shows it under
Locations by its own name ("myGalaxy") with Pulli's icon, with eject in the sidebar, files that
download when opened, and it works in every app's Open and Save panels. It is also the path an
App Store edition needs (docs/APP_STORE.md, spike 3).

## Layers (reusable package)

The generic code lives in its own local Swift package, `Packages/FinderLocations` (docs/DECISIONS.md), offering three library products (`RemoteFiles`, `RemoteFilesProvider`, and `FinderLocations`) without any dependencies outside Apple's SDK so it can be reused by other apps:

| Target / Product | Package | Imports | What |
|---|---|---|---|
| `RemoteFiles` | `FinderLocations` | Foundation | `RemoteItem`, `RemotePath`, `RemoteFileError`, the `RemoteFileSource` protocol, and `WebDAVSource` (a WebDAV client implementing it). Also `RemoteFilesDomainStore`: per-domain settings in a shared (App Group) `UserDefaults` suite. |
| `RemoteFilesProvider` | `FinderLocations` | RemoteFiles, FileProvider, UniformTypeIdentifiers | `open class RemoteFilesExtension: NSObject, NSFileProviderReplicatedExtension`, generic over any `RemoteFileSource` (subclasses override `makeSource()`); `RemoteProviderItem` (an `NSFileProviderItem` from a `RemoteItem`); `RemoteEnumerator`. |
| `FinderLocations` | `FinderLocations` | RemoteFiles, FileProvider, Foundation | `FinderLocationManager`: generic domain addition, removal, reset, and extension-enabled inspection. Also generic `FinderLocationHealth.check()`. |
| `PulliFileProvider` | Pulli | RemoteFiles, RemoteFilesProvider | Pulli's extension executable: `@objc(PulliFileProviderExtension)` subclass that reads its domain's settings and returns a `WebDAVSource` on Pulli's drive server. Bundled by `scripts/make-app.sh` as `Contents/PlugIns/PulliFileProvider.appex`. |
| app (`Sources/Pulli/FinderLocation.swift`) | Pulli | FileProvider, FinderLocations, RemoteFiles | Thin layer over `FinderLocationManager` with Pulli's App Group and `phone-` prefix; `FinderLocationHealth.swift` wraps `FinderLocations.FinderLocationHealth` with the preferred "DCIM" subfolder and the `PULLI_FAKE_FINDER_ERROR` dev switch. |

Item identifiers are paths ("/DCIM/Camera/a.jpg"); the root is `.rootContainer`. The drive
server is Pulli's existing `PhoneDrive` (HelperCore) on `http://127.0.0.1:<port>/<token>/<volume>/`,
so everything it already does (ranged reads, Finder's dot files in memory, the "allow deleting"
switch, answering 403 otherwise) carries over.

## Identity and signing

- App Group: `8Q2D6948R4.app.pulli.mac` (team-prefixed: no provisioning profile for Developer ID).
- Extension bundle id `app.pulli.mac.fileprovider`, extension point `com.apple.fileprovider-nonui`,
  `NSExtensionFileProviderDocumentGroup` = the group, principal class
  `PulliFileProviderExtension`.
- Extension entitlements: app sandbox, the application group, network client (to reach
  127.0.0.1). The app gets the application group entitlement too.

## Health check and automatic repair

On macOS, `fileproviderd` can occasionally lose its internal state for a domain, leaving folders on
"Loading…" and Finder reporting '"Pulli" encountered an error' while Pulli sees no issue. When
"Open in Finder" opens a Finder location, Pulli verifies and repairs it automatically:

1. **Health check** (`FinderLocationHealth`): runs off the main actor, listing the root folder and
   its first subfolder (preferring "DCIM"), racing against an 8-second timeout. An empty root is
   healthy. If any listing throws or times out, the check fails.
2. **One-time repair** (`FinderLocation.reset`): removes the domain via `NSFileProviderManager`
   without clearing settings in `RemoteFilesDomainStore`, adds it again, updates the stored folder,
   checks again, and re-opens the location in Finder if healthy. The repair is attempted at most
   once per phone per app run, resetting when the phone is unplugged.
3. **Fallback note**: if the second check still fails, the main window displays a note:
   "Finder can't show {name} right now. Browse it here instead." with a
   "Browse in Pulli" button to open Pulli's in-app browser.
