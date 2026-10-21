import AppKit
import PulliProtocol
#if !PULLI_APP_STORE
import Sparkle
#endif
import SwiftUI
import UserNotifications

//   Pulli                      real phones (engine in the app, or the background helper)
//   Pulli --mock               a simulated phone
//   Pulli --snapshot DIR       render every screen to PNG files and exit (design checks)
//   Pulli --readme-frames DIR  render the frames of the README's animation (one copy, start to finish)
//   Pulli --art-poses DIR      render the 3D art at the pointer's extremes (checks for cut-off edges;
//                              PULLI_POSE_WIDTH=900 renders it large, to check bevels for seams)
//   PULLI_ART_POINTER=1,-1     with --snapshot: every screen's art turned to that extreme
//   Pulli --flyer DIR          render the one-page flyer for testers (PDF and PNG) and exit
//   Pulli --dmg-background DIR render the disk image window's background (scripts/make-dmg.sh)

@main
enum Entry {
    static func main() {
        Typeface.register()
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--icon"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshots.renderIcon(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshots.render(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--readme-frames"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshots.renderReadmeFrames(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--dmg-background"), arguments.indices.contains(index + 1) {
            let unsigned = arguments.contains("--unsigned")
            MainActor.assumeIsolated { DiskImageArt.render(to: URL(fileURLWithPath: arguments[index + 1]), unsigned: unsigned) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--themes"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshots.renderThemes(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--widget-snapshots"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshots.renderWidgetSnapshots(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--art-poses"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Snapshots.renderArtPoses(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--flyer"), arguments.indices.contains(index + 1) {
            MainActor.assumeIsolated { Flyer.render(to: URL(fileURLWithPath: arguments[index + 1])) }
            exit(0)
        }
        PulliApp.main()
    }
}

struct PulliApp: App {
    /// The app's bundle identifier.
    static let bundleID = Edition.bundleID
    /// The shared App Group for Finder Location settings.
    static let appGroup = Edition.appGroup

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    @AppStorage("showMenuBar") private var showMenuBar = true

    init() {
        let mock = CommandLine.arguments.contains("--mock") || ProcessInfo.processInfo.environment["PULLI_MOCK"] == "1"
        let model = AppModel(mock: mock)
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        Window("Pulli", id: "main") {
            RootView().environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1240, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            PulliCommands()
        }

        Window("Activity", id: "activity") {
            ActivityView().environment(model)
        }
        .defaultSize(width: 900, height: 520)

        Settings {
            SettingsView().environment(model)
        }

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView().environment(model).modifier(ToneProvider())
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Shown once the updater exists (it starts after launch; `Updates` is observed, so the menu
/// catches up). Builds without a Sparkle key have no updater and no menu item.
/// The About window's legal notices (GPL v3 section 5(d)) and the author credit that section
/// 7(b) asks modified versions to keep (see NOTICE).
enum AboutCredits {
    static var text: NSAttributedString {
        let body = """
        Pulli, created by Jahongirmirzo.
        Copyright © 2026 Jahongirmirzo.

        Free software under the GNU General Public License version 3 or later, with no warranty. \
        The licence and the licences of the libraries Pulli uses are in Pulli.app › Contents › \
        Resources › Licenses.
        """
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: body, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("introShown") private var introShown = false
    /// Changing the theme redraws the window in its colours.
    @AppStorage("theme") private var theme = AppTheme.porcelain.rawValue

    var body: some View {
        ZStack {
            MainWindow()
            if !introShown {
                IntroView { introShown = true }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .id(theme)
        .onOpenURL { model.handle(url: $0) }
        .onAppear {
            StatusMenu.openActivityWindow = { [openWindow] in openWindow(id: "activity") }
            AppDelegate.openMainWindow = { [openWindow] in
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate()
            }
            // Opened by macOS at login: put the window away and just watch for phones.
            if LoginItem.launchedAtLogin, !LoginItem.handledLaunch {
                LoginItem.handledLaunch = true
                NSApp.setActivationPolicy(.accessory)
                // Closed on the next turn of the run loop: a window closed while it is still
                // appearing stays open.
                DispatchQueue.main.async { dismissWindow(id: "main") }
                return
            }
            NSApp.setActivationPolicy(.regular)
            model.setWindowVisible(true)
        }
        .onDisappear { model.setWindowVisible(false) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    /// Opens (or brings back) the main window from outside it (a phone arriving in the background).
    @MainActor static var openMainWindow: (() -> Void)?
#if !PULLI_APP_STORE
    @MainActor static var updaterController: SPUStandardUpdaterController? {
        get { Updates.shared.controller }
        set { Updates.shared.controller = newValue }
    }
    @MainActor static let postponer = RelaunchPostponer()

    private var updaterController: SPUStandardUpdaterController?
    private var userDriverDelegate: UpdateDriverDelegate?

    static var shouldEnableUpdater: Bool {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return false }
        if CommandLine.arguments.contains("--mock") || ProcessInfo.processInfo.environment["PULLI_MOCK"] == "1" { return false }
        if CommandLine.arguments.contains("--snapshot") || CommandLine.arguments.contains("--readme-frames") || CommandLine.arguments.contains("--themes")
            || CommandLine.arguments.contains("--art-poses") || CommandLine.arguments.contains("--flyer")
            || CommandLine.arguments.contains("--dmg-background") || CommandLine.arguments.contains("--icon") { return false }
        if NSClassFromString("XCTest") != nil || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty else { return false }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else { return false }
        return true
    }
#endif

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LoginItem.readLaunchEvent() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The engine starts with the app, not with the window (which a login launch never shows).
        MainActor.assumeIsolated {
#if !PULLI_APP_STORE
            LegacyMigration.run()
            InstallLocation.cleanUpOldRelayAppIfNeeded()
#endif
            LoginItem.reregisterIfMoved()
            StatusMenu.install()
            UNUserNotificationCenter.current().delegate = self
            Self.hideDockIconWhenWindowsClose()
#if !PULLI_APP_STORE
            if Self.model?.mock == false { WidgetFeed.restartIfStale() }
            if Self.shouldEnableUpdater {
                let driverDelegate = UpdateDriverDelegate()
                self.userDriverDelegate = driverDelegate
                let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: driverDelegate)
                self.updaterController = controller
                Self.updaterController = controller
            }
#endif
            guard let model = Self.model else { return }
            Task {
                // Finder locations left by a crash or a forced quit (phones that may be gone):
                // each phone's location is added again when it is opened in Finder.
                await FinderLocation.removeAll()
                await model.start()
            }
            // PULLI_SHOW_FINDER_TUTORIAL=1: show the Finder switch tutorial (to check its design).
            if ProcessInfo.processInfo.environment["PULLI_SHOW_FINDER_TUTORIAL"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    UserDefaults.standard.removeObject(forKey: "finderLocationApprovalDismissed")
                    model.finderLocationNeedsApproval = true
                }
            }
        }
    }

    /// A Pulli window someone can see and use (not the menu bar item's own panel or window).
    @MainActor static var hasOpenWindow: Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }

    /// Closing the last window (the red button) leaves Pulli in the menu bar only, as when it
    /// opens at login: no Dock icon until a window opens again (`openMainWindow` brings it back).
    /// Without the menu bar item the Dock icon stays, or there would be no way back in.
    @MainActor private static func hideDockIconWhenWindowsClose() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain, !(closing is NSPanel) else { return }
            // On the next turn: the closing window still counts as visible now, and a window that
            // is only being rebuilt (a theme change) is back by then.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true else { return }
                    if !hasOpenWindow { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keeps running for the menu bar item's progress, and to watch for phones when it opens
        // at login.
        MainActor.assumeIsolated {
            !((UserDefaults.standard.object(forKey: "showMenuBar") as? Bool ?? true) || LoginItem.isEnabled)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Opened again from Finder, Spotlight or the Dock while running in the background.
        // `hasVisibleWindows` also counts the menu bar item's own window, so look for a real one.
        MainActor.assumeIsolated {
            if !Self.hasOpenWindow { Self.openMainWindow?() }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = MainActor.assumeIsolated({ Self.model }) else { return .terminateNow }
        // Let running copies commit what they have before the process ends.
        Task { @MainActor in
            await model.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

}

#if !PULLI_APP_STORE
// MARK: - SPUUpdaterDelegate

extension AppDelegate: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in
            await Self.model?.prepareForUpdate()
        }
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        MainActor.assumeIsolated {
            let active = Self.model.map { RelaunchPostponer.hasActiveCopies(in: Array($0.state.batches.values)) } ?? false
            if active {
                Self.model?.banner = "Pulli will update when this copy finishes."
            }
            return Self.postponer.handlePostpone(hasActiveCopies: active, installHandler: installHandler)
        }
    }
}
#endif

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: @MainActor UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let identifier = response.notification.request.identifier
            if identifier.hasPrefix("update-") || response.notification.request.content.userInfo["action"] as? String == "installUpdate" {
#if !PULLI_APP_STORE
                MainActor.assumeIsolated { Updates.shared.install() }
#endif
            }
        }
        completionHandler()
    }
}
