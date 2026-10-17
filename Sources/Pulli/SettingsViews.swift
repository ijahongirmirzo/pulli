import AppKit
import PulliProtocol
import SwiftUI

/// Settings: General, Sounds, Advanced. App preferences live in UserDefaults; copy behaviour is
/// the engine's `HelperSettings`, sent to it on change.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Sounds", systemImage: "speaker.wave.2") { SoundSettings() }
            Tab("Advanced", systemImage: "sparkles") { AdvancedSettings() }
        }
        .frame(width: 640, height: 620)
        .modifier(ToneProvider())
    }
}

private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(SceneBackground(kind: .slate, animated: false))
        .modifier(ToneProvider())
    }
}

private struct Group_<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }.panel(radius: 16)
    }
}

private struct Row<Control: View>: View {
    var title: String
    var detail: String?
    var divider = true
    @ViewBuilder var control: Control
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.pulli(13.5, .medium))
                if let detail { Text(detail).font(.pulli(12)).foregroundStyle(tone.t2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .overlay(alignment: .top) { if divider { Rectangle().fill(tone.separator).frame(height: 1) } }
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("showMenuBar") private var showMenuBar = true
    @AppStorage("suggestCable") private var suggestCable = true
    @AppStorage("skipDuplicates") private var skipDuplicates = true
    @AppStorage("notifyCopies") private var notifyCopies = true
    @AppStorage("autoCopyNew") private var autoCopyNew = false
#if !PULLI_APP_STORE
    @State private var backgroundHelper = HelperRegistration.isEnabled
    @State private var helperNote: String?
#endif
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginNote: String?
    @AppStorage("openOnConnect") private var openOnConnect = true
    @AppStorage("theme") private var theme = AppTheme.porcelain.rawValue

    var body: some View {
        SettingsPage {
            Group_ {
                Row(title: "Copy to", detail: "Where new copies go unless you choose another folder.", divider: false) {
                    Button { chooseDefault() } label: {
#if PULLI_APP_STORE
                        Label(model.state.settings.defaultDestination.map(Format.place) ?? "Downloads › Pulli", systemImage: "folder")
#else
                        Label(model.state.settings.defaultDestination.map(Format.place) ?? "Downloads › phone name", systemImage: "folder")
#endif
                    }
                    .buttonStyle(PillButtonStyle(small: true))
                }
                Row(title: "Organise copies", detail: "Put photos and videos in folders by the date they were taken, like 2026 › 09.") {
                    Picker("", selection: organizeBinding) {
                        Text("Keep the phone's folders").tag("")
                        Text("By year and month").tag("year_month")
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Skip files already on my Mac", detail: "Found by content in Pictures and the destination, even under other names.") {
                    Toggle("", isOn: $skipDuplicates).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
                Row(title: "When a file already exists", detail: "Same size and date means it is already there.") {
                    Picker("", selection: duplicateBinding) {
                        Text("Skip if identical, else keep both").tag("auto")
                        Text("Always skip").tag("skip")
                        Text("Keep both").tag("keep_both")
                        Text("Replace").tag("overwrite")
                    }
                    .labelsHidden().fixedSize()
                }
            }
            Group_ {
#if !PULLI_APP_STORE
                Row(title: "Keep copying when Pulli is closed", detail: helperNote ?? model.helperProblem ?? "A background helper keeps copies going after you quit, and after a restart.", divider: false) {
                    Toggle("", isOn: $backgroundHelper).labelsHidden().toggleStyle(.switch).tint(.accent)
                        .onChange(of: backgroundHelper) { _, on in setHelper(on) }
                }
#endif
                Row(title: "Keep the Mac awake while copying", detail: "The display can still sleep.") {
                    Toggle("", isOn: settingBinding(\.keepMacAwake)).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
                Row(title: "Look", detail: "Porcelain is calm and light; Graphite is dark and quiet; Midnight is deep indigo; Classic is the original teal.") {
                    Picker("", selection: Binding(get: { theme }, set: { value in
                        // The global first, so the window redraws in the new colours.
                        AppTheme.current = AppTheme(rawValue: value) ?? .porcelain
                        theme = value
                    })) {
                        ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize()
                }
                Row(title: "Show Pulli in the menu bar", detail: "Every copy's progress, one click away.") {
                    Toggle("", isOn: $showMenuBar).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
                Row(title: "Open Pulli at login", detail: loginNote ?? "Starts quietly with your Mac, with no window, and watches for phones. It uses little memory until one is plugged in.") {
                    Toggle("", isOn: $openAtLogin).labelsHidden().toggleStyle(.switch).tint(.accent)
                        .onChange(of: openAtLogin) { _, on in setLogin(on) }
                }
                Row(title: "Open the window when a phone connects", detail: "When Pulli is in the background. Otherwise it sends a notification.") {
                    Toggle("", isOn: $openOnConnect).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
                Row(title: "Suggest a faster cable", detail: "Tell me when a phone could copy faster with another cable or port.") {
                    Toggle("", isOn: $suggestCable).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
#if !PULLI_APP_STORE
                Row(title: "Check for updates automatically", detail: "Check for new versions quietly in the background.") {
                    Toggle("", isOn: updateCheckBinding).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
#endif
            }
            Group_ {
                Row(title: "Notify me about copies", detail: "When a copy finishes or needs you, while Pulli is in the background.", divider: false) {
                    Toggle("", isOn: $notifyCopies).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
                Row(title: "Copy new photos when a phone connects", detail: "For phones Pulli copied before: new camera photos and videos go straight to the usual folder.") {
                    Toggle("", isOn: $autoCopyNew).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
            }
        }
    }

#if !PULLI_APP_STORE
    private var updateCheckBinding: Binding<Bool> {
        Binding(
            get: {
                AppDelegate.updaterController?.updater.automaticallyChecksForUpdates
                    ?? UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
            },
            set: { on in
                AppDelegate.updaterController?.updater.automaticallyChecksForUpdates = on
                UserDefaults.standard.set(on, forKey: "SUEnableAutomaticChecks")
            }
        )
    }
#endif

    private var organizeBinding: Binding<String> {
        Binding(get: { model.state.settings.organize ?? "" }, set: { value in
            var settings = model.state.settings
            settings.organize = value.isEmpty ? nil : value
            Task { await model.update(settings) }
        })
    }

    private var duplicateBinding: Binding<String> {
        Binding(get: { model.state.settings.duplicatePolicy }, set: { value in
            var settings = model.state.settings
            settings.duplicatePolicy = value
            Task { await model.update(settings) }
        })
    }

    private func settingBinding(_ keyPath: WritableKeyPath<HelperSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.state.settings[keyPath: keyPath] }, set: { value in
            var settings = model.state.settings
            settings[keyPath: keyPath] = value
            Task { await model.update(settings) }
        })
    }

    private func chooseDefault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
#if PULLI_APP_STORE
        SandboxBookmark.shared.saveBookmark(for: url)
#endif
        var settings = model.state.settings
        settings.defaultDestination = url.path
        Task { await model.update(settings) }
    }

    private func setLogin(_ on: Bool) {
        guard on != LoginItem.isEnabled else { return }
        do {
            try LoginItem.setEnabled(on)
            if LoginItem.needsApproval {
                loginNote = "Allow Pulli in System Settings › General › Login Items."
                HelperRegistration.openLoginItemsSettings()
            } else {
                loginNote = nil
            }
            // Watching for phones with no window follows this setting.
            model.updateWatching()
        } catch {
            loginNote = "Could not \(on ? "turn on" : "turn off") opening at login: \(error.localizedDescription)"
            openAtLogin = LoginItem.isEnabled
        }
    }

#if !PULLI_APP_STORE
    private func setHelper(_ on: Bool) {
        guard on != HelperRegistration.isEnabled else { return }
        do {
            try HelperRegistration.setEnabled(on)
            if HelperRegistration.needsApproval {
                helperNote = "Allow Pulli in System Settings › General › Login Items, then reopen Pulli."
                HelperRegistration.openLoginItemsSettings()
            } else {
                helperNote = nil
                Task { await model.reconnect() }
            }
        } catch {
            helperNote = "Could not \(on ? "turn on" : "turn off") the background helper: \(error.localizedDescription)"
            backgroundHelper = HelperRegistration.isEnabled
        }
    }
#endif
}

private struct SoundSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("playSounds") private var playSounds = true
    @AppStorage("soundVolume") private var volume = 0.7

    var body: some View {
        SettingsPage {
            Group_ {
                Row(title: "Play sounds", detail: "A soft chime when a phone connects and when a copy finishes.", divider: false) {
                    Toggle("", isOn: $playSounds).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
                Row(title: "Volume", detail: "Relative to the Mac's alert volume.") {
                    Slider(value: $volume, in: 0...1).frame(width: 170).tint(.accent)
                }
            }
            Group_ {
                ForEach(Array([SoundPlayer.Cue.connect, .start, .pause, .resume, .done, .attention].enumerated()), id: \.element) { index, cue in
                    CueRow(cue: cue, divider: index > 0)
                }
            }
            .disabled(!playSounds)
            .opacity(playSounds ? 1 : 0.5)
            Text("Pulli stays silent when the Mac's \u{201C}Play user interface sound effects\u{201D} is off, and plays at most one sound a second, never one per file.")
                .font(.pulli(12)).opacity(0.8)
        }
    }
}

private struct CueRow: View {
    var cue: SoundPlayer.Cue
    var divider: Bool
    @Environment(AppModel.self) private var model
    @AppStorage private var on: Bool

    init(cue: SoundPlayer.Cue, divider: Bool) {
        self.cue = cue
        self.divider = divider
        _on = AppStorage(wrappedValue: cue != .start, cue.settingKey)
    }

    var body: some View {
        Row(title: cue.title, divider: divider) {
            Button { model.sounds.play(cue, force: true) } label: { Image(systemName: "play.fill") }
                .buttonStyle(PillButtonStyle(small: true))
                .accessibilityLabel("Play \(cue.title)")
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).tint(.accent)
        }
    }
}

private struct AdvancedSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("introShown") private var introShown = false

    var body: some View {
        SettingsPage {
            Group_ {
                Row(title: "Chunk size", detail: "8 MB is fastest on most phones; larger chunks react later to problems.", divider: false) {
                    Picker("", selection: chunkBinding) {
                        ForEach([4, 8, 16, 32, 64], id: \.self) { Text("\($0) MB").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                if let overrides = model.state.settings.chunkMiBByDevice, !overrides.isEmpty {
                    ForEach(overrides.keys.sorted(), id: \.self) { deviceID in
                        let size = overrides[deviceID] ?? model.state.settings.chunkMiB
                        let name = model.state.devices[deviceID]?.name ?? deviceID
                        Row(title: "\(name) uses \(size) MB", divider: true) {
                            Button("Use Default") {
                                removeDeviceChunkOverride(deviceID)
                            }
                            .buttonStyle(PillButtonStyle(small: true))
                        }
                    }
                }
            }
#if !PULLI_APP_STORE
            Group_ {
                Row(title: "Free the phone from Image Capture automatically",
                    detail: "macOS's camera service grabs Android phones when plugged in. Pulli releases it while copying; iPhone and camera imports pause meanwhile.",
                    divider: false) {
                    Toggle("", isOn: Binding(get: { model.state.settings.releaseSystemCameraService }, set: { value in
                        var settings = model.state.settings
                        settings.releaseSystemCameraService = value
                        Task { await model.update(settings) }
                    })).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
            }
            Group_ {
                Row(title: "Allow deleting and renaming in Finder",
                    detail: "When a phone is open in Finder, Finder may delete and rename its files. Copying to the phone always works; files deleted this way cannot be recovered.",
                    divider: false) {
                    Toggle("", isOn: Binding(get: { model.state.settings.allowDriveChanges ?? false }, set: { value in
                        var settings = model.state.settings
                        settings.allowDriveChanges = value
                        Task { await model.update(settings) }
                    })).labelsHidden().toggleStyle(.switch).tint(.accent)
                }
            }
#endif
            Group_ {
                Row(title: "Activity log", detail: "Recent events, for troubleshooting.", divider: false) {
                    Button("Open Log") { openWindow(id: "activity") }.buttonStyle(PillButtonStyle(small: true))
                }
                Row(title: "Introduction", detail: "Play the welcome animation again next time Pulli opens.") {
                    Button("Show Again") { introShown = false }.buttonStyle(PillButtonStyle(small: true)).disabled(!introShown)
                }
            }
        }
    }

    private var chunkBinding: Binding<Int> {
        Binding(get: { model.state.settings.chunkMiB }, set: { value in
            var settings = model.state.settings
            settings.chunkMiB = value
            Task { await model.update(settings) }
        })
    }

    private func removeDeviceChunkOverride(_ deviceID: String) {
        var settings = model.state.settings
        var overrides = settings.chunkMiBByDevice ?? [:]
        overrides.removeValue(forKey: deviceID)
        settings.chunkMiBByDevice = overrides.isEmpty ? nil : overrides
        Task { await model.update(settings) }
    }
}
