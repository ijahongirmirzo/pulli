import AppKit
import DeviceAPI
import PulliProtocol
import SwiftUI

// MARK: - Welcome (no phone)

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var float = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            PhoneArt(width: 250, palette: .teal, screen: .photos, cable: .plugged)
                .offset(y: float ? -6 : 4)
                .padding(.top, 14)
            VStack(spacing: 10) {
                Text("Welcome to Pulli").font(.pulli(40, .regular)).tracking(-0.6)
                Text("Plug in your Android phone with a data cable and unlock it. Pulli finds it by itself.")
                    .font(.pulli(15.5)).foregroundStyle(tone.t2).multilineTextAlignment(.center).frame(maxWidth: 470)
            }
            // Room for the cable lying in front of the phone.
            .padding(.top, 54)
            Spacer()
            HStack(spacing: 10) {
                GlowDot(color: .accent, size: 9)
                Text("Waiting for a phone…").font(.pulli(14, .medium))
            }
            .padding(.horizontal, 20).frame(height: 44)
            .panel(radius: 22)
            .accessibilityElement(children: .combine)
            .padding(.bottom, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            Group {
                // ImageRenderer draws a link as a yellow placeholder, so snapshots show its words.
                if isSnapshot {
                    Text("Phone not showing up?")
                } else {
                    Button("Phone not showing up?") {
                        model.showingPhoneHelp = true
                    }
                    .buttonStyle(InlineLinkStyle())
                }
            }
            .font(.pulli(12.5, .semibold)).foregroundStyle(tone.t2)
            .padding(24)
        }
        // No float: the 3D phone turns toward the pointer, and a SwiftUI animation that never
        // stops costs CPU the whole time the window is open.
    }
}

// MARK: - Opening

struct OpeningView: View {
    var device: DeviceSnapshot
    @Environment(\.tone) private var tone

