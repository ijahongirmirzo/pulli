import AppKit
import Foundation
import Observation
import PulliClient
import PulliHost
import PulliProtocol
import SwiftUI
import WorkerIPC

/// The quick picks on the phone screen.
enum PhonePick: String, CaseIterable, Identifiable, Sendable {
    case new, camera, screenshots, downloads
    /// Media folders of messaging apps (owner request, 2026-09-27).
    case whatsapp, telegram, instagram, viber
    var id: String { rawValue }

    static let apps: [PhonePick] = [.whatsapp, .telegram, .instagram, .viber]
}

/// A messaging app's media folder on the phone, measured (whole tree).
struct AppMedia: Sendable, Identifiable {
    var pick: PhonePick
    var name: String
    var path: String
    var files: Int
    var bytes: UInt64
    var id: PhonePick { pick }

    /// Where each app keeps its media: the Android 11+ location first, then the older one.
    static let candidates: [(PhonePick, String, [String])] = [
        (.whatsapp, "WhatsApp media", ["/Android/media/com.whatsapp/WhatsApp/Media", "/WhatsApp/Media"]),
        (.telegram, "Telegram", ["/Android/media/org.telegram.messenger/Telegram", "/Telegram"]),
        (.instagram, "Instagram", ["/Pictures/Instagram", "/DCIM/Instagram"]),
        (.viber, "Viber", ["/Android/media/com.viber.voip/Viber", "/Viber"]),
    ]
}

/// What the phone screen shows about a phone: its well-known folders, counted.
struct PhoneSummary: Sendable {
    struct Folder: Sendable {
        var path: String
        var files: [FolderEntry]
        var folderCount: Int
        /// Computed once: the phone screen reads it on every render.
        let bytes: UInt64

        init(path: String, files: [FolderEntry], folderCount: Int) {
            self.path = path
            self.files = files
            self.folderCount = folderCount
            bytes = files.reduce(0) { $0 + $1.sizeBytes }
        }
    }

    var storageID: UInt32
    var camera: Folder?
    var screenshots: Folder?
    var downloads: Folder?
    /// The newest camera item copied last time (phone wall clock), if Pulli copied Camera before.
    var cameraMark: Int64? { didSet { updateNewItems() } }
    /// Messaging-app media found on the phone (measured after the rest, as it walks whole trees).
    var apps: [AppMedia] = []
    /// Camera files whose content is already on the Mac (by content, any name), when checked.
    var cameraDuplicates: Set<String> = [] { didSet { updateNewItems() } }
    var cameraDuplicateBytes: UInt64 = 0
    /// Camera items newer than `cameraMark`, and their size.
    private(set) var newItems: [FolderEntry] = []
    private(set) var newBytes: UInt64 = 0

    init(storageID: UInt32, camera: Folder?, screenshots: Folder?, downloads: Folder?, cameraMark: Int64?) {
        self.storageID = storageID
        self.camera = camera
        self.screenshots = screenshots
        self.downloads = downloads
        self.cameraMark = cameraMark
        updateNewItems()
    }

    private mutating func updateNewItems() {
        guard let camera, let cameraMark else {
            newItems = []
            newBytes = 0
            return
        }
        newItems = camera.files.filter { $0.modifiedWallClock > cameraMark && !cameraDuplicates.contains(camera.path + "/" + $0.name) }
        newBytes = newItems.reduce(0) { $0 + $1.sizeBytes }
    }
}

@MainActor
@Observable
final class AppModel {
    enum Section: Hashable { case phone, copies, history, attention }
    enum Connection: Equatable { case starting, embedded, helper, failed(String) }

