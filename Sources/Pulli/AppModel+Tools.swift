import AppKit
import Foundation
import PulliClient
import PulliProtocol
import SwiftUI

/// Freeing up space on the phone after a copy: check every file against the phone, confirm,
/// delete, summary (docs/DECISIONS.md, D-022).
struct FreeUpState: Sendable {
    enum Stage: Sendable {
        case checking
        case confirm
        case deleting
        case done(DeleteSummary)
        case failed(String)
    }

    var batchID: Int64
    var verifyID: UUID
    var progress: VerifyProgress?
    var stage: Stage
}

extension AppModel {
    // MARK: Progress from the engine

    func handleProgress(_ event: HelperEvent) {
        switch event {
        case .storageScan(let scan):
            guard scan.scanID == storageScanID else { return }
            storageScan = scan
        case .upload(let progress):
            uploads[progress.uploadID] = progress
            if progress.done {
                browseReloadToken += 1
                if progress.error == nil {
                    sounds.play(.done)
                    Notifier.post(title: "Copied to \(state.devices[progress.deviceID]?.name ?? "the phone")",
                                  body: "\(Format.count(progress.filesDone, "file")) · \(Format.bytes(progress.bytesDone)) in \(Format.place(progress.destination))")
                } else {
                    banner = "Copying to the phone stopped: \(progress.error ?? "")"
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.uploads[progress.uploadID] = nil
                }
            }
        case .verification(let progress):
            guard var current = freeUp, current.verifyID == progress.verifyID else { return }
            current.progress = progress
            if progress.done {
                if let error = progress.error {
                    current.stage = .failed(error)
                } else {
                    current.stage = .confirm
                    sounds.play(progress.problems.isEmpty ? .done : .attention)
                }
            }
            freeUp = current
        default:
            break
        }
    }

    // MARK: Phone screen extras

    /// After the phone screen shows: measure messaging-app media, and (when enabled) find which
    /// camera files are already on the Mac. Both walk or read more of the phone, so they come
    /// second.
    func enrichSummary(deviceID: String, storageID: UInt32) async {
        guard let client else { return }
        let paths = AppMedia.candidates.flatMap(\.2)
        if case .measured(let results)? = try? await client.send(.measure(deviceID: deviceID, storageID: storageID, paths: paths), timeout: .seconds(600)) {
            var apps: [AppMedia] = []
            for (pick, name, candidates) in AppMedia.candidates {
                guard let found = candidates.lazy.compactMap({ path in results.first { $0.path == path && $0.exists && $0.files > 0 } }).first else { continue }
                apps.append(AppMedia(pick: pick, name: name, path: found.path, files: found.files, bytes: found.bytes))
            }
            withAnimation(.easeOut(duration: 0.3)) { summaries[deviceID]?.apps = apps }
        }
        await refreshDuplicates(deviceID: deviceID, storageID: storageID)
        autoCopyIfWanted(deviceID: deviceID)
    }

    /// Which camera files are already on the Mac. Run when the phone's summary loads, and again
    /// after a copy from it finishes, so the overview stops offering what was just copied
    /// (it said "4 already on your Mac" right after copying all 92).
    func refreshDuplicates(deviceID: String, storageID: UInt32) async {
        guard UserDefaults.standard.object(forKey: "skipDuplicates") as? Bool ?? true,
              let camera = summaries[deviceID]?.camera, !camera.files.isEmpty else { return }
        let paths = camera.files.map { camera.path + "/" + $0.name }
        let matches = await findDuplicates(deviceID: deviceID, storageID: storageID, paths: paths)
        let set = Set(matches.map(\.path))
        let bytes = camera.files.filter { set.contains(camera.path + "/" + $0.name) }.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        summaries[deviceID]?.cameraDuplicateBytes = bytes
        summaries[deviceID]?.cameraDuplicates = set
    }

    /// Settings › Copy new photos when a phone connects: only for phones Pulli copied before (it
    /// knows what "new" means for them), and never while another copy of that phone is running.
    private func autoCopyIfWanted(deviceID: String) {
        guard UserDefaults.standard.bool(forKey: "autoCopyNew"), let summary = summaries[deviceID], summary.cameraMark != nil,
              !summary.newItems.isEmpty, selectedDeviceID == deviceID,
              !state.batches.values.contains(where: { $0.deviceID == deviceID && AppModel.isActive($0) }) else { return }
        picks = [.new]
        Notifier.post(title: "Copying \(Format.count(summary.newItems.count, "new item")) from \(device?.name ?? "the phone")",
                      body: "\(Format.bytes(summary.newBytes)) to \(Format.place(destination))")
        Task { await copyPicks() }
    }

    func findDuplicates(deviceID: String, storageID: UInt32, paths: [String]) async -> [DuplicateMatch] {
        guard let client, !paths.isEmpty else { return [] }
        let pictures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path
        let folders = Array(Set([destination, pictures]))
        guard case .duplicates(let matches)? = try? await client.send(
            .findDuplicates(deviceID: deviceID, storageID: storageID, paths: paths, macFolders: folders), timeout: .seconds(600)) else { return [] }
        return matches
    }

    // MARK: Storage map

