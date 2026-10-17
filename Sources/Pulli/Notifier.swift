import AppKit
import UserNotifications

/// Pulli's notifications: a copy finished or needs you, a phone with new photos connected,
/// space freed. Only while Pulli is not in front (when it is, the window already shows it), and
/// only with Settings › Notify me about copies on (the default).
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

    /// Removes all delivered notifications Pulli posted.
    @MainActor
    static func removeAllDelivered() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
