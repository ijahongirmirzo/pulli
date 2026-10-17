import Foundation
import ServiceManagement

/// The background helper (a LaunchAgent inside the app bundle, registered with SMAppService).
/// Off by default: Pulli then runs its engine inside the app, and copies pause when it quits.
enum HelperRegistration {
    static let plistName = "app.pulli.mac.helper.plist"

    static var service: SMAppService { .agent(plistName: plistName) }

    static var isEnabled: Bool { service.status == .enabled }

    static var needsApproval: Bool { service.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }

    /// Registers the helper again, so launchd picks up the app's current code signature.
    static func repair() {
        try? service.unregister()
        try? service.register()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