    var state = PulliState()
    var connection: Connection = .starting
    var section: Section = .phone
    var selectedDeviceID: String?
    /// Non-nil while browsing a folder on the phone (the Choose screen).
    var browsePath: String?
    /// Where browsing started (a card's folder, or the top of the phone): Back from here returns
    /// to the phone screen, not to the folder's parent.
    var browseRoot: String?
    /// How the next screen change animates (set by the navigation methods below).
    var navTransition: NavTransition = .fade
    var focusedBatchID: Int64?
    var summaries: [String: PhoneSummary] = [:]
    var picks: Set<PhonePick> = []
    var destinationOverride: String?
    /// A short message shown at the top of the window (errors from requests).
    var banner: String?
    /// "myGalaxy connected", shown for a few seconds when a phone becomes ready.
    var connectedNote: String?
    /// When each phone last disappeared (a mode switch re-attaches it: no second chime).
    @ObservationIgnored private var recentlyGone: [String: Date] = [:]
    var showingCableHelp = false
    /// The storage map is showing (phone section).
    var showingStorageMap = false
    var storageScan: StorageScan?
    @ObservationIgnored var storageScanID: UUID?
    /// Copies from the Mac to the phone, running or just finished.
    var uploads: [UUID: UploadProgress] = [:]
    /// Freeing up space after a copy (copies section).
    var freeUp: FreeUpState?
    /// The file being fetched for Quick Look.
    var quickLookLoading: String?
    /// Bumped when a folder's contents changed (an upload finished): the Choose list reloads.
    var browseReloadToken = 0
    /// Items dragged out to Finder being delivered (kept alive until their copy finishes).
    @ObservationIgnored var dragOuts: Set<DragOut> = []
    /// "Copying 3 items to Desktop…" while a drag-out is delivered.
    var dragOutNotice: String?
    /// A short confirmation ("Copied 3 items…"), cleared after a few seconds.
    var toast: String?
    /// Phones mounted in Finder, by device ID: where their volume is.
    var finderMounts: [String: URL] = [:]
    /// Phones shown as Finder locations, by device ID: their folder on disk.
    var finderLocations: [String: URL] = [:]
    /// A phone whose Finder location failed its check and repair, showing the fallback note.
    var finderTrouble: String?
    /// Phones whose Finder location has already undergone an automatic repair during this run.
    @ObservationIgnored var repairedPhones: Set<String> = []
    /// Pulli needs approval in System Settings › Login Items & Extensions › File Providers.
    var finderLocationNeedsApproval = false {
        didSet {
            if finderLocationNeedsApproval {
                presentFinderLocationApprovalSheetIfNeeded()
            }
        }
    }
    var driveStatus: String?
    /// Why the background helper is not in use although it is turned on (shown in Settings).
    var helperProblem: String?
    /// Folder listings used instead of the phone (screen snapshots).
    @ObservationIgnored var previewListings: [String: [FolderEntry]] = [:]
    /// How the Choose list shows and sorts a folder (as Finder's View options); remembered.
    var browseOptions = BrowseOptions.saved {
        didSet { if !isPreview, browseOptions != oldValue { browseOptions.save() } }
    }
    @ObservationIgnored private var isPreview = false

    @ObservationIgnored let mock: Bool
    @ObservationIgnored let sounds = SoundPlayer()
    @ObservationIgnored private(set) var client: PulliClient?
    @ObservationIgnored private var embedded: EmbeddedEngine?
    @ObservationIgnored private var receivedFirstState = false
    @ObservationIgnored private var summaryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingMarks: [Int64: (device: String, mark: Int64)] = [:]
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Notices when the helper's connection ends.
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// The phone's previews of photos and videos, cached.
    @ObservationIgnored private(set) lazy var thumbnails = Thumbnails { [weak self] deviceID, storageID, path in
        await self?.fetchThumbnail(deviceID: deviceID, storageID: storageID, path: path)
    }
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private let widgetFeed = WidgetFeed()

    /// Journal file for the in-app engine; nil uses Application Support (tests pass a temporary one).
    @ObservationIgnored let journalURL: URL?

    init(mock: Bool, journalURL: URL? = nil) {
        self.mock = mock
        self.journalURL = journalURL
    }

    /// A model with fixed state and no engine (snapshots of the screens).
    init(preview state: PulliState, summaries: [String: PhoneSummary] = [:]) {
        mock = true
        journalURL = nil
        isPreview = true
        browseOptions = BrowseOptions()
        self.state = state
        self.summaries = summaries
        connection = .embedded
        selectedDeviceID = state.devices.keys.sorted().first
        picks = [.new]
    }

    // MARK: Connection

