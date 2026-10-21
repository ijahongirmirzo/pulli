import AppKit
import DeviceAPI

extension CameraClientApps {
    /// Returns the first running known camera client application in priority order, with its running process.
    @MainActor
    static func firstRunningApp() -> (app: CameraClientApp, running: NSRunningApplication)? {
        let runningApps = NSWorkspace.shared.runningApplications
        for client in known {
            if let running = runningApps.first(where: {
                $0.bundleIdentifier?.caseInsensitiveCompare(client.bundleID) == .orderedSame
            }) {
                return (client, running)
            }
        }
        return nil
    }
}
