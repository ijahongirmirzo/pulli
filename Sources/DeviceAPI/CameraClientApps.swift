import Foundation

/// One app known to browse phones or cameras in the background.
public struct CameraClientApp: Sendable, Hashable, Equatable, Identifiable {
    public let bundleID: String
    public let displayName: String

    public var id: String { bundleID }

    public init(bundleID: String, displayName: String) {
        self.bundleID = bundleID
        self.displayName = displayName
    }
}

/// Known macOS applications that open phones or cameras in the background (docs/DECISIONS.md, D-008).
///
/// When an app like Google Drive browses cameras via ImageCaptureCore, launchd restarts ptpcamerad
/// whenever Pulli terminates it. Naming the actual user application lets the user quit it so Pulli
/// can claim the phone interface.
public enum CameraClientApps {
    /// Human-friendly name used instead of raw system daemon names like "ptpcamerad".
    public static let photoServiceName = "macOS's photo service"

    /// Known apps in priority order for display and conflict resolution.
    public static let known: [CameraClientApp] = [
        CameraClientApp(bundleID: "com.google.drivefs", displayName: "Google Drive"),
        CameraClientApp(bundleID: "com.getdropbox.dropbox", displayName: "Dropbox"),
        CameraClientApp(bundleID: "com.apple.Photos", displayName: "Photos"),
        CameraClientApp(bundleID: "com.apple.Image_Capture", displayName: "Image Capture"),
        CameraClientApp(bundleID: "com.apple.Preview", displayName: "Preview"),
        CameraClientApp(bundleID: "com.adobe.LightroomClassicCC7", displayName: "Lightroom Classic"),
        CameraClientApp(bundleID: "com.adobe.mas.lightroomCC", displayName: "Lightroom"),
        CameraClientApp(bundleID: "com.adobe.lightroomCC", displayName: "Lightroom"),
        CameraClientApp(bundleID: "com.samsung.SmartSwitch", displayName: "Samsung Smart Switch"),
        CameraClientApp(bundleID: "com.google.android.mtpviewer", displayName: "Android File Transfer"),
        CameraClientApp(bundleID: "io.ganeshrvel.openmtp", displayName: "OpenMTP"),
    ]

    /// Looks up a known client app by bundle identifier (case-insensitive).
    public static func app(forBundleID bundleID: String) -> CameraClientApp? {
        known.first { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Returns matching known apps for running bundle identifiers, in declared priority order.
    public static func matching<S: Sequence<String>>(runningBundleIDs: S) -> [CameraClientApp] {
        let runningSet = Set(runningBundleIDs.map { $0.lowercased() })
        var seen = Set<String>()
        var result: [CameraClientApp] = []
        for client in known {
            if runningSet.contains(client.bundleID.lowercased()), !seen.contains(client.displayName) {
                seen.insert(client.displayName)
                result.append(client)
            }
        }
        return result
    }

    /// First matching running app in priority order, if any.
    public static func firstRunning<S: Sequence<String>>(in runningBundleIDs: S) -> CameraClientApp? {
        matching(runningBundleIDs: runningBundleIDs).first
    }

    /// Whether `name` matches a raw macOS camera daemon or the human-friendly photo service name.
    public static func isSystemCameraDaemonName(_ name: String) -> Bool {
        name == "ptpcamerad" || name.hasPrefix("mscamerad") || name == photoServiceName
    }

    /// Returns "macOS's photo service" when `name` is a system camera daemon, else `name` unmodified.
    public static func sanitizedHolderName(_ name: String) -> String {
        isSystemCameraDaemonName(name) ? photoServiceName : name
    }
}
