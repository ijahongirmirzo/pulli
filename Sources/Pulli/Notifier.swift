import AppKit
@preconcurrency import UserNotifications

/// Pulli's notifications: a copy finished or needs you, a phone with new photos connected,
/// space freed, or a quiet update notice. Only while Pulli is not in front (when it is, the window
/// already shows it), and only with Settings › Notify me about copies on (the default).
enum Notifier {
    @MainActor
    static func post(title: String, body: String) {
        // Only in the real app: tests and snapshots have no NSApp, and the notification centre
        // needs an app bundle.
        guard UserDefaults.standard.object(forKey: "notifyCopies") as? Bool ?? true,
              let app = NSApp as NSApplication?, !app.isActive,
              Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// Posts a quiet notification for an available update if the user has not yet been notified for this version.
    @MainActor
    static func postUpdateAvailable(version: String) {
        guard UserDefaults.standard.object(forKey: "notifyCopies") as? Bool ?? true else { return }
        guard UserDefaults.standard.string(forKey: "lastNotifiedUpdateVersion") != version else { return }
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }

        UserDefaults.standard.set(version, forKey: "lastNotifiedUpdateVersion")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Pulli \(version) is available"
            content.body = "Click to install"
            content.userInfo = ["action": "installUpdate"]
            let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
            center.add(request)
        }
    }

    /// Removes any delivered update notice notifications.
    @MainActor
    static func removeUpdateNotification() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { notifications in
            let ids = notifications.filter { $0.request.identifier.hasPrefix("update-") }.map { $0.request.identifier }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
        }
    }

    /// Removes all delivered notifications Pulli posted.
    @MainActor
    static func removeAllDelivered() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
