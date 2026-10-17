#if !PULLI_APP_STORE
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
#endif