    /// Connects to the background helper when it is turned on, otherwise runs the engine here.
    /// A helper that cannot be reached (launchd refused it, or it keeps crashing) never leaves the
    /// app without an engine: Pulli repairs the registration once, then falls back to the engine
    /// inside the app.
    func start() async {
        guard client == nil else { return }
        Self.cleanIncoming()
        connection = .starting
        helperProblem = nil
#if !PULLI_APP_STORE
        if HelperRegistration.isEnabled, !mock {
            if await connectToHelper() { return }
            // A rebuilt or moved app has a new code signature; launchd will not start the old
            // registration. Registering again usually fixes it.
            HelperRegistration.repair()
            if await connectToHelper() { return }
            helperProblem = "The background helper is not responding, so copies run inside Pulli for now."
        }
#endif
        do {
            let engine = try await EmbeddedEngine.start(mock: mock, workerURL: Self.workerURL, version: Self.version, journalURL: journalURL)
            embedded = engine
            if await attach(engine.connection, mode: .embedded) { return }
            await engine.stop()
            embedded = nil
            connection = .failed("Pulli could not talk to its copy engine.")
        } catch .helperRunning {
#if !PULLI_APP_STORE
            if await connectToHelper() { return }
#endif
            connection = .failed("Another copy of Pulli's engine is running but not answering. Quit Pulli and open it again.")
        } catch {
            connection = .failed(error.description)
        }
    }

    private func connectToHelper() async -> Bool {
        guard let xpc = try? XPCHelperConnection(timeout: .seconds(3)) else { return false }
        guard await attach(xpc, mode: .helper) else { return false }
        // A helper from another build (still running after Pulli was updated or rebuilt) does not
        // know this build's requests: ask it to quit, and connect again to the one launchd starts
        // from this bundle.
        if let hello = await client?.helper, hello.helperVersion != Self.version || hello.minor < PulliProtocolVersion.minor {
            _ = try? await client?.send(.prepareForUpdate)
            await detach()
            try? await Task.sleep(for: .seconds(1))
            guard let fresh = try? XPCHelperConnection(timeout: .seconds(5)) else { return false }
            return await attach(fresh, mode: .helper)
        }
        return true
    }

    private func detach() async {
        watcher?.cancel()
        watcher = nil
        pump?.cancel()
        pump = nil
        await client?.stop()
        client = nil
    }

    /// The helper went away (crashed, or was replaced): connect again, to it or to the engine here.
    private func connectionLost() async {
        guard connection == .helper else { return }
        await detach()
        receivedFirstState = false
        try? await Task.sleep(for: .seconds(1))
        await start()
    }

    private func attach(_ connection: any HelperConnection, mode: Connection) async -> Bool {
        let client = PulliClient(connection: connection)
        let (stream, continuation) = AsyncStream<PulliState>.makeStream()
        do {
            try await client.start(clientName: "Pulli") { continuation.yield($0) }
        } catch {
            await client.stop()
            return false
        }
        self.client = client
        self.connection = mode
        let ended = await client.eventsEnded
        pump = Task { [weak self] in
            for await state in stream { self?.apply(state) }
        }
        watcher = Task { [weak self] in
            await ended()
            guard !Task.isCancelled else { return }
            await self?.connectionLost()
        }
        _ = try? await client.send(.setWatchingDevices(windowVisible))
        await client.setProgressHandler { [weak self] event in
            Task { @MainActor in self?.handleProgress(event) }
        }
        return true
    }