    var body: some View {
        VStack(spacing: 20) {
            PhoneArt(width: 220, palette: .teal, screen: .blank, cable: .plugged)
            Text("Opening \(device.name)…").font(.pulli(24, .medium))
            ProgressView().controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Phone ready (cards)

struct OverviewView: View {
    var device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        let summary = model.summaries[device.id]
        let suggestion = model.state.devices[device.id]?.chunkSuggestion ?? device.chunkSuggestion
        VStack(spacing: 0) {
            if let suggestion {
                ChunkSuggestionCard(suggestion: suggestion, deviceName: device.name)
                    .padding(.horizontal, 32)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let summary {
                // Scrolls when messaging-app cards make it taller than the window; the selection
                // and the Copy button stay put below.
                Scrolling {
                    VStack(spacing: 0) {
                        Text("\(device.name) is ready. Here's what's on it:")
                            .font(.pulli(27, .medium)).tracking(-0.3)
                            .padding(.top, 18)
                        cards(summary)
                            .padding(.horizontal, 32).padding(.top, 26)
#if !PULLI_APP_STORE
                        if !summary.apps.isEmpty {
                            appCards(summary.apps)
                                .padding(.horizontal, 32).padding(.top, 18)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
#endif
                    }
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.never)
                selectionLine
                    .padding(.top, 12)
                    .padding(.horizontal, 32)
                    .padding(.trailing, 150)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 40)
            } else {
                Text("\(device.name) is ready. Here's what's on it:")
                    .font(.pulli(27, .medium)).tracking(-0.3)
                    .padding(.top, 18)
                Spacer()
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Looking at the phone…").font(.pulli(14, .medium)) }
                Spacer(minLength: 140)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: suggestion)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            let empty = model.pickedItems().paths.isEmpty
            CornerAction {
                Button("Copy") { Task { await model.copyPicks() } }
                    .buttonStyle(RoundActionButtonStyle())
                    .disabled(empty)
            }
        }
        .background {
            // Return copies (the button itself is in its own little window).
            Button("") { Task { await model.copyPicks() } }
                .keyboardShortcut(.defaultAction).opacity(0)
                .disabled(model.pickedItems().paths.isEmpty)
        }
    }

    /// Messaging apps' media (WhatsApp, Telegram, Instagram, Viber), measured over whole trees.
    private func appCards(_ apps: [AppMedia]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FROM YOUR APPS").font(.pulli(12, .bold)).tracking(0.8).foregroundStyle(tone.t3).padding(.leading, 2)
            HStack(spacing: 16) {
                ForEach(apps.prefix(3)) { app in
                    let style = StorageStyle.style(path: app.path, name: app.name)
                    PickCard(pick: app.pick, title: app.name, big: Format.count(app.files, "file"), small: Format.bytes(app.bytes),
                             art: Gem(form: .disc, palette: style.palette, symbol: style.symbol, size: 116), reviewPath: app.path)
                }
            }
            .frame(height: 160)
        }
    }

    private func cards(_ summary: PhoneSummary) -> some View {
        let newItems = summary.newItems
        // The Browse card goes in the first gap: the top row's if it has one, else Downloads' slot.
        let browseOnTop = summary.cameraMark == nil && (summary.screenshots == nil || summary.camera == nil)
        return VStack(spacing: 16) {
            HStack(spacing: 16) {
                if summary.cameraMark != nil {
                    PickCard(pick: .new, title: "New since last copy",
                             big: newItems.isEmpty ? "Nothing new" : Format.count(newItems.count, "item"),
                             small: newItems.isEmpty ? "Everything is already on your Mac" : "\(Format.bytes(summary.newBytes)) to copy",
                             art: Gem(form: .squircle, palette: .teal, symbol: "sparkles", size: 116, tilt: -10),
                             enabled: !newItems.isEmpty, reviewPath: summary.camera?.path)
                }
                if let camera = summary.camera {
                    PickCard(pick: .camera, title: "Camera", big: Format.count(camera.files.count, "photo"),
                             small: summary.cameraDuplicates.isEmpty ? "and videos · \(Format.bytes(camera.bytes))"
                                 : "\(summary.cameraDuplicates.count.formatted()) already on your Mac · \(Format.bytes(camera.bytes - summary.cameraDuplicateBytes)) new",
                             art: Gem(form: .disc, palette: .blue, symbol: "camera.aperture", size: 116), reviewPath: camera.path)
                }
                if let screenshots = summary.screenshots {
                    PickCard(pick: .screenshots, title: "Screenshots", big: Format.count(screenshots.files.count, "image"),
                             small: Format.bytes(screenshots.bytes),
                             art: Gem(form: .hexagon, palette: .violet, symbol: "iphone.gen3", size: 116), reviewPath: screenshots.path)
                }
                if browseOnTop {
                    BrowseCard()
                }
            }
            .frame(height: 172)
            GeometryReader { proxy in
                let first = (proxy.size.width - 16) / 2.25
                HStack(spacing: 16) {
#if !PULLI_APP_STORE
                    if let downloads = summary.downloads {
                        PickCard(pick: .downloads, title: "Downloads", big: Format.count(downloads.files.count, "file"),
                                 small: Format.bytes(downloads.bytes) + (downloads.folderCount > 0 ? " · \(Format.count(downloads.folderCount, "folder")) not counted" : ""),
                                 art: Gem(form: .squircle, palette: .sky, symbol: "arrow.down.to.line", size: 116, tilt: 8), reviewPath: downloads.path)
                            .frame(width: first)
                    } else if !browseOnTop {
                        BrowseCard().frame(width: first)
                    }
#else
                    if !browseOnTop {
                        BrowseCard().frame(width: first)
                    }
#endif
                    CableCard(device: device)
                }
            }
            .frame(height: 172)
        }
    }

    private var selectionLine: some View {
        let picked = model.pickedItems()
        let times = device.cable?.duration(ofBytes: picked.bytes)
        return Group {
            if picked.paths.isEmpty {
                Text("Tick what to copy, or browse the phone.").foregroundStyle(tone.t2)
            } else {
                let selected = HStack(spacing: 0) {
                    Text("Selected: ").foregroundStyle(tone.t2)
                    Text("\(Format.count(picked.count, "item")) · \(Format.bytes(picked.bytes))\(times.map { " · " + Format.about($0.now) } ?? "")")
                        .fontWeight(.semibold)
                    Text(" to \(Format.place(model.destination))\(model.state.settings.organize != nil ? " › year › month" : "") · ").foregroundStyle(tone.t2)
                    Button("Change") { model.chooseDestination() }.buttonStyle(InlineLinkStyle()).font(.pulli(14, .semibold))
                }
                if let faster = times?.faster {
                    // One line when it fits; otherwise the USB 3 hint gets its own line rather
                    // than breaking mid-phrase beside the Copy button.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 0) {
                            selected
                            Text(" · \(Format.about(faster)) with a USB 3 cable").fontWeight(.semibold).foregroundStyle(tone.amber)
                        }
                        .fixedSize()
                        VStack(alignment: .leading, spacing: 3) {
                            selected
                            Text("About \(Format.duration(faster)) with a USB 3 cable")
                                .fontWeight(.semibold).foregroundStyle(tone.amber)
                        }
                    }
                } else {
                    selected
                }
            }
        }
        .font(.pulli(14))
        .monospacedDigit()
    }
}

