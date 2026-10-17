import AppKit
import PulliProtocol
import UniformTypeIdentifiers

/// Delivers phone items dragged out of Pulli (to the Desktop, a Finder window, Mail…). Finder asks
/// for each promised file with the folder it was dropped in; everything from one drag becomes one
/// ordinary copy into that folder (journaled and resumable, shown in Copies), and each promise
/// is kept when that copy finishes.
final class DragOut: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    struct Item: Sendable {
        var path: String
        var entry: FolderEntry
    }

    let items: [Item]
    private weak var model: AppModel?
    private let lock = NSLock()
    private var requested: [(index: Int, url: URL, done: @Sendable ((any Error)?) -> Void)] = []
    private var scheduled = false

    @MainActor
    init(model: AppModel, items: [Item]) {
        self.model = model
        self.items = items
    }

    /// A drag item per phone item, each promising its file (or folder).
    @MainActor
    func draggingItems(frames: [NSRect], images: [NSImage]) -> [NSDraggingItem] {
        items.enumerated().map { index, item in
            let type: UTType = item.entry.isFolder ? .folder : (UTType(filenameExtension: (item.entry.name as NSString).pathExtension) ?? .data)
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = index
            let dragging = NSDraggingItem(pasteboardWriter: provider)
            dragging.setDraggingFrame(frames[min(index, frames.count - 1)], contents: images[min(index, images.count - 1)])
            return dragging
        }
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let index = provider.userInfo as? Int, items.indices.contains(index) else { return "Item" }
        return items[index].entry.name
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let index = provider.userInfo as? Int else { completionHandler(nil); return }
        nonisolated(unsafe) let done = completionHandler
        let first = lock.withLock { () -> Bool in
            requested.append((index, url, { done($0) }))
            defer { scheduled = true }
            return !scheduled
        }
        // Finder asks for each promise separately; gather them for a moment, then copy once.
        guard first else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            await self.deliver()
        }
    }

    @MainActor
    private func deliver() async {
        let batch = lock.withLock { requested }
        guard let model, let folder = batch.first?.url.deletingLastPathComponent() else {
            batch.forEach { $0.done(CocoaError(.fileWriteUnknown)) }
            return
        }
        let paths = batch.map { items[$0.index].path }
        guard let id = await model.copy(paths: paths, destination: folder.path, navigate: false) else {
            batch.forEach { $0.done(CocoaError(.fileWriteUnknown)) }
            return
        }
        model.banner = nil
        model.dragOutNotice = "Copying \(paths.count == 1 ? items[batch[0].index].entry.name : "\(paths.count) items") to \(folder.lastPathComponent)…"
        // Keep each promise when the copy is done (or report why not).
        while true {
            try? await Task.sleep(for: .milliseconds(400))
            guard let snapshot = model.state.batches[id] else { continue }
            if snapshot.phase == .completed {
                batch.forEach { $0.done(nil) }
                break
            }
            if snapshot.phase == .cancelled {
                batch.forEach { $0.done(CocoaError(.userCancelled)) }
                break
            }
        }
        model.dragOutNotice = nil
        model.dragOuts.remove(self)
    }
}
