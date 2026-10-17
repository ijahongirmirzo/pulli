import AppKit
import ServiceManagement

/// Opening Pulli at login (the app itself as a login item). Started by macOS at login, Pulli
/// opens no window and shows no Dock icon: it only watches for phones, and comes forward (or
/// notifies) when one is plugged in. With no window, its views, 3D art and preview caches are
/// released, so it stays small.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: "loginItemAppPath")
        } else {
            try SMAppService.mainApp.unregister()
            UserDefaults.standard.removeObject(forKey: "loginItemAppPath")
        }
    }

    /// If enabled and the app was renamed/moved, re-register it so login launches the new copy
    /// (unregister then register, only when status says it is enabled; ignore errors).
    static func reregisterIfMoved() {
        guard SMAppService.mainApp.status == .enabled else { return }
        let currentPath = Bundle.main.bundlePath
        let lastPath = UserDefaults.standard.string(forKey: "loginItemAppPath")
        if lastPath != currentPath {
            try? SMAppService.mainApp.unregister()
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(currentPath, forKey: "loginItemAppPath")
        }
    }

    /// This launch is macOS opening Pulli at login (read from the launch's Apple event).
    static var launchedAtLogin = false
    /// The window has been put away once for this login launch.
    static var handledLaunch = false

    static func readLaunchEvent() {
        // PULLI_LOGIN_LAUNCH=1 behaves as a login launch (for trying it without logging out).
        if ProcessInfo.processInfo.environment["PULLI_LOGIN_LAUNCH"] == "1" {
            launchedAtLogin = true
            return
        }
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) else { return }
        launchedAtLogin = true
    }
}
