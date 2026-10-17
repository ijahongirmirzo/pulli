import Darwin
import Foundation
import PulliProtocol
import WidgetKit

/// Keeps the desktop widget current: writes a `WidgetSnapshot` into the widget's container when
/// copies change (at most every 2 s), then asks WidgetKit to reload.
///
/// The container exists once macOS has run the widget (added to the desktop or gallery). Pulli
/// never creates it: a container made by anyone but macOS is not trusted by the sandbox.
@MainActor
final class WidgetFeed {
    private var last: WidgetSnapshot?
    private var lastWrite = Date.distantPast
    private var pending: Task<Void, Never>?

    func update(from model: AppModel) {
        let snapshot = Self.snapshot(model)
        guard snapshot.copies != last?.copies
            || snapshot.phone != last?.phone
            || snapshot.hint != last?.hint
            || snapshot.photos != last?.photos
            || snapshot.newPhotos != last?.newPhotos
            || snapshot.lastCopy != last?.lastCopy
        else { return }
        last = snapshot
        pending?.cancel()
        let wait = max(0, 2 - Date().timeIntervalSince(lastWrite))
        pending = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.write(snapshot)
        }
    }

    private func write(_ snapshot: WidgetSnapshot) {
        let file = WidgetSnapshot.containerFile
        let container = file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: container.path) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
        lastWrite = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// After Pulli is replaced (an update, or a new copy dragged in), macOS can keep the old
    /// widget process alive. Its own files are gone, so it draws only grey placeholders until it
    /// is restarted. Stops a widget process older than the widget on disk; macOS starts the new
    /// one when the desktop next asks.
    static func restartIfStale() {
        guard let executable = Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("PulliWidget.appex/Contents/MacOS/PulliWidget"),
              let installed = (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var stopped = false
        for pid in pids.prefix(Int(max(0, found))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == getuid() else { continue }
            let name = withUnsafeBytes(of: info.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == "PulliWidget" else { continue }
            let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
            if started < installed {
                kill(pid, SIGTERM)
                stopped = true
            }
        }
        if stopped { WidgetCenter.shared.reloadAllTimelines() }
    }

    static func snapshot(_ model: AppModel) -> WidgetSnapshot {
        let copies = model.state.batchesForMenu.filter { AppModel.isActive($0) }.prefix(3).map { batch -> WidgetSnapshot.Copy in
            let (detail, tint): (String, WidgetSnapshot.Copy.Tint) = switch batch.phase {
            case .copying: (batch.secondsRemaining.map { "\(Format.duration($0)) left" } ?? "copying", .copying)
            case .scanning: ("finding files", .copying)
            case .paused(.queued): ("next", .waiting)
            case .paused: ("paused", .paused)
            default: ("", .done)
            }
            return WidgetSnapshot.Copy(
                id: batch.id,
                device: batch.deviceName,
                title: batch.title,
                fraction: batch.fractionDone,
                detail: detail,
                tint: tint,
                bytesDone: batch.bytesDone,
                bytesTotal: batch.bytesTotal
            )
        }
        var hint: String?
        if let cable = model.device?.cable, cable.suggestion != .none, let faster = cable.fasterBytesPerSecond {
            hint = String(format: "%@ · %.0f× faster with USB 3", Format.link(cable.link), faster / max(cable.bytesPerSecond, 1))
        }
        var photos: Int?
        var newPhotos: Int?
        if let device = model.device, let summary = model.summaries[device.id] {
            if let camera = summary.camera {
                photos = camera.files.count
                if summary.cameraMark != nil {
                    newPhotos = summary.newItems.count
                }
            }
        }
        let lastFinished = model.state.batches.values
            .filter { $0.phase == .completed }
            .max { ($0.finishedAt ?? $0.createdAt) < ($1.finishedAt ?? $1.createdAt) }
        let lastCopy = lastFinished.map { batch in
            WidgetSnapshot.LastCopy(
                title: batch.title,
                date: batch.finishedAt ?? batch.createdAt,
                files: batch.filesDone
            )
        }
        return WidgetSnapshot(
            updated: Date(),
            phone: model.device?.name,
            hint: hint,
            copies: Array(copies),
            photos: photos,
            newPhotos: newPhotos,
            lastCopy: lastCopy
        )
    }
}
