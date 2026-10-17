import AppKit
import PulliProtocol
import UniformTypeIdentifiers

// Copy and paste between the phone and the Mac, and drops from any app.
//
// - ⌘C on phone items puts them on the clipboard as files in the phone's Finder location (or its
//   WebDAV drive), so ⌘V in Finder copies them with Finder's own progress, and any app that takes
//   files (Mail, Telegram, a browser's upload) can paste them too.
// - ⌘V in a phone folder copies what is on the clipboard there: files, or a picture copied in a
//   browser or with a screenshot, or a picture's web address (downloaded first).
// - Drops take the same things from any app: files, files an app writes only when dropped
//   (Telegram, WhatsApp, Photos, Safari), pictures, and web links to files.
extension AppModel {
    // MARK: Phone to clipboard

    /// Puts phone items on the clipboard as files Finder and other apps can paste.
    func copyToClipboard(_ paths: [String]) {
        guard !paths.isEmpty, let device else { return }
        let names = paths.map { ($0 as NSString).lastPathComponent }
        dragOutNotice = "Getting \(names.count == 1 ? names[0] : "\(names.count) items") ready to paste…"
        Task {
            defer { dragOutNotice = nil }
            guard let drive = await phoneFilesRoot() else { return }
            let urls = paths.map { drive.appendingPathComponent(String($0.drop { $0 == "/" })) }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
            // Plain text too, for pasting into a text field.
            pasteboard.addTypes([.string], owner: nil)
            pasteboard.setString(names.joined(separator: "\n"), forType: .string)
            showToast("Copied \(names.count == 1 ? "\u{201C}\(names[0])\u{201D}" : "\(names.count) items") from \(device.name). Paste with ⌘V in Finder or any app.")
        }
    }

    /// Whether ⌘V has something to copy to the phone.
    var clipboardHasSomethingForPhone: Bool {
#if !PULLI_APP_STORE
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        let types = pasteboard.types ?? []
        return types.contains { type in
            guard let uti = UTType(type.rawValue) else { return false }
            return uti.conforms(to: .image) || uti.conforms(to: .movie) || uti == .url
        }
#else
        return false
#endif
    }

#if !PULLI_APP_STORE
    // MARK: Clipboard and drops to phone

    /// ⌘V: copies what is on the clipboard into `folder` on the phone.
    func pasteFromClipboard(into folder: String) {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            send(urls, to: folder)
            return
        }
        // A picture (copied in a browser, or a screenshot to the clipboard).
        let pictures: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
                                                                 (NSPasteboard.PasteboardType("public.heic"), "heic"), (.tiff, "png")]
        for (type, ext) in pictures {
            guard var data = pasteboard.data(forType: type) else { continue }
            if type == .tiff, let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) { data = png }
            let file = Self.unique(Self.incomingFolder().appendingPathComponent("Pasted Image \(Self.stamp()).\(ext)"))
            do {
                try data.write(to: file)
                send([file], to: folder)
            } catch {
                banner = "Could not paste the picture: \(error.localizedDescription)"
            }
            return
        }
        // A web address of a file.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let web = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            Task { await downloadAndSend(web, to: folder) }
            return
        }
        banner = "The clipboard has no files or pictures to copy to the phone."
    }

    /// A drop from any app onto a phone folder.
    func receive(_ providers: [NSItemProvider], into folder: String) {
        guard !providers.isEmpty else { return }
        dragOutNotice = "Receiving \(providers.count == 1 ? "1 item" : "\(providers.count) items")…"
        let incoming = Self.incomingFolder()
        Task {
            defer { dragOutNotice = nil }
            var files: [URL] = []
            for provider in providers {
                if let file = await Self.file(from: provider, into: incoming) { files.append(file) }
            }
            if files.isEmpty {
                banner = "Pulli could not take what was dropped. Try saving it to the Mac first, then drop the file."
            } else {
                send(files, to: folder)
            }
        }
    }

    private func send(_ files: [URL], to folder: String) {
        upload(files, to: folder)
        let where_ = folder == "/" ? device?.name ?? "the phone" : (folder as NSString).lastPathComponent
        showToast("Copying \(files.count == 1 ? "\u{201C}\(files[0].lastPathComponent)\u{201D}" : "\(files.count) items") to \(where_).")
    }

    private func downloadAndSend(_ web: URL, to folder: String) async {
        dragOutNotice = "Downloading \(web.lastPathComponent)…"
        defer { dragOutNotice = nil }
        if let file = await Self.download(web, into: Self.incomingFolder()) {
            send([file], to: folder)
        } else {
            banner = "Could not download \(web.absoluteString)."
        }
    }
#endif

    func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            if toast == text { toast = nil }
        }
    }

    // MARK: Files from item providers

    /// A file for what a provider holds: a file itself, a file the app writes on request, the
    /// data of a picture or document, or a web link (downloaded).
    static func file(from provider: NSItemProvider, into folder: URL) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(provider, type: .fileURL), url.isFileURL {
            return url
        }
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let content = types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) && $0 != .data }
            ?? types.first { $0.conforms(to: .content) && !$0.conforms(to: .url) && !$0.conforms(to: .plainText) }
        if let content {
            let name = provider.suggestedName ?? "Dropped \(stamp())"
            if let file = await loadFile(provider, type: content, name: name, into: folder) { return file }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier), let url = await loadURL(provider, type: .url) {
            if url.isFileURL { return url }
            if url.scheme == "http" || url.scheme == "https" { return await download(url, into: folder) }
        }
        return nil
    }

    private static func loadURL(_ provider: NSItemProvider, type: UTType) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? (item as? String).flatMap { URL(string: $0) }
                continuation.resume(returning: url)
            }
        }
    }

    /// The provider writes the file (a promised file from Telegram, Photos, Safari…); it is
    /// removed when the handler returns, so it is moved to `folder` straight away.
    private static func loadFile(_ provider: NSItemProvider, type: UTType, name: String, into folder: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: nil); return }
                var fileName = url.lastPathComponent
                // Some apps hand over a temporary name: prefer the suggested one, with the right extension.
                if fileName.hasPrefix(".") || fileName.contains("-") && fileName.count > 40 {
                    fileName = name
                    if let ext = type.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty { fileName += ".\(ext)" }
                }
                let target = unique(folder.appendingPathComponent(fileName))
                do {
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func download(_ web: URL, into folder: URL) async -> URL? {
        guard let (temporary, response) = try? await URLSession.shared.download(from: web) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let name = response.suggestedFilename ?? web.lastPathComponent
        let target = unique(folder.appendingPathComponent(name.isEmpty ? "Download \(stamp())" : name))
        do {
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        } catch {
            return nil
        }
    }

    // MARK: Incoming files

    private static let incomingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(PulliApp.bundleID)/Incoming", isDirectory: true)

    /// A fresh folder for files received from the clipboard or drops, until they are on the phone.
    static func incomingFolder() -> URL {
        let folder = incomingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes received files older than a day (their copies to the phone have long finished).
    static func cleanIncoming() {
        let old = Date().addingTimeInterval(-86_400)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: incomingRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for folder in folders where ((try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) < old {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Removes cached incoming files, skipping recently created items if a drag or paste is active.
    static func clearIncoming(skippingActive: Bool = false) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: incomingRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let now = Date()
        for item in items {
            if skippingActive {
                let created = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if now.timeIntervalSince(created) < 60 { continue }
            }
            try? FileManager.default.removeItem(at: item)
        }
    }

    private static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for index in 2... {
            let candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
    }
}
