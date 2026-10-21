import AppKit
import FileProvider
import FinderLocations
import PulliProtocol
import RemoteFiles
import TransferCore

/// Mounts a phone's drive (a WebDAV server inside Pulli, on this Mac only) so the phone shows in
/// Finder like any drive.
///
/// Mounted with macOS's WebDAV client directly (`mount_webdav`, about two seconds). The NetFS
/// framework (what Finder's Connect to Server uses) waits 90 seconds on every mount of a server on
/// this Mac before finishing, and needs a guest sign-in (D-029). Only system tools can create
/// folders in /Volumes, so the mount point is in Pulli's own folder; Finder still lists the drive
/// under Locations.
@MainActor
enum FinderDrive {
    static let mountsFolder = DataFolder.current.appendingPathComponent("Drives", isDirectory: true)

    /// Mounts `url` as `name` and returns where; nil if macOS refused.
    static func mount(_ url: URL, name: String) async -> URL? {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let point = mountsFolder.appendingPathComponent(safe.isEmpty ? "Phone" : safe, isDirectory: true)
        return await Task.detached {
            // A mount left from an earlier run (Pulli quit without unmounting) is taken down first.
            if isMountPoint(point) { _ = run("/sbin/umount", ["-f", point.path]) }
            try? FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
            guard run("/sbin/mount_webdav", ["-S", "-v", safe, url.absoluteString, point.path]) == 0, isMountPoint(point) else {
                // rmdir removes only an empty folder: it can never reach into a mounted phone.
                rmdir(point.path)
                return nil
            }
            return point
        }.value
    }

    static func unmount(_ mountPoint: URL) {
        Task.detached {
            if run("/sbin/umount", [mountPoint.path]) != 0 { _ = run("/sbin/umount", ["-f", mountPoint.path]) }
            // rmdir removes only an empty folder: if the drive is somehow still mounted it fails,
            // and nothing on the phone is touched (a recursive delete would reach into it).
            rmdir(mountPoint.path)
        }
    }

