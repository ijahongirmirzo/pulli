public import FileProvider
public import Foundation
public import RemoteFiles

/// Manages File Provider domains for remote file locations in Finder.
public struct FinderLocationManager: Sendable {
    /// Shared App Group suite name for domain settings.
    public let appGroup: String

    /// Prefix prepended to sanitised identifiers.
    public let identifierPrefix: String

    /// Initialises a manager for a given App Group and optional domain identifier prefix.
    public init(appGroup: String, identifierPrefix: String = "") {
        self.appGroup = appGroup
        self.identifierPrefix = identifierPrefix
    }

    /// Access to the domain settings store in the shared App Group.
    public var domainStore: RemoteFilesDomainStore {
        RemoteFilesDomainStore(suiteName: appGroup)
    }

    /// Formats a safe domain identifier for a given raw identifier.
    ///
    /// File Provider accepts only letters, digits, "-", "." and "_".
    public func identifier(for id: String) -> NSFileProviderDomainIdentifier {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        let safe = String(id.map { allowed.contains($0) ? $0 : "-" })
        let suffix = safe.isEmpty ? "location" : safe
        return NSFileProviderDomainIdentifier(rawValue: identifierPrefix + suffix)
    }

    /// Adds a File Provider domain and returns its user-visible root folder URL.
    ///
    /// If `settings` are supplied, they are saved to the domain store before registration.
    /// If an existing domain with the same identifier has a different display name,
    /// it is removed and re-added to refresh the name in Finder.
    @discardableResult
    public func add(id: String, name: String, settings: RemoteFilesDomainSettings? = nil) async throws -> URL {
        let domainID = identifier(for: id)
        if let settings {
            domainStore.set(settings, for: domainID.rawValue)
        }
        let domain = NSFileProviderDomain(identifier: domainID, displayName: name)
        let domains = (try? await NSFileProviderManager.domains()) ?? []
        if let existing = domains.first(where: { $0.identifier == domain.identifier }) {
            if existing.displayName != name {
                try await NSFileProviderManager.remove(existing)
                try await NSFileProviderManager.add(domain)
            }
        } else {
            try await NSFileProviderManager.add(domain)
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await userVisibleRootURL(for: manager)
    }

    /// Fetches the user-visible root container URL, retrying briefly while macOS sets up the domain.
    public func userVisibleRootURL(
        for manager: NSFileProviderManager,
        retries: Int = 10,
        delay: Duration = .milliseconds(200),
        fetch: (@Sendable () async throws -> URL)? = nil
    ) async throws -> URL {
        var lastError: (any Error)?
        for attempt in 1...retries {
            do {
                if let fetch {
                    return try await fetch()
                } else {
                    return try await manager.getUserVisibleURL(for: .rootContainer)
                }
            } catch {
                lastError = error
                if attempt < retries {
                    try? await Task.sleep(for: delay)
                }
            }
        }
        throw lastError ?? CocoaError(.fileNoSuchFile)
    }

    /// Returns the user-visible root folder URL for a domain, retrying briefly if macOS is still setting it up.
    public func userVisibleURL(for id: String) async throws -> URL {
        let domainID = identifier(for: id)
        guard let domain = (try? await NSFileProviderManager.domains())?.first(where: { $0.identifier == domainID }),
              let manager = NSFileProviderManager(for: domain) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try await userVisibleRootURL(for: manager)
    }

    /// Removes and re-adds a domain to recover when fileproviderd has lost its state,
    /// keeping domain settings in the store intact.
    @discardableResult
    public func reset(id: String, name: String) async throws -> URL {
        let domainID = identifier(for: id)
        if let domain = try? await NSFileProviderManager.domains().first(where: { $0.identifier == domainID }) {
            try await NSFileProviderManager.remove(domain)
        }
        return try await add(id: id, name: name)
    }

    /// Removes a domain from Finder and deletes its settings from the domain store.
    public func remove(id: String) async {
        let domainID = identifier(for: id)
        domainStore.remove(domainID.rawValue)
        guard let domain = try? await NSFileProviderManager.domains().first(where: { $0.identifier == domainID }) else { return }
        try? await NSFileProviderManager.remove(domain)
    }

    /// Removes every domain registered for this File Provider extension.
    public func removeAll() async {
        try? await NSFileProviderManager.removeAllDomains()
    }

    /// Whether macOS has the File Provider extension enabled in System Settings.
    public func isExtensionEnabled() async -> Bool {
        guard let domains = try? await NSFileProviderManager.domains() else { return false }
        if !identifierPrefix.isEmpty {
            let matching = domains.filter { $0.identifier.rawValue.hasPrefix(identifierPrefix) }
            if !matching.isEmpty {
                return matching.contains { $0.userEnabled }
            }
        }
        return domains.contains { $0.userEnabled }
    }
}
