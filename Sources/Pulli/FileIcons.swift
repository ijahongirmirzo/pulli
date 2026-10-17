import AppKit
import CryptoKit
import PulliProtocol
import SwiftUI
import UniformTypeIdentifiers

/// Finder's own icon for a kind of file (PDF, Word, ZIP, APK, audio…), cached per extension.
@MainActor
enum SystemIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forName name: String, isFolder: Bool) -> NSImage {
        let key = isFolder ? "/folder" : (name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = isFolder ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}

/// The phone's previews of photos and videos (MTP GetThumb: a JPEG of a few kilobytes, tens of
/// milliseconds each over USB 2, far cheaper than reading the file).
///
/// Kept in memory and on disk (Caches), keyed by phone, path, size and date, so a folder opens
/// with its previews at once the second time and a changed file gets a new one. At most three
/// requests run together; a row that scrolls away before its turn is skipped. Files the phone has
/// no preview for are remembered too.
@MainActor
final class Thumbnails {
    private let memory = NSCache<NSString, NSImage>()
    private var none: Set<String> = []
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let fetch: (String, UInt32, String) async -> Data?
    private let folder: URL?

    static let limit = 3

    init(fetch: @escaping (String, UInt32, String) async -> Data?) {
        self.fetch = fetch
        memory.countLimit = 2_000
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(PulliApp.bundleID)/Thumbnails", isDirectory: true)
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    }

    static func hasPreview(_ name: String) -> Bool {
        switch KindThumb.kind(forName: name, isFolder: false) {
        case .image, .video: true
        default: false
        }
    }

    /// Drops the previews held in memory (the window is closed; the disk copies stay).
    func clearMemory() {
        memory.removeAllObjects()
    }

    /// Drops previews held in memory and removes all cached preview files from disk.
    func clear() {
        clearMemory()
        none.removeAll()
        guard let folder, let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// The cached preview, if there is one already (no waiting).
    func cached(deviceID: String, path: String, entry: FolderEntry) -> NSImage? {
        memory.object(forKey: key(deviceID, path, entry) as NSString)
    }

    func image(deviceID: String, storageID: UInt32, path: String, entry: FolderEntry) async -> NSImage? {
        let key = key(deviceID, path, entry)
        if let image = memory.object(forKey: key as NSString) { return image }
        if none.contains(key) { return nil }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await self.load(key: key, deviceID: deviceID, storageID: storageID, path: path) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    private func load(key: String, deviceID: String, storageID: UInt32, path: String) async -> NSImage? {
        let file = folder?.appendingPathComponent(key + ".jpg")
        let marker = folder?.appendingPathComponent(key + ".none")
        if let file, let image = NSImage(contentsOf: file) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        if let marker, FileManager.default.fileExists(atPath: marker.path) {
            none.insert(key)
            return nil
        }

        await acquire()
        defer { release() }
        // Scrolled away while waiting: leave the phone to the rows still on screen.
        guard !Task.isCancelled else { return nil }
        guard let data = await fetch(deviceID, storageID, path), let image = NSImage(data: data) else {
            none.insert(key)
            if let marker { FileManager.default.createFile(atPath: marker.path, contents: nil) }
            return nil
        }
        memory.setObject(image, forKey: key as NSString)
        if let file { try? data.write(to: file, options: .atomic) }
        return image
    }

    private func acquire() async {
        if running < Self.limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            // Newest first: the rows the user just scrolled to.
            waiting.removeLast().resume()
        }
    }

    private func key(_ deviceID: String, _ path: String, _ entry: FolderEntry) -> String {
        let digest = SHA256.hash(data: Data("\(deviceID)\n\(path)\n\(entry.sizeBytes)\n\(entry.modifiedWallClock)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// A file's picture in lists: the phone's preview for photos and videos (with a play badge on
/// videos), Finder's icon for everything else, and while a preview loads.
struct FileIcon: View {
    var name: String
    var isFolder: Bool
    var size: CGFloat = 30
    /// Where to fetch a preview from; nil shows the icon only.
    var preview: (deviceID: String, storageID: UInt32, path: String, entry: FolderEntry)?
    /// Show the whole picture at its own proportions (icon view), not a square crop (lists).
    var fit = false

    @Environment(AppModel.self) private var model
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                let radius = fit ? min(8, size * 0.08) : size * 0.2
                Image(nsImage: image)
                    .resizable()
                    .modifier(PictureFit(fit: fit, size: size))
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(fit ? 0.6 : 0.35), lineWidth: fit ? 1.5 : 0.8))
                    .shadow(color: .black.opacity(fit ? 0.3 : 0), radius: 4, y: 2)
                    .overlay(alignment: .bottomTrailing) {
                        if KindThumb.kind(forName: name, isFolder: false) == .video {
                            Image(systemName: "play.fill")
                                .font(.system(size: size * 0.24, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(size * 0.07)
                                .background(Circle().fill(.black.opacity(0.5)))
                                .padding(size * 0.06)
                        }
                    }
                    .transition(.opacity)
            } else {
                Image(nsImage: SystemIcons.icon(forName: name, isFolder: isFolder))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size * 1.1, height: size * 1.1)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.25), value: image != nil)
        .task(id: preview?.path) {
            guard let preview, !isFolder, Thumbnails.hasPreview(name) else { return }
            if let cached = model.thumbnails.cached(deviceID: preview.deviceID, path: preview.path, entry: preview.entry) {
                image = cached
                return
            }
            let loaded = await model.thumbnails.image(deviceID: preview.deviceID, storageID: preview.storageID, path: preview.path, entry: preview.entry)
            if !Task.isCancelled { image = loaded }
        }
        .accessibilityHidden(true)
    }
}

private struct PictureFit: ViewModifier {
    var fit: Bool
    var size: CGFloat

    func body(content: Content) -> some View {
        if fit {
            content.scaledToFit().frame(maxWidth: size, maxHeight: size)
        } else {
            content.scaledToFill().frame(width: size, height: size)
        }
    }
}