/// A tickable card for one of the phone's well-known folders.
private struct PickCard<Art: View>: View {
    var pick: PhonePick
    var title: String
    var big: String
    var small: String
    var art: Art
    var enabled = true
    var reviewPath: String?
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        let on = model.picks.contains(pick)
        CardShell(art: art, action: reviewPath.map { path in { model.openBrowser(at: path) } }, actionName: "Review") {
            Button {
                guard enabled else { return }
                if on { model.picks.remove(pick) } else {
                    model.picks.insert(pick)
                    if pick == .camera { model.picks.remove(.new) }
                    if pick == .new { model.picks.remove(.camera) }
                }
            } label: {
                HStack(spacing: 10) {
                    CheckBox(state: on ? .on : .off)
                    Text(title).font(.pulli(14, .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .accessibilityAddTraits(on ? .isSelected : [])
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(big).font(.pulli(28, .semibold)).tracking(-0.3).lineLimit(1).minimumScaleFactor(0.7)
                Text(small).font(.pulli(13.5)).foregroundStyle(tone.t2).lineLimit(2)
            }
            .monospacedDigit()
            Spacer(minLength: 8)
            if let reviewPath {
                Button("Review") { model.openBrowser(at: reviewPath) }.buttonStyle(PillButtonStyle(small: true))
            }
        }
        .opacity(enabled ? 1 : 0.75)
    }
}

private struct BrowseCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        CardShell(art: Gem(form: .squircle, palette: .slate, symbol: "folder.fill", size: 116, tilt: 6),
                  action: { model.openBrowser(at: "/") }, actionName: "Browse") {
            Text("Anything else").font(.pulli(14, .medium))
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Choose folders").font(.pulli(28, .semibold)).tracking(-0.3)
                Text("Browse the whole phone").font(.pulli(13.5)).foregroundStyle(tone.t2)
            }
            Spacer(minLength: 8)
            Button("Browse") { model.openBrowser(at: "/") }.buttonStyle(PillButtonStyle(small: true))
        }
    }
}

/// The cable card: the USB version now, whether a better cable or port would help, and by how much.
private struct CableCard: View {
    var device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @AppStorage("suggestCable") private var suggestCable = true

    var body: some View {
        let cable = device.cable
        let slow = suggestCable && (cable?.suggestion ?? .none) != .none
        let all = model.summaries[device.id]?.camera?.bytes ?? 0
        CardShell(art: Gem(form: .disc, palette: slow ? .amber : .green, symbol: slow ? "cable.connector" : "bolt.fill", size: 116),
                  tint: slow ? tone.amberFill : nil, action: slow ? { model.showingCableHelp = true } : nil, actionName: "Which Cable?") {
            Text("Cable · \(Format.link(device.link))\(cable.map { " · " + Format.speed($0.bytesPerSecond) } ?? "")\(cable?.measured == true ? " measured" : "")")
                .font(.pulli(14, .medium))
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(cable)).font(.pulli(28, .semibold)).tracking(-0.3).lineLimit(1).minimumScaleFactor(0.7)
                Text(detail(cable, allBytes: all)).font(.pulli(13.5)).foregroundStyle(tone.t2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if slow {
                Button("Which Cable?") { model.showingCableHelp = true }.buttonStyle(PillButtonStyle(small: true))
            }
        }
    }

    private func headline(_ cable: CableAdvice?) -> String {
        guard let cable, suggestCable else { return "Connected" }
        if let faster = cable.fasterBytesPerSecond {
            let factor = faster / max(cable.bytesPerSecond, 1)
            return cable.suggestion == .plugDirectly ? "Faster plugged in directly" : String(format: "%.0f× faster with USB 3", factor)
        }
        switch cable.suggestion {
        case .none: return device.link == .usb3 ? "Full speed" : "As fast as it goes"
        case .plugDirectly: return "Plug in directly"
        case .useUSB3Cable, .mayBeFaster: return "May be faster with USB 3"
        }
    }

    private func detail(_ cable: CableAdvice?, allBytes: UInt64) -> String {
        guard let cable, suggestCable else { return "Copies go as fast as the phone allows." }
        let model = device.model.map { "Your \($0.replacingOccurrences(of: " (simulated)", with: ""))" } ?? "Your phone"
        let times = cable.duration(ofBytes: allBytes)
        switch cable.suggestion {
        case .none:
            return cable.throughHub ? "Connected through a hub." : "\(model) is connected at its best speed."
        case .plugDirectly:
            return "It is connected through a hub, monitor or dock. A port on the Mac itself is faster."
        case .useUSB3Cable:
            if let faster = times.faster, allBytes > 0 {
                return "\(model) supports USB 3. All photos: \(Format.about(faster)) instead of \(Format.duration(times.now))."
            }
            return "\(model) supports USB 3. A USB 3 or Thunderbolt cable copies much faster."
        case .mayBeFaster:
            return "A USB 3 cable may copy faster, if the phone supports it."
        }
    }
}

