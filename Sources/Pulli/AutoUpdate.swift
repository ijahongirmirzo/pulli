import AppKit
import Foundation
import PulliProtocol
import Sparkle

/// The running updater, observed so menus drawn before it started show its commands.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()
    var controller: SPUStandardUpdaterController?
    var available: String?

    /// Brings Pulli forward and presents Sparkle's update window for the available update.
    func install() {
        NSApplication.shared.activate()
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle user-driver delegate: quiet, gentle update notices instead of unexpected pop-up windows.
@MainActor
final class UpdateDriverDelegate: NSObject {
    private let updates: Updates
    private let notify: (String) -> Void

    init(
        updates: Updates = .shared,
        notify: @escaping (String) -> Void = { Notifier.postUpdateAvailable(version: $0) }
    ) {
        self.updates = updates
        self.notify = notify
        super.init()
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // MARK: - Testable seam

    /// Sparkle shows its window only when it would come up in immediate focus; otherwise Pulli shows its own notice.
    func shouldHandleScheduledUpdate(immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    /// When Sparkle will not show its window, record the available version for Pulli's notice and notify the user once.
    func recordAvailableUpdate(sparkleHandles: Bool, version: String) {
        guard !sparkleHandles else { return }
        updates.available = version
        notify(version)
    }

    /// Clears the notice once the user gave attention to the update or finished the session.
    func dismissNotice() {
        updates.available = nil
        Notifier.removeUpdateNotification()
    }
}

extension UpdateDriverDelegate: @MainActor SPUStandardUserDriverDelegate {
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        shouldHandleScheduledUpdate(immediateFocus: immediateFocus)
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        recordAvailableUpdate(sparkleHandles: handleShowingUpdate, version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        dismissNotice()
    }

    func standardUserDriverWillFinishUpdateSession() {
        dismissNotice()
    }
}

/// Manages postponements of Sparkle updates while transfers are running.
@MainActor
final class RelaunchPostponer {
    private(set) var isPostponed = false
    private var pendingInstallHandler: (() -> Void)?

    /// Returns true if any batch is currently scanning or copying bytes.
    nonisolated static func hasActiveCopies(in batches: [BatchSnapshot]) -> Bool {
        batches.contains { batch in
            switch batch.phase {
            case .copying, .scanning: true
            default: false
            }
        }
    }

    /// Postpones relaunch if a copy is running, saving the install handler to run later.
    func handlePostpone(hasActiveCopies: Bool, installHandler: @escaping () -> Void) -> Bool {
        guard hasActiveCopies else {
            isPostponed = false
            pendingInstallHandler = nil
            return false
        }
        isPostponed = true
        pendingInstallHandler = installHandler
        return true
    }

    /// Checks if a postponed update can now install because active copies have finished.
    func batchesDidUpdate(hasActiveCopies: Bool, beforeInstall: (() async -> Void)? = nil) {
        guard isPostponed, !hasActiveCopies else { return }
        isPostponed = false
        guard let handler = pendingInstallHandler else { return }
        pendingInstallHandler = nil
        Task { @MainActor in
            if let beforeInstall {
                await beforeInstall()
            }
            handler()
        }
    }
}

/// Helpers for Sparkle version comparison and update configuration.
enum UpdateManager {
    /// Compares two version strings using Sparkle's standard version comparator.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        SUStandardVersionComparator.default.compareVersion(a, toVersion: b)
    }
}
