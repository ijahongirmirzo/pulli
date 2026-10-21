import AppKit
import PulliProtocol
import SwiftUI

/// The menu bar extra, laid out like a macOS menu: the phone and its status, running copies, the
/// common actions as menu rows (highlighted on hover), and Open Pulli. System font, menu glass.
struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.tone) private var tone
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        let batches = model.state.batchesForMenu.filter { AppModel.isActive($0) || ($0.finishedAt.map { Date().timeIntervalSince($0) < 3600 } ?? false) }
        let device = model.device
        let ready = device?.state == .ready
        let newCount = device.flatMap { model.summaries[$0.id]?.newItems.count } ?? 0
        VStack(alignment: .leading, spacing: 0) {
            header(device: device, batches: batches)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            separator
            if batches.isEmpty {
                Text(device == nil ? "Plug in an Android phone with a data cable and unlock it. Pulli finds it by itself." : "No copies right now.")
                    .font(.system(size: 12.5)).foregroundStyle(tone.t2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 320 - 28, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            } else {
                VStack(spacing: 2) {
                    ForEach(batches.prefix(4)) { batch in CopyRow(batch: batch) }
                }
                .padding(.vertical, 6)
            }
            if model.attentionCount > 0 {
                MenuRow(symbol: "exclamationmark.triangle.fill", title: "\(Format.count(model.attentionCount, "file")) need\(model.attentionCount == 1 ? "s" : "") attention", tint: tone.amber) {
                    open(.attention)
                }
                .padding(.bottom, 4)
            }
            separator
            VStack(spacing: 0) {
                if ready, newCount > 0 {
                    MenuRow(symbol: "sparkles", title: "Copy \(Format.count(newCount, "New Item"))") {
                        Task { _ = try? await model.copyNewForShortcut() }
                    }
                }
                MenuRow(symbol: "folder", title: "Browse Phone…", enabled: ready) {
                    model.openBrowser(at: "/")
                    open(nil)
                }
                MenuRow(symbol: "externaldrive", title: "Open in Finder", enabled: ready) { model.openInFinder() }
                MenuRow(symbol: "square.grid.3x3.square", title: "Storage Map", enabled: ready) {
                    model.openStorageMap()
                    open(nil)
                }
                MenuRow(symbol: "clock", title: "History") { open(.history) }
            }
            .padding(.vertical, 5)
            if let version = Updates.shared.available {
                separator
                UpdateMenuRow(version: version) { Updates.shared.install() }
                    .padding(.vertical, 4)
            }
            separator
            HStack(spacing: 4) {
                MenuRow(symbol: nil, title: "Open Pulli", bold: true) { open(nil) }
                Button {
                    NSApp.activate()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape").font(.system(size: 13, weight: .medium)).foregroundStyle(tone.t2)
                        .frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
                .accessibilityLabel("Settings")
                .padding(.trailing, 8)
            }
            .padding(.vertical, 5)
        }
        .frame(width: 320)
        .background {
            if isSnapshot {
                // Snapshots cannot draw the system's glass.
                SceneBackground(kind: .home, animated: false)
            } else {
                GlassBackground(material: .menu, clarity: 0.3).ignoresSafeArea()
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(tone.separator).frame(height: 1).padding(.horizontal, 14)
    }

    @ViewBuilder
    private func header(device: DeviceSnapshot?, batches: [BatchSnapshot]) -> some View {
        let running = batches.filter { $0.phase == .copying || $0.phase == .scanning }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device?.name ?? "Pulli").font(.system(size: 15, weight: .bold))
                HStack(spacing: 5) {
                    Image(systemName: statusSymbol(device, running: !running.isEmpty))
                        .font(.system(size: 11, weight: .semibold))
                    Text(statusText(device, running: running))
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone.t2)
            }
            Spacer()
            Menu {
                Button("Open Pulli") { open(nil) }
                Divider()
                if AppDelegate.updaterController != nil {
                    Button("Check for Updates…") { AppDelegate.updaterController?.checkForUpdates(nil) }
                }
                Button("Settings…") { StatusMenu.openSettings() }
                Button("Activity Log") { StatusMenu.openActivityLog() }
                if Feedback.isAvailable {
                    Button("Send Feedback…") { Feedback.open(model: model) }
                }
                Divider()
                Button("Quit Pulli") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 16, weight: .regular)).foregroundStyle(tone.t2)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private func statusSymbol(_ device: DeviceSnapshot?, running: Bool) -> String {
        guard let device else { return "iphone.slash" }
        if running { return "arrow.down.circle" }
        switch device.state {
        case .ready: return "cable.connector"
        case .locked: return "lock.fill"
        default: return "exclamationmark.circle"
        }
    }

    private func statusText(_ device: DeviceSnapshot?, running: [BatchSnapshot]) -> String {
        guard let device else { return "No phone connected" }
        if let batch = running.first {
            let left = batch.secondsRemaining.map { " · \(Format.duration($0)) left" } ?? ""
            return "Copying \(batch.filesDone) of \(batch.filesTotal)\(left)"
        }
        switch device.state {
        case .ready:
            let speed = device.cable.map { " · " + Format.speed($0.bytesPerSecond) } ?? ""
            return "Connected · \(Format.link(device.link))\(speed)"
        case .locked: return "Connected · unlock the phone"
        case .notInFileTransferMode: return "Connected · choose File transfer"
        default: return "Connecting…"
        }
    }

    private func open(_ section: AppModel.Section?) {
        if let section { model.show(section) }
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// The menu for a right-click (or Control-click) on Pulli's menu bar icon, the same as the ⋯
/// menu in its window. SwiftUI's menu bar item has no right-click, so clicks on the status bar
/// button are watched for in the app's own events.
@MainActor
enum StatusMenu {
    /// Opens the activity log window (set by the main window, which can open SwiftUI windows).
    static var openActivityWindow: (() -> Void)?
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            guard let window = event.window, String(describing: type(of: window)).contains("StatusBar"),
                  event.type == .rightMouseDown || event.modifierFlags.contains(.control),
                  let button = window.contentView else { return event }
            MainActor.assumeIsolated { show(from: button) }
            return nil
        }
    }

    private static func show(from button: NSView) {
        let menu = NSMenu()
        if let version = Updates.shared.available {
            menu.addItem(ClosureMenuItem("Install Update (\(version))…") { Updates.shared.install() })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Open Pulli") { AppDelegate.openMainWindow?() })
        menu.addItem(.separator())
        if let updater = AppDelegate.updaterController {
            menu.addItem(ClosureMenuItem("Check for Updates…") { updater.checkForUpdates(nil) })
        }
        menu.addItem(ClosureMenuItem("Settings…") { openSettings() })
        menu.addItem(ClosureMenuItem("Activity Log") { openActivityLog() })
        if Feedback.isAvailable {
            menu.addItem(ClosureMenuItem("Send Feedback…") { Feedback.open(model: AppDelegate.model) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Quit Pulli") { NSApp.terminate(nil) })
        // In the app's appearance, like Pulli's own menu window: opened from the status bar it
        // would otherwise take the menu bar's (dark over a dark wallpaper).
        menu.appearance = NSApp.effectiveAppearance
        // Below the icon, as a menu bar menu opens.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.height + 4 : -4), in: button)
    }

    static func openSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    static func openActivityLog() {
        NSApp.activate()
        openActivityWindow?()
    }
}

/// A row like a macOS menu item: icon, title, highlighted in the accent colour on hover.
private struct MenuRow: View {
    var symbol: String?
    var title: String
    var enabled = true
    var bold = false
    var tint: Color?
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.tone) private var tone

    init(symbol: String?, title: String, enabled: Bool = true, bold: Bool = false, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.enabled = enabled
        self.bold = bold
        self.tint = tint
        self.action = action
    }

    var body: some View {
        let lit = hovering && enabled
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(lit ? .white : (tint ?? tone.t2))
                        .frame(width: 18)
                }
                Text(title).font(.system(size: 13.5, weight: bold ? .semibold : .regular))
                    .foregroundStyle(lit ? .white : tone.t1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.accent : .clear))
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
    }
}

/// An update notice in BetterDisplay's style: filled orange circle with white arrow, two lines of text.
private struct UpdateMenuRow: View {
    var version: String
    var action: () -> Void
    @State private var hovering = false
    @Environment(\.tone) private var tone

    var body: some View {
        let lit = hovering
        let orange = Color(hex: tone.dark ? 0xF5A65B : 0xF0913A)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.down.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, orange)
                    .font(.system(size: 19))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Install Update…")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(lit ? .white : tone.t1)
                    Text("Pulli \(version) is available")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(lit ? .white.opacity(0.8) : tone.t2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(lit ? Color.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
    }
}

/// One copy, compact: what and where, a thin progress bar, and pause or resume.
private struct CopyRow: View {
    var batch: BatchSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(batch.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("→ \(Format.place(batch.destinationPath))").font(.system(size: 12)).foregroundStyle(tone.t2).lineLimit(1)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(tone.track)
                        Capsule().fill(color).frame(width: max(4, proxy.size.width * batch.fractionDone))
                    }
                }
                .frame(height: 4)
                .animation(.easeInOut(duration: 0.4), value: batch.fractionDone)
                HStack {
                    Text(leftText)
                    Spacer()
                    Text(rightText).foregroundStyle(isPaused ? tone.amber : tone.t2)
                }
                .font(.system(size: 11.5)).foregroundStyle(tone.t2).monospacedDigit()
            }
            if let command {
                Button {
                    Task { await model.control(batch.id, command) }
                } label: {
                    Image(systemName: command == .pause ? "pause.circle" : "play.circle")
                        .font(.system(size: 18, weight: .regular)).foregroundStyle(tone.t2)
                }
                .buttonStyle(.plain)
                .help(command == .pause ? "Pause" : "Resume")
                .accessibilityLabel(command == .pause ? "Pause" : "Resume")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(Int((batch.fractionDone * 100).rounded())) percent")
    }

    private var isPaused: Bool {
        if case .paused(let reason) = batch.phase { return reason != .queued }
        return false
    }

    private var command: BatchCommand? {
        switch batch.phase {
        case .copying, .scanning: .pause
        case .paused(.byUser): .resume
        default: nil
        }
    }

    private var color: Color {
        switch batch.phase {
        case .copying, .scanning: .accent
        case .paused(.queued): tone.t3
        case .paused: .pausedAmber
        case .completed: Color(hex: 0x46C96A)
        default: tone.t3
        }
    }

    private var leftText: String {
        switch batch.phase {
        case .copying: "\(batch.filesDone) of \(batch.filesTotal)\(batch.bytesPerSecond > 0 ? " · " + Format.speed(batch.bytesPerSecond) : "")"
        case .scanning: "Finding files… \(batch.filesTotal)"
        default: "\(Format.bytes(batch.bytesDone)) of \(Format.bytes(batch.bytesTotal))"
        }
    }

    private var rightText: String {
        switch batch.phase {
        case .copying: batch.secondsRemaining.map { "\(Format.duration($0)) left" } ?? ""
        case .paused(.phoneDisconnected): "Reconnect the phone"
        case .paused(.phoneLocked): "Unlock the phone"
        case .paused(.queued): "Next"
        case .paused(.byUser): "Paused"
        case .paused: "Waiting"
        case .completed: "Done"
        case .cancelled: "Stopped"
        default: ""
        }
    }
}

/// The menu bar icon: Pulli's mark (a pulley "p" with a down arrow), plus the overall percentage
/// while copying, a pause in the wheel while paused, and a small badge dot when an update is waiting.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let batch = model.activeBatch, batch.phase == .copying {
            HStack(spacing: 3) {
                Image(nsImage: PulliGlyph.image(.copying))
                Text("\(Int((batch.fractionDone * 100).rounded()))%").monospacedDigit()
            }
        } else {
            let glyph = model.activeBatch != nil ? PulliGlyph.image(.paused) : PulliGlyph.image(.idle)
            if Updates.shared.available != nil {
                HStack(spacing: 3) {
                    Image(nsImage: glyph)
                    Image(systemName: "circlebadge.fill").imageScale(.small)
                }
            } else {
                Image(nsImage: glyph)
            }
        }
    }
}
