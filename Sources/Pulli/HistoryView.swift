import PulliProtocol
import SwiftUI

struct HistoryView: View {
    var search: String
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var confirmingClear = false

    var body: some View {
        let batches = model.state.batches.values
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.deviceName.localizedCaseInsensitiveContains(search) || $0.destinationPath.localizedCaseInsensitiveContains(search) }
            .sorted { $0.createdAt > $1.createdAt }
        let total = batches.reduce(UInt64(0)) { $0 + $1.bytesDone }
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("History").font(.pulli(30, .medium))
                Spacer()
                Text("\(Format.count(batches.count, "copy", "copies")) · \(Format.bytes(total))").font(.pulli(14)).foregroundStyle(tone.t2).monospacedDigit()
                // Always offered: the log and saved previews can hold names even with no copies listed.
                Button("Clear History…") { confirmingClear = true }
                    .buttonStyle(PillButtonStyle(small: true))
            }
            if batches.isEmpty {
                VStack(spacing: 14) {
                    Gem(form: .squircle, palette: .violet, symbol: "clock", size: 120)
                    Text(search.isEmpty ? "Copies you make show up here." : "No copies match \u{201C}\(search)\u{201D}.").font(.pulli(15)).foregroundStyle(tone.t2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Scrolling {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(batches.enumerated()), id: \.element.id) { index, batch in
                            HistoryRow(batch: batch, first: index == 0)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .panel(radius: 22)
            }
        }
        .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 36)
        .confirmationDialog("Clear history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                Task { await model.clearHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearMessage)
        }
    }

    private var clearMessage: String {
        let base = "Pulli forgets your past copies, its activity log, and the previews and thumbnails it saved. Your copied files stay on your Mac."
        let hasActive = model.state.batches.values.contains(where: AppModel.isActive)
        return hasActive ? base + " Copies in progress or paused stay." : base
    }
}

private struct HistoryRow: View {
    var batch: BatchSnapshot
    var first: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var hovering = false

    var body: some View {
        Button {
            model.focusedBatchID = batch.id
            model.show(.copies)
        } label: {
            HStack(spacing: 14) {
                Gem(form: .squircle, palette: palette, symbol: "iphone.gen3", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(batch.title).font(.pulli(14.5, .semibold))
                        Text("from \(batch.deviceName)").font(.pulli(14.5)).foregroundStyle(tone.t2)
                    }
                    .lineLimit(1)
                    Text("to \(Format.place(batch.destinationPath))").font(.pulli(12.5)).foregroundStyle(tone.t3).lineLimit(1)
                }
                Spacer()
                Text(Format.relativeDay(batch.createdAt)).frame(width: 150, alignment: .leading).foregroundStyle(tone.t2)
                Text(Format.count(batch.filesTotal, "file")).frame(width: 90, alignment: .trailing).foregroundStyle(tone.t2)
                Text(Format.bytes(batch.bytesTotal)).frame(width: 80, alignment: .trailing).foregroundStyle(tone.t2)
                status.frame(width: 150, alignment: .trailing)
            }
            .font(.pulli(13)).monospacedDigit()
            .padding(.horizontal, 22).frame(height: 62)
            .background(hovering ? tone.pill.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .top) { if !first { Rectangle().fill(tone.separator).frame(height: 1) } }
        .contextMenu {
            Button("Show in Finder") { model.showInFinder(batch.destinationPath) }
            if batch.phase == .completed, model.state.devices[batch.deviceID] != nil {
                Button("Free Up Space on Phone…") { model.startFreeUp(batch) }
            }
            if batch.phase == .completed || batch.phase == .cancelled {
                Button("Remove from History") { Task { await model.control(batch.id, .remove) } }
            }
        }
    }

    private var palette: ArtPalette {
        switch batch.phase {
        case .completed: .teal
        case .cancelled: .slate
        case .paused: .amber
        default: .blue
        }
    }

    @ViewBuilder
    private var status: some View {
        switch batch.phase {
        case .completed where batch.filesNeedingAttention > 0:
            Chip(text: "\(batch.filesNeedingAttention) need attention", color: tone.amber, fill: tone.amberFill, small: true)
        case .completed: Chip(text: "Done", color: tone.green, fill: tone.greenFill, small: true)
        case .cancelled: Chip(text: "Stopped", color: tone.t2, small: true)
        case .paused: Chip(text: "Paused", color: tone.amber, fill: tone.amberFill, small: true)
        default: Chip(text: "\(Int((batch.fractionDone * 100).rounded()))%", color: tone.t1, small: true)
        }
    }
}

/// Every file that needs a look, per copy, with the reason and a Try Again.
struct AttentionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var items: [Int64: [AttentionItem]] = [:]

    var body: some View {
        let batches = model.state.batches.values.filter { $0.filesNeedingAttention > 0 }.sorted { $0.createdAt > $1.createdAt }
        VStack(alignment: .leading, spacing: 18) {
            Text("Needs attention").font(.pulli(30, .medium))
            if batches.isEmpty {
                VStack(spacing: 14) {
                    Gem(form: .disc, palette: .green, symbol: "checkmark", size: 120, face: true)
                    Text("Nothing needs your attention.").font(.pulli(15)).foregroundStyle(tone.t2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Scrolling {
                    VStack(spacing: 16) {
                        ForEach(batches) { batch in
                            VStack(alignment: .leading, spacing: 0) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(batch.title) from \(batch.deviceName)").font(.pulli(15, .semibold))
                                        Text(Format.relativeDay(batch.createdAt)).font(.pulli(12.5)).foregroundStyle(tone.t3)
                                    }
                                    Spacer()
                                    Button("Try Again") { Task { await model.control(batch.id, .retryNeedsAttention) } }
                                        .buttonStyle(PillButtonStyle(kind: .strong, small: true))
                                }
                                .padding(16)
                                ForEach(items[batch.id] ?? [], id: \.jobID) { item in
                                    HStack(spacing: 12) {
                                        FileIcon(name: item.path, isFolder: false, size: 28)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text((item.path as NSString).lastPathComponent).font(.pulli(13.5, .semibold)).lineLimit(1)
                                            Text(item.reason).font(.pulli(12.5)).foregroundStyle(tone.t2).lineLimit(2)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 16).padding(.vertical, 9)
                                    .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1) }
                                }
                            }
                            .panel(radius: 18)
                            .task(id: batch.filesNeedingAttention) { items[batch.id] = await model.attention(batch.id) }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.horizontal, 40).padding(.top, 20).padding(.bottom, 36)
    }
}