    /// The folder is a mount point (on another file system than its parent).
    nonisolated private static func isMountPoint(_ url: URL) -> Bool {
        var point = stat(), parent = stat()
        guard stat(url.path, &point) == 0, stat(url.deletingLastPathComponent().path, &parent) == 0 else { return false }
        return point.st_dev != parent.st_dev
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

extension AppModel {
    /// Shows the phone in Finder: its Finder location when macOS has Pulli's extension on, else
    /// the WebDAV mount (and, once, the tutorial for the switch).
    func openInFinder() {
        guard let device, device.state == .ready else { return }
        driveStatus = "Opening \(device.name) in Finder…"
        Task {
            defer { driveStatus = nil }
            let fresh = finderLocations[device.id] == nil && finderMounts[device.id] == nil
            guard let root = await phoneFilesRoot(askForApproval: true) else {
                await recordLog("Could not open \(device.name) in Finder: no root URL", level: 3, kind: "finder_location")
                if finderLocationDisabled {
                    finderTrouble = nil
                }
                return
            }
            if finderLocationDisabled {
                finderTrouble = nil
            }
            Self.showInFinder(root)
            if fresh { sounds.play(.connect) }

            // Verify and repair only for Finder locations, not the WebDAV mount.
            guard finderLocations[device.id] != nil else { return }
#if !PULLI_APP_STORE
            verifyAndRepairFinderLocation(for: device, root: root)
#endif
        }
    }

    /// Opens the phone's folder in Finder. In the App Sandbox the user-visible File Provider URL
    /// is security-scoped: without starting access, Finder answers "Pulli does not have permission
    /// to open" it. Access is held a few seconds so Finder can take its own copy of the grant.
    static func showInFinder(_ root: URL) {
        let scoped = root.startAccessingSecurityScopedResource()
        if !NSWorkspace.shared.open(root) {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
        guard scoped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { root.stopAccessingSecurityScopedResource() }
    }

    /// Verifies that a Finder location is healthy and repairs it once if fileproviderd broke.
    private func verifyAndRepairFinderLocation(for device: DeviceSnapshot, root: URL) {
        Task {
            let status = await FinderLocationHealth.checkStatus(root: root)
            if status == .domainDisabled {
                guard self.device?.id == device.id else { return }
                finderLocationDisabled = true
                await recordLog("Finder location domain disabled", level: 3, kind: "finder_location")
                return
            }
            guard status != .healthy else { return }
            guard self.device?.id == device.id else { return }

            await recordLog("Finder location check failed", level: 3, kind: "finder_location")
            guard !repairedPhones.contains(device.id) else {
                await recordLog("Finder location still failing", level: 4, kind: "finder_location")
                finderTrouble = device.id
                return
            }

            repairedPhones.insert(device.id)
            driveStatus = "Repairing \(device.name) in Finder…"
            defer { driveStatus = nil }

            do {
                let newRoot = try await FinderLocation.reset(deviceID: device.id, name: device.name)
                finderLocations[device.id] = newRoot
                let repairedStatus = await FinderLocationHealth.checkStatus(root: newRoot)
                guard self.device?.id == device.id else { return }
                if repairedStatus == .domainDisabled {
                    finderLocationDisabled = true
                    await recordLog("Finder location domain disabled", level: 3, kind: "finder_location")
                } else if repairedStatus == .healthy {
                    await recordLog("Finder location repaired", level: 2, kind: "finder_location")
                    Self.showInFinder(newRoot)
                } else {
                    await recordLog("Finder location still failing", level: 4, kind: "finder_location")
                    finderTrouble = device.id
                }
            } catch {
                guard self.device?.id == device.id else { return }
                if FinderLocations.FinderLocationHealth.isDomainDisabledError(error) {
                    finderLocationDisabled = true
                    await recordLog("Finder location domain disabled", level: 3, kind: "finder_location")
                } else {
                    await recordLog("Finder location still failing", level: 4, kind: "finder_location")
                    finderTrouble = device.id
                }
            }
        }
    }

    /// Where the phone's files are on this Mac, for Finder and for ⌘C: its Finder location if
    /// macOS has the extension switched on (added if needed), else the WebDAV drive (mounted if
    /// needed). `askForApproval` shows the switch tutorial when the extension is off.
    func phoneFilesRoot(askForApproval: Bool = false) async -> URL? {
        guard let client, let device, device.state == .ready else { return nil }
        if let location = finderLocations[device.id] { return location }
        if case .drive(let address) = try? await client.send(.startDrive(deviceID: device.id)),
           let driveURL = URL(string: address) {
            let domainID = FinderLocation.identifier(for: device.id)
            RemoteFilesDomainStore(suiteName: PulliApp.appGroup)
                .set(RemoteFilesDomainSettings(baseURL: driveURL, readOnly: false, displayName: device.name), for: domainID.rawValue)
            do {
                let url = try await FinderLocation.add(deviceID: device.id, name: device.name)
                let domain = (try? await NSFileProviderManager.domains())?.first { $0.identifier == domainID }
                if domain?.userEnabled == false {
                    finderLocationDisabled = true
                    if askForApproval { finderLocationNeedsApproval = true }
                } else {
                    finderLocationDisabled = false
                    finderLocations[device.id] = url
                    return url
                }
            } catch {
                await recordLog("Adding Finder location for \(device.name) failed: \(Self.describe(error))", level: 3, kind: "finder_location")
                if FinderLocations.FinderLocationHealth.isDomainDisabledError(error) {
                    finderLocationDisabled = true
                }
            }
        }
        return await mountedDrive()
    }

    /// The phone's drive in Finder, mounted first if it is not (nil, with a banner, if it
    /// cannot be).
    func mountedDrive() async -> URL? {
        guard let client, let device, device.state == .ready else { return nil }
        if let mounted = finderMounts[device.id], FileManager.default.fileExists(atPath: mounted.path) { return mounted }
        do {
            guard case .drive(let address) = try await client.send(.startDrive(deviceID: device.id)), let url = URL(string: address) else { return nil }
            guard let mountPoint = await FinderDrive.mount(url, name: device.name) else {
                banner = "macOS did not mount \(device.name). Try again, or use Finder › Go › Connect to Server with \(address)"
                return nil
            }
            finderMounts[device.id] = mountPoint
            return mountPoint
        } catch {
            banner = "Could not open \(device.name) in Finder: \(Self.describe(error))"
            return nil
        }
    }

    /// Takes the phone's Finder location out and clears its settings.
    func removeFinderLocation(_ deviceID: String) async {
        finderLocations.removeValue(forKey: deviceID)
        await FinderLocation.remove(deviceID: deviceID)
    }

    /// The phone left (or Pulli is quitting): take its drive out of Finder.
    func unmountFinderDrive(_ deviceID: String) {
        repairedPhones.remove(deviceID)
        if finderTrouble == deviceID { finderTrouble = nil }
        Task { await removeFinderLocation(deviceID) }
        guard let mountPoint = finderMounts.removeValue(forKey: deviceID) else { return }
        FinderDrive.unmount(mountPoint)
    }
}
