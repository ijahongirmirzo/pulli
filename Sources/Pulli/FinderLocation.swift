import FileProvider
import FinderLocations
import Foundation
import RemoteFiles

/// A phone as a Finder location: one File Provider domain per phone, listed under Locations by
/// the phone's own name with Pulli's icon (docs/FINDER_LOCATION.md). The extension that serves it
/// is `PulliFileProvider.appex` inside the app; this type is a thin layer over `FinderLocationManager`.
@MainActor
enum FinderLocation {
    /// Manager configured with Pulli's shared App Group suite and domain prefix.
    static let manager = FinderLocationManager(
        appGroup: PulliApp.appGroup,
        identifierPrefix: "phone-"
    )

    /// A domain identifier from a device id: File Provider accepts only letters, digits, "-", "."
    /// and "_", and the same phone must always map to the same domain so a leftover from an
    /// earlier run is replaced rather than duplicated.
    static func identifier(for deviceID: String) -> NSFileProviderDomainIdentifier {
        let safeID = deviceID.isEmpty ? "device" : deviceID
        return manager.identifier(for: safeID)
    }

    /// Adds the phone's domain (named `name` in Finder) and returns its folder, where Finder
    /// should be pointed.
    static func add(deviceID: String, name: String) async throws -> URL {
        let safeID = deviceID.isEmpty ? "device" : deviceID
        return try await manager.add(id: safeID, name: name)
    }

    /// Removes and re-adds the phone's domain to recover when fileproviderd has lost its state,
    /// keeping domain settings in RemoteFilesDomainStore intact.
    static func reset(deviceID: String, name: String) async throws -> URL {
        let safeID = deviceID.isEmpty ? "device" : deviceID
        return try await manager.reset(id: safeID, name: name)
    }

    /// The user-visible root URL in Finder for the phone's domain, retrying briefly while setting up.
    static func userVisibleURL(deviceID: String) async throws -> URL {
        let safeID = deviceID.isEmpty ? "device" : deviceID
        return try await manager.userVisibleURL(for: safeID)
    }

    /// Takes the phone out of Finder and clears its domain settings (its copies on the phone are
    /// never touched).
    static func remove(deviceID: String) async {
        let safeID = deviceID.isEmpty ? "device" : deviceID
        await manager.remove(id: safeID)
    }

    /// Takes every phone out of Finder (Pulli is quitting, or a spike left one behind).
    static func removeAll() async {
        await manager.removeAll()
    }

    /// Whether macOS has Pulli's Finder extension switched on (System Settings › General ›
    /// Login Items & Extensions › File Providers): any of Pulli's domains reports it.
    static func isExtensionEnabled() async -> Bool {
        await manager.isExtensionEnabled()
    }
}