    /// While the window is closed (Pulli lives on in the menu bar), phones are only opened when a
    /// copy needs them, so Pulli does not keep them from Photos or other apps.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        updateWatching()
        if !visible {
            // Nothing shows them now: give the memory back.
            thumbnails.clearMemory()
            SceneBaker.purge()
        }
    }

    /// Phones are watched while the window is open, and always when Pulli opens at login.
    func updateWatching() {
        let watching = windowVisible || LoginItem.isEnabled
        Task { _ = try? await client?.send(.setWatchingDevices(watching)) }
    }

    /// A phone plugged in while Pulli has no window: bring it forward, or say so.
    private func phoneArrivedInBackground(_ device: DeviceSnapshot) {
        if UserDefaults.standard.object(forKey: "openOnConnect") as? Bool ?? true {
            selectedDeviceID = device.id
            AppDelegate.openMainWindow?()
        } else {
            Notifier.post(title: "\(device.name) connected", body: "Open Pulli to copy its photos and files.")
        }
    }

    /// Stops the in-app engine at a clean point (app quit).
    func shutdown() async {
        let locationIDs = Array(finderLocations.keys)
        for id in locationIDs { await removeFinderLocation(id) }
        for id in finderMounts.keys { unmountFinderDrive(id) }
        await FinderLocation.removeAll()
        watcher?.cancel()
        pump?.cancel()
        await client?.stop()
        await embedded?.stop()
        client = nil
        embedded = nil
    }

    /// Shows the File Provider approval sheet if the user has not dismissed it before.
    func presentFinderLocationApprovalSheetIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "finderLocationApprovalDismissed") else { return }
        FinderLocationApprovalPresenter.show(
            onDismiss: { [weak self] in
                UserDefaults.standard.set(true, forKey: "finderLocationApprovalDismissed")
                self?.finderLocationNeedsApproval = false
            },
            onOpenSettings: {
                if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            },
            isEnabled: { await FinderLocation.isExtensionEnabled() },
            onEnabled: { [weak self] in
                self?.finderLocationNeedsApproval = false
                self?.openInFinder()
            }
        )
    }

    /// After turning the background helper on or off: reconnect to wherever the engine now runs.
    func reconnect() async {
        await shutdown()
        receivedFirstState = false
        await start()
    }

    static var workerURL: URL { WorkerConnector.besideCurrentExecutable("pulli-mtp-worker") }

    static var version: String { PulliProtocolVersion.build }
    static var commit: String? { PulliProtocolVersion.commit }

    /// Asks the helper to prepare for an update and exit cleanly.
    func prepareForUpdate() async {
        _ = try? await client?.send(.prepareForUpdate)
    }

    // MARK: State

    private func apply(_ new: PulliState) {
#if !PULLI_APP_STORE
        AppDelegate.postponer.batchesDidUpdate(
            hasActiveCopies: RelaunchPostponer.hasActiveCopies(in: Array(new.batches.values))
        ) { [weak self] in
            await self?.prepareForUpdate()
            if self?.banner == "Pulli will update when this copy finishes." {
                self?.banner = nil
            }
        }
#endif
        // Screen changes caused by the phone or the engine crossfade; only the user's own
        // navigation slides.
        if navTransition != .fade { navTransition = .fade }
        let old = state
        state = new
        if receivedFirstState {
            playCues(from: old, to: new)
            if !windowVisible {
                for device in new.devices.values where old.devices[device.id] == nil { phoneArrivedInBackground(device) }
            }
        } else {
            receivedFirstState = true
        }
        if !mock { widgetFeed.update(from: self) }

        if let focused = focusedBatchID, new.batches[focused] == nil {
            focusedBatchID = nil
        }

        if selectedDeviceID.map({ new.devices[$0] == nil }) ?? true {
            selectedDeviceID = new.devices.values.sorted { $0.name < $1.name }.first?.id
            browsePath = nil
            browseRoot = nil
        }
        for device in new.devices.values where device.state == .ready && summaries[device.id] == nil && summaryTasks[device.id] == nil {
            loadSummary(device)
        }
        let disconnected = Set(finderMounts.keys).union(finderLocations.keys).filter { new.devices[$0] == nil }
        for id in disconnected { unmountFinderDrive(id) }
        for id in old.devices.keys where new.devices[id] == nil {
            repairedPhones.remove(id)
            if finderTrouble == id { finderTrouble = nil }
        }
        for id in summaries.keys where new.devices[id] == nil {
            summaries[id] = nil
            summaryTasks.removeValue(forKey: id)?.cancel()
        }
#if PULLI_APP_STORE
        for (id, oldBatch) in old.batches {
            if let newBatch = new.batches[id] {
                if Self.isActive(oldBatch) && !Self.isActive(newBatch) {
                    SandboxBookmark.shared.stopAccessing(path: newBatch.destinationPath)
                }
            } else if Self.isActive(oldBatch) {
                SandboxBookmark.shared.stopAccessing(path: oldBatch.destinationPath)
            }
        }
#endif
        // A copy finished: what is already on the Mac changed for that phone.
        for batch in new.batches.values where batch.phase == .completed && old.batches[batch.id]?.phase != .completed {
            if let storageID = summaries[batch.deviceID]?.storageID {
                Task { await refreshDuplicates(deviceID: batch.deviceID, storageID: storageID) }
            }
        }
        for (id, pending) in pendingMarks {
            guard let batch = new.batches[id] else { continue }
            if batch.phase == .completed {
                UserDefaults.standard.set(pending.mark, forKey: "cameraMark.\(pending.device)")
                pendingMarks[id] = nil
                summaries[pending.device]?.cameraMark = pending.mark
            } else if batch.phase == .cancelled {
                pendingMarks[id] = nil
            }
        }
    }

    /// "myGalaxy connected": a short note in the window, and a notification when Pulli is not
    /// in front: the confirmation that the phone is ready to copy from.
    private func announceConnected(_ device: DeviceSnapshot) {
        let note = "\(device.name) connected · ready to copy"
        withAnimation(.easeOut(duration: 0.3)) { connectedNote = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, connectedNote == note else { return }
            withAnimation(.easeIn(duration: 0.3)) { connectedNote = nil }
        }
        Notifier.post(title: "\(device.name) connected", body: "Ready to copy its photos and files.")
    }

    private func playCues(from old: PulliState, to new: PulliState) {
        var cues: [SoundPlayer.Cue] = []
        // The chime when the phone is plugged in and seen, in whatever mode (before File transfer
        // is chosen on it): the user hears Pulli noticed. Ready later: the note, no second chime.
        // A phone switching USB mode drops off the bus for a moment: back within 10 s, no chime.
        let now = Date()
        for id in old.devices.keys where new.devices[id] == nil { recentlyGone[id] = now }
        for device in new.devices.values where old.devices[device.id] == nil {
            if let gone = recentlyGone[device.id], now.timeIntervalSince(gone) < 10 { continue }
            cues.append(.connect)
        }
        for device in new.devices.values where device.state == .ready && old.devices[device.id]?.state != .ready {
            announceConnected(device)
            // PULLI_E2E_OPEN_FINDER=1: open each phone in Finder once it is ready (end-to-end tests).
            if ProcessInfo.processInfo.environment["PULLI_E2E_OPEN_FINDER"] == "1" {
                selectedDeviceID = device.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.openInFinder() }
            }
        }
        for batch in new.batches.values {
            let before = old.batches[batch.id]?.phase
            switch (before, batch.phase) {
            case (nil, .copying), (nil, .scanning):
                cues.append(.start)
            case (.copying?, .paused(let reason)), (.scanning?, .paused(let reason)):
                if reason != .queued { cues.append(.pause) }
                if reason == .phoneDisconnected {
                    Notifier.post(title: "Copy paused", body: "Reconnect \(batch.deviceName) to continue. Nothing is lost.")
                }
            case (.paused?, .copying):
                cues.append(.resume)
            case (let previous?, .completed) where previous != .completed:
                cues.append(batch.filesNeedingAttention > 0 ? .attention : .done)
                Notifier.post(title: batch.filesNeedingAttention > 0 ? "Copy finished · \(batch.filesNeedingAttention) need attention" : "Copy finished",
                              body: "\(Format.count(batch.filesDone, "file")) · \(Format.bytes(batch.bytesDone)) from \(batch.deviceName) are on your Mac.")
            default:
                break
            }
        }
        let priority: [SoundPlayer.Cue] = [.done, .attention, .pause, .resume, .start, .connect]
        if let cue = priority.first(where: cues.contains) { sounds.play(cue) }
    }

    var device: DeviceSnapshot? { selectedDeviceID.flatMap { state.devices[$0] } }

    var sortedDevices: [DeviceSnapshot] { state.devices.values.sorted { $0.name < $1.name } }

    /// The copy the Copies section shows.
    var focusedBatch: BatchSnapshot? {
        if let id = focusedBatchID, let batch = state.batches[id] { return batch }
        return state.batchesForMenu.first { Self.isActive($0) } ?? state.batches.values.max { $0.createdAt < $1.createdAt }
    }

    /// A copy that is running or waiting (drives the pie on the Copies tile).
    var activeBatch: BatchSnapshot? { state.batchesForMenu.first(where: Self.isActive) }

    static func isActive(_ batch: BatchSnapshot) -> Bool {
        switch batch.phase {
        case .copying, .scanning, .paused: true
        default: false
        }
    }

    var attentionCount: Int { state.batches.values.reduce(0) { $0 + $1.filesNeedingAttention } }

    var destination: String {
        if let destinationOverride { return destinationOverride }
        if let saved = state.settings.defaultDestination { return saved }
#if PULLI_APP_STORE
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Pulli").path
#else
        // Downloads › the phone's name, until another folder is chosen in Settings.
        let name = (device?.name ?? "Phone").replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/\(name)").path
#endif
    }

    // MARK: Navigation

    enum NavTransition: Equatable {
        /// Crossfade: changes that come from the phone or the engine, not from the user.
        case fade
        /// Moving down the sidebar: the content scrolls up; moving up: it scrolls down.
        case up, down
        /// Into a folder, and back out.
        case forward, back
    }

    private static func order(_ section: Section) -> Int {
        switch section {
        case .phone: 0
        case .copies: 1
        case .history: 2
        case .attention: 3
        }
    }

    /// Switches sidebar sections (vertical slide). Choosing the phone again leaves a folder.
    func show(_ new: Section) {
        guard new != section else {
            if new == .phone, browsePath != nil { closeBrowser() }
#if !PULLI_APP_STORE
            if new == .phone, showingStorageMap { closeStorageMap() }
#endif
            return
        }
        navTransition = Self.order(new) > Self.order(section) ? .up : .down
        withAnimation(.pulliNavigation) {
            section = new
            if new == .phone {
                browsePath = nil
                browseRoot = nil
                showingStorageMap = false
            }
        }
    }

    /// Opens a folder from the phone screen (a card's Review, or Browse): Back comes back here.
    func openBrowser(at path: String) {
        navTransition = .forward
        withAnimation(.pulliNavigation) {
            browseRoot = path
            browsePath = path
        }
    }

    /// Moves within the browser: deeper is forward, shallower is back.
    func browse(to path: String) {
        guard let current = browsePath, path != current else { return }
        navTransition = depth(path) > depth(current) ? .forward : .back
        withAnimation(.pulliNavigation) {
            if let root = browseRoot, !(path == root || path.hasPrefix(root == "/" ? "/" : root + "/")) { browseRoot = path }
            browsePath = path
        }
    }

    /// Back: to the parent folder, or to the phone screen from where browsing started.
    func goBack() {
        guard let current = browsePath else { return }
        let parent = (current as NSString).deletingLastPathComponent
        if current == browseRoot || current == "/" || parent.isEmpty {
            closeBrowser()
        } else {
            browse(to: parent)
        }
    }

    func closeBrowser() {
        navTransition = .back
        withAnimation(.pulliNavigation) {
            browsePath = nil
            browseRoot = nil
        }
    }

    /// Where Back leads, for its label.
    var backTitle: String? {
        guard let current = browsePath else { return nil }
        if current == browseRoot || current == "/" { return device?.name ?? "Phone" }
        let parent = (current as NSString).deletingLastPathComponent
        return parent == "/" ? "Internal storage" : (parent as NSString).lastPathComponent
    }

    private func depth(_ path: String) -> Int { path.split(separator: "/").count }

    // MARK: Phone summary

    func loadSummary(_ device: DeviceSnapshot) {
        guard let storage = device.storages.first else { return }
        let id = device.id
        let mark = UserDefaults.standard.object(forKey: "cameraMark.\(id)") as? Int64
        summaryTasks[id] = Task { [weak self] in
            guard let self else { return }
            async let camera = self.folder(id, storage.id, "/DCIM/Camera")
            async let screenshotsDCIM = self.folder(id, storage.id, "/DCIM/Screenshots")
            async let screenshotsPictures = self.folder(id, storage.id, "/Pictures/Screenshots")
            async let downloads = self.folder(id, storage.id, "/Download")
            var (cameraFolder, dcimShots, pictureShots, downloadFolder) = await (camera, screenshotsDCIM, screenshotsPictures, downloads)
            // Just after Allow a phone can answer with nothing at all for a moment. Camera and
            // Download exist on every Android phone, so both missing or empty means "not yet":
            // ask once more rather than show "0 files".
            if Self.isEmpty(cameraFolder), Self.isEmpty(downloadFolder) {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                async let camera = self.folder(id, storage.id, "/DCIM/Camera")
                async let screenshotsDCIM = self.folder(id, storage.id, "/DCIM/Screenshots")
                async let screenshotsPictures = self.folder(id, storage.id, "/Pictures/Screenshots")
                async let downloads = self.folder(id, storage.id, "/Download")
                (cameraFolder, dcimShots, pictureShots, downloadFolder) = await (camera, screenshotsDCIM, screenshotsPictures, downloads)
            }
            let summary = PhoneSummary(storageID: storage.id, camera: cameraFolder, screenshots: dcimShots ?? pictureShots,
                                       downloads: downloadFolder, cameraMark: mark)
            guard !Task.isCancelled else { return }
            self.summaries[id] = summary
            self.summaryTasks[id] = nil
            if self.selectedDeviceID == id {
                self.picks = !summary.newItems.isEmpty ? [.new] : (summary.camera != nil ? [.camera] : [])
            }
            await self.enrichSummary(deviceID: id, storageID: storage.id)
        }
    }

    private static func isEmpty(_ folder: PhoneSummary.Folder?) -> Bool {
        folder.map { $0.files.isEmpty && $0.folderCount == 0 } ?? true
    }

    private func folder(_ deviceID: String, _ storageID: UInt32, _ path: String) async -> PhoneSummary.Folder? {
        guard let client else { return nil }
        guard let stream = try? await client.listFolder(deviceID: deviceID, storageID: storageID, path: path) else { return nil }
        var files: [FolderEntry] = []
        var folders = 0
        for await page in stream {
            if page.error != nil { return nil }
            for entry in page.entries {
                if entry.isFolder { folders += 1 } else { files.append(entry) }
            }
        }
        return PhoneSummary.Folder(path: path, files: files, folderCount: folders)
    }

    /// Lists one folder for the Choose screen, page by page.
    func list(_ path: String) async -> AsyncStream<PulliClient.FolderPage>? {
        guard let client, let device, let storage = device.storages.first else { return nil }
        return try? await client.listFolder(deviceID: device.id, storageID: storage.id, path: path)
    }

    /// Paths and bytes the phone screen's current picks would copy.
    func pickedItems() -> (paths: [String], bytes: UInt64, count: Int) {
        guard let device, let summary = summaries[device.id] else { return ([], 0, 0) }
        var paths: [String] = []
        var bytes: UInt64 = 0
        var count = 0
        if picks.contains(.camera), let camera = summary.camera {
            if summary.cameraDuplicates.isEmpty {
                paths.append(camera.path)
            } else {
                // Leave out what is already on the Mac (Settings › Skip files already on my Mac).
                paths += camera.files.map { camera.path + "/" + $0.name }.filter { !summary.cameraDuplicates.contains($0) }
            }
            bytes += camera.bytes - summary.cameraDuplicateBytes
            count += camera.files.count - summary.cameraDuplicates.count
        } else if picks.contains(.new), let camera = summary.camera {
            let items = summary.newItems
            paths += items.map { camera.path + "/" + $0.name }
            bytes += summary.newBytes
            count += items.count
        }
        for (pick, folder) in [(PhonePick.screenshots, summary.screenshots), (.downloads, summary.downloads)] {
            guard picks.contains(pick), let folder else { continue }
            paths.append(folder.path)
            bytes += folder.bytes
            count += folder.files.count
        }
        for app in summary.apps where picks.contains(app.pick) {
            paths.append(app.path)
            bytes += app.bytes
            count += app.files
        }
        return (paths, bytes, count)
    }

    // MARK: Actions

    func copyPicks() async {
        guard let device, let summary = summaries[device.id] else { return }
        let picked = pickedItems()
        guard !picked.paths.isEmpty else { return }
        let includesCamera = picks.contains(.camera) || picks.contains(.new)
        let mark = summary.camera?.files.map(\.modifiedWallClock).max()
        if let id = await copy(paths: picked.paths, storageID: summary.storageID), includesCamera, let mark {
            pendingMarks[id] = (device.id, mark)
        }
    }

    /// Starts a copy. Drags to Finder pass their drop folder and stay on the current screen.
    @discardableResult
    func copy(paths: [String], storageID: UInt32? = nil, destination explicit: String? = nil, navigate: Bool = true) async -> Int64? {
        guard let client, let device, let storage = storageID ?? device.storages.first?.id else { return nil }
        let dest = explicit ?? destination
#if PULLI_APP_STORE
        SandboxBookmark.shared.startAccessing(path: dest)
#endif
        let request = CreateBatchRequest(deviceID: device.id, storageID: storage, paths: paths, destinationPath: dest,
                                         organize: explicit == nil ? state.settings.organize : nil)
        do {
            guard case .batchCreated(let id) = try await client.send(.createBatch(request)) else {
#if PULLI_APP_STORE
                SandboxBookmark.shared.stopAccessing(path: dest)
#endif
                return nil
            }
            guard navigate else { return id }
            focusedBatchID = id
            show(.copies)
            browsePath = nil
            browseRoot = nil
            return id
        } catch {
#if PULLI_APP_STORE
            SandboxBookmark.shared.stopAccessing(path: dest)
#endif
            banner = "Could not start the copy: \(Self.describe(error))"
            return nil
        }
    }

    func control(_ batchID: Int64, _ command: BatchCommand) async {
        guard let client else { return }
        do {
            _ = try await client.send(.control(batchID: batchID, command))
        } catch {
            banner = Self.describe(error)
        }
    }

    private func clearQuickLookCache() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(PulliApp.bundleID)/QuickLook", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Forgets past copies, activity log entries, and cached previews and thumbnails.
    func clearHistory() async {
        guard let client else { return }
        do {
            _ = try await client.send(.clearHistory)
        } catch {
            banner = Self.describe(error)
            return
        }

        clearQuickLookCache()
        let skipActive = dragOutNotice != nil || !uploads.isEmpty
        Self.clearIncoming(skippingActive: skipActive)
        thumbnails.clear()
        Notifier.removeAllDelivered()

        if let id = focusedBatchID, state.batches[id] == nil || state.batches[id]?.phase == .completed || state.batches[id]?.phase == .cancelled {
            focusedBatchID = nil
        }
        if !mock { widgetFeed.update(from: self) }
    }

    /// Accepts or declines a suggested read chunk size for a phone.
    func applyChunkSuggestion(deviceID: String, accept: Bool) async {
        guard let client else { return }
        do {
            _ = try await client.send(.applyChunkSuggestion(deviceID: deviceID, accept: accept))
        } catch {
            banner = Self.describe(error)
        }
    }

    func attention(_ batchID: Int64) async -> [AttentionItem] {
        guard let client, case .needsAttention(let items)? = try? await client.send(.needsAttention(batchID: batchID)) else { return [] }
        return items
    }

    private func fetchThumbnail(deviceID: String, storageID: UInt32, path: String) async -> Data? {
        guard let client, case .thumbnail(let data)? = try? await client.send(.thumbnail(deviceID: deviceID, storageID: storageID, path: path)) else {
            return nil
        }
        return data
    }

    func log(limit: Int = 500) async -> [LogEntry] {
        guard let client, case .log(let entries)? = try? await client.send(.log(afterID: nil, limit: limit)) else { return [] }
        return entries
    }

    /// Records an event in the activity log.
    func recordLog(_ message: String, level: Int = 2, kind: String = "finder_location") async {
        _ = try? await client?.send(.recordLog(level: level, kind: kind, message: message))
    }

    func update(_ settings: HelperSettings) async {
        guard let client else { return }
        _ = try? await client.send(.setSettings(settings))
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Pulli copies to"
        panel.directoryURL = URL(fileURLWithPath: destination).deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
#if PULLI_APP_STORE
            SandboxBookmark.shared.saveBookmark(for: url)
#endif
            destinationOverride = url.path
        }
    }

    func showInFinder(_ path: String) {
#if PULLI_APP_STORE
        SandboxBookmark.shared.startAccessing(path: path)
        defer { SandboxBookmark.shared.stopAccessing(path: path) }
#endif
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    static func describe(_ error: any Error) -> String {
        (error as? PulliError)?.message ?? "\(error)"
    }
}
