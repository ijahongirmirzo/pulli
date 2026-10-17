# Reusing Pulli's core in another app

Pulli is split so that its engine does not depend on how a phone is reached. Another app — for
example one that talks to an Android phone over Wi-Fi — can reuse the parts below and supply its
own phone connection.

## The parts

| Part | Where | Licence | What it gives you |
|---|---|---|---|
| **FinderLocations** (products `RemoteFiles`, `RemoteFilesProvider`, `FinderLocations`) | `Packages/FinderLocations` | Apache 2.0 | Show any remote file tree as a location in Finder's sidebar (File Provider), with a WebDAV source included, location management and a health check with self-repair. See its [README](../Packages/FinderLocations/README.md). |
| **DeviceAPI** | `Sources/DeviceAPI` | GPL-3.0-or-later | The seam: `DeviceConnector` (opens a phone), `DeviceSession` (storages, paged listing, stat, ranged reads), `DeviceWatcher`, value types and `DeviceError`. Implement these for a new transport. |
| **TransferCore** | `Sources/TransferCore` | GPL-3.0-or-later | The resumable copy engine: the GRDB journal, batches and folder scans, `TransferSupervisor` (reconnects, waits, backoff), 4 MiB block commits, the chained SHA-256 digest, name mapping and duplicate handling. Works with any `DeviceSession`. |
| **MockDevice** | `Sources/MockDevice` | GPL-3.0-or-later | A simulated phone with fault injection (disconnects, stalls, short reads, power loss) for testing a transport or the engine. |

Also in this repository, but tied to USB phones: `MTPKit` and `USBKit` (libmtp over USB), and,
on the `appstore` branch, `ICCKit` (Apple's ImageCaptureCore, for a sandboxed App Store build).

## Depending on it

Swift Package Manager can only depend on a whole repository, so:

- **Pulli's core** (DeviceAPI, TransferCore, MockDevice):
  ```swift
  .package(url: "https://github.com/ijahongirmirzo/pulli", branch: "main"),
  // in a target:
  .product(name: "TransferCore", package: "pulli"),
  ```
  Building it fetches GRDB; libmtp is only needed if you use MTPKit.
- **FinderLocations** lives in a subfolder of this repository, which SwiftPM cannot fetch by URL.
  On the same Mac use a path: `.package(path: "../pulli/Packages/FinderLocations")`. For use from
  GitHub it should move to its own repository first.

## How to reuse the engine with a new transport

1. Implement `DeviceConnector` and `DeviceSession` for your transport (ranged reads are what make
   resume byte-exact; a transport without them can still copy, but restarts a file after an
   interruption — see `ReadStrategy`).
2. Implement `DeviceWatcher` so the app knows which phones are reachable.
3. Create a `Journal` and run batches through `TransferSupervisor` exactly as `pulli-cli copy`
   does (`Sources/pulli-cli/CopyCommand.swift` is the smallest complete example).
4. Test it against `MockDevice`'s fault injection (see `Tests/TransferCoreTests`).

## Licence

Pulli's own code is GPL-3.0-or-later (with the author-credit term in [NOTICE](../NOTICE));
FinderLocations is Apache 2.0. Apps by Pulli's author may use and relicense the code freely,
since the author holds the copyright; others must follow the licences.