    func openStorageMap() {
        navTransition = .forward
        withAnimation(.pulliNavigation) { showingStorageMap = true }
        if storageScan == nil || storageScan?.root.path != "/" || storageScanID == nil { rescanStorage() }
    }

    func closeStorageMap() {
        navTransition = .back
        withAnimation(.pulliNavigation) { showingStorageMap = false }
    }

    func rescanStorage() {
        guard let client, let device, let storage = device.storages.first else { return }
        if let old = storageScanID { Task { _ = try? await client.send(.cancelScan(scanID: old)) } }
        let id = UUID()
        storageScanID = id
        storageScan = nil
        Task { _ = try? await client.send(.scanStorage(deviceID: device.id, storageID: storage.id, scanID: id)) }
    }

    // MARK: Quick Look

    /// Previews a phone file with macOS Quick Look: the file is fetched into Pulli's cache first
    /// (at the cable's speed), then Space shows it like any file in Finder.
    func quickLook(_ entry: FolderEntry, at path: String) {
        fetchToCache(entry, at: path) { QuickLookPanel.shared.show($0) }
    }

    /// Opens a phone file in its usual app, straight from the phone: it is streamed into Pulli's
    /// cache (nothing to manage), then opened. Changes made there stay on the Mac.
    func openFile(_ entry: FolderEntry, at path: String, with app: URL? = nil) {
        fetchToCache(entry, at: path) { local in
            if let app {
                NSWorkspace.shared.open([local], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(local)
            }
        }
    }

    private func fetchToCache(_ entry: FolderEntry, at path: String, then use: @escaping @MainActor (URL) -> Void) {
        guard let client, let device, let storage = device.storages.first else { return }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(PulliApp.bundleID)/QuickLook/\(device.id.replacingOccurrences(of: ":", with: "_"))", isDirectory: true)
        let local = caches.appendingPathComponent(String(path.drop { $0 == "/" }))
        if let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, UInt64(size) == entry.sizeBytes {
            use(local)
            return
        }
        quickLookLoading = entry.name
        Task {
            defer { quickLookLoading = nil }
            do {
                _ = try await client.send(.fetchFile(deviceID: device.id, storageID: storage.id, path: path, destination: local.path), timeout: .seconds(1_800))
                use(local)
            } catch {
                banner = "Could not open \(entry.name): \(Self.describe(error))"
            }
        }
    }

    /// Copies phone items into a folder the user picks (the list's right-click menu).
    func copy(_ paths: [String], chooseFolder: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await copy(paths: paths, destination: folder.path) }
    }

    // MARK: Mac to phone

    func upload(_ urls: [URL], to folder: String) {
        guard let client, let device, let storage = device.storages.first, !urls.isEmpty else { return }
        let id = UUID()
        uploads[id] = UploadProgress(uploadID: id, deviceID: device.id, destination: folder, filesDone: 0, filesTotal: urls.count,
                                     bytesDone: 0, bytesTotal: 0, current: urls.first?.lastPathComponent, done: false, error: nil)
        sounds.play(.start)
        Task {
            do {
                _ = try await client.send(.upload(deviceID: device.id, storageID: storage.id, localPaths: urls.map(\.path), destination: folder, uploadID: id))
            } catch {
                uploads[id] = nil
                banner = "Could not copy to the phone: \(Self.describe(error))"
            }
        }
    }

    func chooseFilesToUpload(to folder: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Copy to Phone"
        panel.message = "Choose files or folders to copy to \((folder as NSString).lastPathComponent) on \(device?.name ?? "the phone")"
        if panel.runModal() == .OK { upload(panel.urls, to: folder) }
    }

    // MARK: Free up space

    func startFreeUp(_ batch: BatchSnapshot) {
        guard let client else { return }
        let id = UUID()
        navTransition = .forward
        withAnimation(.pulliNavigation) {
            focusedBatchID = batch.id
            freeUp = FreeUpState(batchID: batch.id, verifyID: id, progress: nil, stage: .checking)
            section = .copies
        }
        Task {
            do {
                _ = try await client.send(.verify(batchID: batch.id, verifyID: id))
            } catch {
                freeUp?.stage = .failed(Self.describe(error))
            }
        }
    }

    /// Deletes the originals the check found identical. Only reachable from the confirmation,
    /// after the user ticked "I understand".
    func confirmFreeUp() {
        guard let client, let current = freeUp, case .confirm = current.stage else { return }
        freeUp?.stage = .deleting
        Task {
            do {
                guard case .deleted(let summary) = try await client.send(.deleteVerified(batchID: current.batchID), timeout: .seconds(600)) else { return }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { freeUp?.stage = .done(summary) }
                sounds.play(.done)
                Notifier.post(title: "\(Format.bytes(summary.bytesFreed)) freed on the phone",
                              body: "\(Format.count(summary.deleted, "original")) deleted after checking their copies on your Mac.")
                if let device { loadSummary(device) }
            } catch {
                freeUp?.stage = .failed(Self.describe(error))
            }
        }
    }

    func closeFreeUp() {
        navTransition = .back
        withAnimation(.pulliNavigation) { freeUp = nil }
    }
}
