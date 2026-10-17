public import Foundation

/// Per-domain configuration stored by the hosting application and read by the File Provider extension.
public struct RemoteFilesDomainSettings: Codable, Sendable, Equatable {
    /// The root URL of the remote file tree.
    public var baseURL: URL

    /// Whether this domain operates in read-only mode.
    public var readOnly: Bool

    /// The human-readable name of the domain shown in Finder.
    public var displayName: String

    /// Initialises domain settings.
    public init(baseURL: URL, readOnly: Bool = false, displayName: String) {
        self.baseURL = baseURL
        self.readOnly = readOnly
        self.displayName = displayName
    }
}

/// Manages per-domain settings in a shared `UserDefaults` suite (such as an App Group).
public struct RemoteFilesDomainStore: Sendable {
    /// The name of the `UserDefaults` suite.
    public let suiteName: String

    /// Initialises a domain store for the specified App Group suite.
    public init(suiteName: String) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    private func key(for domainID: String) -> String {
        "remoteFiles.domain.\(domainID)"
    }

    /// Reads settings for a given domain identifier, or returns `nil` if absent or unparseable.
    public func settings(for domainID: String) -> RemoteFilesDomainSettings? {
        guard let data = defaults?.data(forKey: key(for: domainID)) else { return nil }
        return try? JSONDecoder().decode(RemoteFilesDomainSettings.self, from: data)
    }

    /// Stores domain settings as JSON in the shared suite.
    public func set(_ settings: RemoteFilesDomainSettings, for domainID: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults?.set(data, forKey: key(for: domainID))
    }

    /// Removes domain settings from the shared suite.
    public func remove(_ domainID: String) {
        defaults?.removeObject(forKey: key(for: domainID))
    }
}
