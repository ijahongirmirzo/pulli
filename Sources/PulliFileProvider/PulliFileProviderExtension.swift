import FileProvider
import Foundation
import PulliProtocol
import RemoteFiles
import RemoteFilesProvider

/// Pulli's Finder location (docs/FINDER_LOCATION.md): the reusable core, pointed at the phone's
/// drive server inside Pulli on this Mac. The app writes each domain's address (it changes on
/// every start of the drive) to the shared App Group settings; the extension reads it per call,
/// so a restarted drive is picked up without restarting the extension.
@objc(PulliFileProviderExtension)
final class PulliFileProviderExtension: RemoteFilesExtension, @unchecked Sendable {
    /// Shared with the app.
    static let appGroup = Edition.appGroup

    private var settings: RemoteFilesDomainSettings? {
        RemoteFilesDomainStore(suiteName: Self.appGroup).settings(for: domain.identifier.rawValue)
    }

    override func makeSource() -> (any RemoteFileSource)? {
        settings.map { WebDAVSource(baseURL: $0.baseURL) }
    }

    override var readOnly: Bool { settings?.readOnly ?? true }

    override var rootDisplayName: String { settings?.displayName ?? domain.displayName }
}