/// Shared card layout: a title row, glossy art peeking in at the top right, a footer row. With an
/// `action`, a click anywhere on the card does what its button does (the tick box still ticks);
/// the art tilts toward the pointer anywhere on the card.
private struct CardShell<Art: View, Header: View, Footer: View>: View {
    var art: Art
    var tint: Color?
    var action: (() -> Void)?
    var actionName: String?
    @ViewBuilder var header: Header
    @ViewBuilder var footer: Footer
    @State private var hovering = false

    init(art: Art, tint: Color? = nil, action: (() -> Void)? = nil, actionName: String? = nil,
         @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.art = art
        self.tint = tint
        self.action = action
        self.actionName = actionName
        self.header = header()
        self.footer = footer()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            // The art sits behind the top-right corner: keep the title clear of it (a long title
            // wraps to a second line instead of running under the icon).
            HStack(alignment: .top, spacing: 0) { header; Spacer(minLength: 104) }
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 12) { footer }
        }
        .padding(.leading, 20).padding(.trailing, 18).padding(.top, 18).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .topTrailing) { art.offset(x: -8, y: 8).allowsHitTesting(false) }
        .panel(radius: 18, tint: tint)
        .overlay { if action != nil, hovering { shape.fill(.white.opacity(0.05)).allowsHitTesting(false) } }
        .overlay { if action != nil, hovering { shape.strokeBorder(.white.opacity(0.22), lineWidth: 1).allowsHitTesting(false) } }
        .offset(y: action != nil && hovering ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .modifier(CardPress(action: action))
        .parallaxSource()
        .accessibilityAction(named: actionName ?? "Open") { action?() }
    }
}

/// A click anywhere on a card (buttons inside it keep their own clicks).
private struct CardPress: ViewModifier {
    var action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .pointerStyle(.link)
                .onTapGesture { action() }
        } else {
            content
        }
    }
}

// MARK: - Another app holds the phone

struct BusyView: View {
    var device: DeviceSnapshot
    var app: String
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    /// Pulli itself has the phone: its background helper, or a second copy of the app.
    private var helper: Bool { app == "Pulli's background helper" || app == "Relay's background helper" }
    private var otherPulli: Bool { app == "Another copy of Pulli" || app == "Another copy of Relay" }

    private var isSystemDaemon: Bool {
        CameraClientApps.isSystemCameraDaemonName(app)
    }

    private var runningClient: (app: CameraClientApp, running: NSRunningApplication)? {
        guard isSystemDaemon else { return nil }
        return CameraClientApps.firstRunningApp()
    }

    private var titleText: String {
        if let running = runningClient {
            return "\(running.app.displayName) keeps taking the phone"
        }
        let name = isSystemDaemon ? CameraClientApps.photoServiceName : app
        return "\(name) is using your phone"
    }

    private var explanation: String {
        if let running = runningClient {
            return "Quit \(running.app.displayName), then Pulli carries on."
        }
        if helper {
            return "Pulli's background helper is copying from this phone. Connect to it to see and control its copies here."
        }
        if otherPulli {
            return "A second copy of Pulli is open (for example one opened from the disk image) and has the phone. Quit it and this one picks up the phone straight away."
        }
        let name = isSystemDaemon ? CameraClientApps.photoServiceName : app
        return "Only one app at a time can talk to the phone. Quit \(name) and Pulli picks up the connection straight away."
    }

