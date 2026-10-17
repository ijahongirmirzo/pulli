public import Foundation

/// Build edition identity: Mac App Store (sandboxed) or direct download.
public enum Edition: Sendable {
#if PULLI_APP_STORE
    public static let isAppStore = true
    public static let bundleID = "app.pulli.store"
    public static let widgetBundleID = "app.pulli.store.widget"
    public static let fileProviderBundleID = "app.pulli.store.fileprovider"
    public static let appGroup = "8Q2D6948R4.app.pulli.store"
    public static let urlScheme = "pulli"
#else
    public static let isAppStore = false
    public static let bundleID = "app.pulli.mac"
    public static let widgetBundleID = "app.pulli.mac.widget"
    public static let fileProviderBundleID = "app.pulli.mac.fileprovider"
    public static let appGroup = "8Q2D6948R4.app.pulli.mac"
    public static let urlScheme = "pulli"
#endif
}
