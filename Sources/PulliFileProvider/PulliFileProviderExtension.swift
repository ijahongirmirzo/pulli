import FileProvider
import Foundation
import RemoteFiles
import RemoteFilesProvider

/// Pulli's Finder location (docs/FINDER_LOCATION.md): the reusable core, pointed at the phone's
/// drive server inside Pulli on this Mac. The app writes each domain's address (it changes on
/// every start of the drive) to the shared App Group settings; the extension reads it per call,
/// so a restarted drive is picked up without restarting the extension.
@objc(PulliFileProviderExtension)
final class PulliFileProviderExtension: RemoteFilesExtension, @unchecked Sendable {
    /// Shared with the app (team-prefixed: no provisioning profile needed for Developer ID).
    static let appGroup = "8Q2D6948R4.app.pulli.mac"

    private var settings: RemoteFilesDomainSettings? {
        RemoteFilesDomainStore(suiteName: Self.appGroup).settings(for: domain.identifier.rawValue)
    }

    override func makeSource() -> (any RemoteFileSource)? {
        settings.map { WebDAVSource(baseURL: $0.baseURL) }
    }

    override var readOnly: Bool { settings?.readOnly ?? true }

    override var rootDisplayName: String { settings?.displayName ?? domain.displayName }
}