    var body: some View {
        HStack(spacing: 40) {
            HStack(spacing: 4) {
                if helper || otherPulli {
                    Gem(form: .squircle, palette: .teal, symbol: "arrow.down.to.line", size: 170, tilt: -8)
                } else {
                    Gem(form: .squircle, palette: .pink, symbol: "photo.on.rectangle", size: 170, tilt: -8)
                }
                Image(systemName: "ellipsis").font(.system(size: 24, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                PhoneArt(width: 170, palette: .teal, screen: .photos, cable: .none)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text(titleText).font(.pulli(32, .medium))
                Text(explanation)
                    .font(.pulli(15)).foregroundStyle(tone.t2).frame(maxWidth: 400, alignment: .leading)
                HStack(spacing: 10) {
                    if let running = runningClient {
                        Button("Quit \(running.app.displayName)") {
                            running.running.terminate()
                        }
                        .buttonStyle(PillButtonStyle(kind: .strong))
                    } else if helper {
                        Button("Connect to the Helper") { Task { await model.reconnect() } }.buttonStyle(PillButtonStyle(kind: .strong))
                    } else if otherPulli {
                        Button("Quit the Other Pulli") { quitOtherPulli() }.buttonStyle(PillButtonStyle(kind: .strong))
                    } else {
                        let name = isSystemDaemon ? CameraClientApps.photoServiceName : app
                        Button("Quit \(name)") {
                            quit(name)
                            if isSystemDaemon {
                                Task { await model.retryOpening() }
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .strong))
                    }
                }
                Text("Pulli releases the phone from macOS's own camera service by itself. It never closes an app you opened without asking.")
                    .font(.pulli(12.5)).foregroundStyle(tone.t3).frame(maxWidth: 400, alignment: .leading)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { notification in
            if let running = runningClient,
               let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               terminated.bundleIdentifier?.caseInsensitiveCompare(running.app.bundleID) == .orderedSame {
                Task { await model.retryOpening() }
            } else if let terminated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      terminated.localizedName == app {
                Task { await model.retryOpening() }
            }
        }
    }

    private func quit(_ name: String) {
        for running in NSWorkspace.shared.runningApplications where running.localizedName == name {
            running.terminate()
        }
    }

    private func quitOtherPulli() {
        let me = ProcessInfo.processInfo.processIdentifier
        for running in NSWorkspace.shared.runningApplications
        where running.bundleIdentifier == Bundle.main.bundleIdentifier && running.processIdentifier != me {
            running.terminate()
        }
    }
}

struct ReplugView: View {
    var device: DeviceSnapshot
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 40) {
            PhoneArt(width: 250, palette: .amber, screen: .pause, cable: .unplugged)
            VStack(alignment: .leading, spacing: 16) {
                Text("Unplug \(device.name) and plug it back in").font(.pulli(30, .medium))
                Text("The phone stopped answering. This happens on some phones after a long pause. Nothing copied so far is lost; any copy carries on once the phone is back.")
                    .font(.pulli(15)).foregroundStyle(tone.t2).frame(maxWidth: 440, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
    }
}

// MARK: - Which cable?

struct CableHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Gem(form: .disc, palette: .amber, symbol: "cable.connector", size: 64)
                Text("Which cable is faster?").font(.pulli(22, .semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                row("Use a USB 3 or Thunderbolt cable.", "Most phone chargers come with USB 2 cables, which top out near 40 MB/s. A cable marked SS, 5/10 Gbps, USB 3 or Thunderbolt carries far more.")
                row("Plug into the Mac itself.", "Hubs, monitors and docks often run at USB 2 speed.")
                row("Try the plug the other way round.", "On some phones a USB-C plug only reaches full speed in one orientation.")
            }
            if let cable = model.device?.cable {
                Text("Now: \(Format.link(cable.link)), about \(Format.speed(cable.bytesPerSecond))\(cable.fasterBytesPerSecond.map { " · with USB 3: about \(Format.speed($0))" } ?? "")")
                    .font(.pulli(13, .semibold)).monospacedDigit()
            }
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(kind: .strong)).keyboardShortcut(.defaultAction) }
        }
        .padding(28)
        .frame(width: 480)
        .background(SceneBackground(kind: .home, animated: false))
        .modifier(ToneProvider())
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.pulli(14, .semibold))
            Text(detail).font(.pulli(13)).opacity(0.8).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Phone not showing up?

struct PhoneHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.tone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Gem(form: .disc, palette: .teal, symbol: "questionmark.circle", size: 64)
                Text("Phone not showing up?").font(.pulli(22, .semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                row("Unlock the phone and allow access.", "Tap the USB notification on your phone and choose File transfer instead of Charging only.")
                row("Try another cable or port.", "Many charger cables only carry power, not data. Plug into a port directly on your Mac rather than a hub.")
                row("Another app may be using the phone.", "Google Drive, Dropbox, Photos, Image Capture, Preview or Lightroom - quit it, then unplug the phone and plug it back in.")
            }
            HStack {
                Link("More troubleshooting…", destination: URL(string: "https://support.google.com/android/answer/9064445")!)
                    .font(.pulli(13)).foregroundStyle(tone.t2)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PillButtonStyle(kind: .strong)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 480)
        .background(SceneBackground(kind: .home, animated: false))
        .modifier(ToneProvider())
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.pulli(14, .semibold))
            Text(detail).font(.pulli(13)).opacity(0.8).fixedSize(horizontal: false, vertical: true)
        }
    }
}
