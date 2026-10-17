import AppKit
import PulliProtocol
import SwiftUI
import UniformTypeIdentifiers

/// The activity log: what the engine did, newest first, for troubleshooting.
struct ActivityView: View {
    enum Filter: String, CaseIterable { case all = "All", warnings = "Warnings", errors = "Errors" }

    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var entries: [LogEntry] = []
    @State private var filter = Filter.all
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                SearchField(text: $search, prompt: "Search the log")
                Button { export() } label: { Label("Export Diagnostics…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(PillButtonStyle())
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 0) {
                            Text(entry.date.formatted(date: .omitted, time: .standard)).frame(width: 90, alignment: .leading).foregroundStyle(tone.t2)
                            HStack(spacing: 6) {
                                Circle().fill(color(entry.level)).frame(width: 7, height: 7).shadow(color: color(entry.level), radius: 3)
                                Text(label(entry.level)).font(.pulli(12, .semibold))
                            }
                            .frame(width: 90, alignment: .leading)
                            Text(entry.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.pulli(13)).monospacedDigit()
                        .padding(.horizontal, 18).frame(minHeight: 38)
                        .overlay(alignment: .top) { if index > 0 { Rectangle().fill(tone.separator).frame(height: 1) } }
                    }
                    if visible.isEmpty {
                        Text("No events yet.").font(.pulli(13)).foregroundStyle(tone.t2).padding(20)
                    }
                }
            }
            .panel(radius: 18)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 420)
        .background(SceneBackground(kind: .slate))
        .modifier(ToneProvider())
        .task {
            while !Task.isCancelled {
                entries = await model.log().sorted { $0.id > $1.id }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var visible: [LogEntry] {
        entries.filter { entry in
            switch filter {
            case .all: true
            case .warnings: entry.level >= 3
            case .errors: entry.level >= 4
            }
        }
        .filter { search.isEmpty || $0.message.localizedCaseInsensitiveContains(search) }
    }

    private func color(_ level: Int) -> Color {
        switch level {
        case 4...: Color(hex: 0xFF7A66)
        case 3: .pausedAmber
        case 2: .accent
        default: Color(hex: 0x9FB0B8)
        }
    }

    private func label(_ level: Int) -> String {
        switch level {
        case 4...: "Error"
        case 3: "Warning"
        case 2: "Notice"
        default: "Info"
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pulli diagnostics \(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let commitStr = AppModel.commit.map { " (\($0))" } ?? ""
        var lines = ["Pulli \(AppModel.version)\(commitStr) · \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for device in model.state.devices.values {
            lines.append("Phone: \(device.name) \(device.model ?? "") · \(Format.link(device.link)) · \(device.state)")
        }
        lines.append("")
        lines += entries.reversed().map { "\($0.date.formatted(.iso8601)) [\(label($0.level))] \($0.kind): \($0.message)" }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
