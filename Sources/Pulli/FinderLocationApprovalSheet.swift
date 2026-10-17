import AppKit
import SwiftUI

/// The one switch macOS asks for before Pulli can list phones under Locations in Finder, as an
/// animated tutorial (owner request, 2026-10-14): a small System Settings window acts the steps
/// out (the pointer goes to General, Login Items & Extensions, the ⓘ beside File Providers, and
/// switches Pulli on) while the matching step lights up beside it. Pulli checks every second and
/// a half whether the switch is on, then shows a tick and moves on by itself.
struct FinderLocationApprovalSheet: View {
    var dismiss: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Whether macOS has the extension switched on now.
    var isEnabled: () async -> Bool = { false }
    /// Called once it is on (the sheet closes and the phone opens in Finder).
    var enabled: () -> Void = {}
    /// Snapshots only: show this scene, still (their renderer runs no tasks).
    var still: SettingsScene?

    @Environment(\.tone) private var tone
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var scene = SettingsScene.sidebar
    @State private var pointer = CGPoint(x: 300, y: 230)
    @State private var pressed = false
    @State private var done = false

    static let steps: [(title: String, detail: String)] = [
        ("Open System Settings", "The button below opens it at the right page."),
        ("General › Login Items & Extensions", "In the sidebar, then the list on the right."),
        ("File Providers ⓘ", "Scroll to Extensions and click the ⓘ beside File Providers."),
        ("Switch on Pulli", "Pulli sees it straight away and opens your phone in Finder."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 26) {
                SettingsMock(scene: still ?? scene, pointer: still.map(Self.pointer(for:)) ?? pointer, pressed: pressed, done: done)
                    .frame(width: 380, height: 300)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Show your phone in Finder").font(.pulli(22, .semibold))
                    Text("macOS asks once before Pulli can list phones under Locations.")
                        .font(.pulli(13.5)).foregroundStyle(tone.t2)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                            row(index: index, title: step.title, detail: step.detail, current: index == (still ?? scene).step && !done)
                        }
                    }
                }
                .frame(width: 300, alignment: .leading)
            }
            HStack(spacing: 10) {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tone.green)
                    Text("Pulli is on. Opening your phone in Finder…").font(.pulli(13.5, .medium))
                } else {
                    GlowDot(color: .accent)
                    Text("Pulli continues as soon as it is switched on.").font(.pulli(13.5)).foregroundStyle(tone.t2)
                }
                Spacer()
                Button("Not Now", action: dismiss).buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Open System Settings", action: openSettings)
                    .buttonStyle(PillButtonStyle(kind: .accent)).keyboardShortcut(.defaultAction)
                    .disabled(done)
            }
        }
        .padding(28)
        .frame(width: 760)
        .background(SceneBackground(kind: .home, animated: false))
        .task { await tour() }
        .task { await watch() }
    }

    /// Where the pointer rests in a still scene.
    static func pointer(for scene: SettingsScene) -> CGPoint {
        switch scene {
        case .sidebar: CGPoint(x: 300, y: 230)
        case .general: SettingsMock.Spot.general.point
        case .loginItems, .extensions: SettingsMock.Spot.loginItems.point
        case .providers(let on): on ? SettingsMock.Spot.pulliSwitch.point : SettingsMock.Spot.fileProvidersInfo.point
        }
    }

    private func row(index: Int, title: String, detail: String, current: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index + 1)").font(.pulli(12.5, .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(current ? Color.accent : tone.t3.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.pulli(14, .semibold))
                Text(detail).font(.pulli(12.5)).foregroundStyle(tone.t2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(current ? Color.accent.opacity(0.13) : .clear))
        .opacity(current ? 1 : 0.6)
        .animation(.easeInOut(duration: 0.3), value: current)
    }

    // MARK: The tour

    /// Acts the steps out on the mock window, and round again. Every move is a short, discrete
    /// animation; between them the view is still (nothing redraws while it waits).
    private func tour() async {
        guard !isSnapshot else {
            scene = .providers(on: false)
            pointer = SettingsMock.Spot.pulliSwitch.point
            return
        }
        while !Task.isCancelled && !done {
            scene = .sidebar
            pointer = CGPoint(x: 300, y: 230)
            guard await pause(0.9) else { return }
            guard await click(.general, then: .general) else { return }
            guard await pause(0.5) else { return }
            guard await click(.loginItems, then: .loginItems) else { return }
            guard await pause(0.4) else { return }
            withAnimation(.easeInOut(duration: 0.6)) { scene = .extensions }
            guard await pause(0.8) else { return }
            guard await click(.fileProvidersInfo, then: .providers(on: false)) else { return }
            guard await pause(0.5) else { return }
            guard await click(.pulliSwitch, then: .providers(on: true)) else { return }
            guard await pause(2.2) else { return }
        }
    }

    /// Moves the pointer to a spot, presses, and shows the next scene.
    private func click(_ spot: SettingsMock.Spot, then next: SettingsScene) async -> Bool {
        withAnimation(.easeInOut(duration: 0.7)) { pointer = spot.point }
        guard await pause(0.75) else { return false }
        withAnimation(.easeOut(duration: 0.1)) { pressed = true }
        guard await pause(0.14) else { return false }
        withAnimation(.easeOut(duration: 0.15)) { pressed = false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { scene = next }
        return true
    }

    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    /// Checks whether the switch is on, every second and a half.
    private func watch() async {
        guard !isSnapshot else { return }
        while !Task.isCancelled {
            if await isEnabled() {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    done = true
                    scene = .providers(on: true)
                }
                try? await Task.sleep(for: .seconds(1.3))
                enabled()
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

/// What the mock System Settings window shows.
enum SettingsScene: Equatable {
    case sidebar, general, loginItems, extensions
    case providers(on: Bool)

    /// The step (0-based) beside it that lights up.
    var step: Int {
        switch self {
        case .sidebar: 0
        case .general, .loginItems: 1
        case .extensions: 2
        case .providers(let on): on ? 3 : 2
        }
    }
}

/// A small System Settings window, drawn (not a screenshot): sidebar, a page, and the File
/// Providers sheet, in the system's light or dark look.
struct SettingsMock: View {
    var scene: SettingsScene
    var pointer: CGPoint
    var pressed: Bool
    var done: Bool
    @Environment(\.colorScheme) private var scheme

    /// Where the pointer goes, in the mock's 380 × 300 points.
    enum Spot {
        case general, loginItems, fileProvidersInfo, pulliSwitch

        var point: CGPoint {
            switch self {
            // Measured from rendered snapshots: the pointer's tip lands on the control.
            case .general: CGPoint(x: 58, y: 95)
            case .loginItems: CGPoint(x: 215, y: 136)
            case .fileProvidersInfo: CGPoint(x: 350, y: 79)
            case .pulliSwitch: CGPoint(x: 298, y: 163)
            }
        }
    }

    private var dark: Bool { scheme == .dark }
    private var window: Color { dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xF5F5F7) }
    private var sidebar: Color { dark ? Color(hex: 0x232327) : Color(hex: 0xE9E9EC) }
    private var card: Color { dark ? Color(hex: 0x36363B) : .white }
    private var text: Color { dark ? .white.opacity(0.92) : Color(hex: 0x1D1D1F) }
    private var faint: Color { dark ? .white.opacity(0.5) : Color(hex: 0x1D1D1F, opacity: 0.5) }
    private var line: Color { dark ? .white.opacity(0.08) : .black.opacity(0.07) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(window)
            HStack(spacing: 0) {
                sidebarList.frame(width: 120)
                Rectangle().fill(line).frame(width: 1)
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            if case .providers(let on) = scene { providersSheet(on: on).transition(.opacity.combined(with: .scale(scale: 0.96))) }
            pointerArrow.position(pointer)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(line, lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.45 : 0.16), radius: 18, y: 10)
        .accessibilityHidden(true)
    }

    // MARK: Parts

    private var sidebarList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                ForEach([UInt32(0xFF5F57), 0xFEBC2E, 0x28C840], id: \.self) { Circle().fill(Color(hex: $0)).frame(width: 9, height: 9) }
            }
            .padding(.bottom, 12)
            item("wifi", "Wi-Fi", 0x0A84FF, selected: false)
            item("network", "Network", 0x0A84FF, selected: false)
            item("bell.badge.fill", "Notifications", 0xFF453A, selected: false)
            item("gearshape.fill", "General", 0x8E8E93, selected: scene != .sidebar)
            item("paintbrush.fill", "Appearance", 0x1C1C1E, selected: false)
            item("lock.fill", "Privacy & Security", 0x0A84FF, selected: false)
            Spacer()
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(sidebar)
    }

    private func item(_ symbol: String, _ title: String, _ colour: UInt32, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 7.5, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 15, height: 15).background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: colour)))
            Text(title).font(.system(size: 9.5)).foregroundStyle(selected ? .white : text).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color(hex: 0x0A84FF) : .clear))
    }

    @ViewBuilder private var page: some View {
        switch scene {
        case .sidebar:
            VStack(alignment: .leading, spacing: 8) {
                pageTitle("Wi-Fi")
                group(["Wi-Fi", "Known Networks", "Other Networks", "Advanced…"], highlight: nil)
            }
        case .general:
            VStack(alignment: .leading, spacing: 8) {
                pageTitle("General")
                group(["About", "Software Update", "Storage", "AirDrop & Handoff", "Login Items & Extensions", "Date & Time"], highlight: nil)
            }
        case .loginItems:
            VStack(alignment: .leading, spacing: 8) {
                pageTitle("General")
                group(["About", "Software Update", "Storage", "AirDrop & Handoff", "Login Items & Extensions", "Date & Time"], highlight: 4)
            }
        case .extensions, .providers:
            VStack(alignment: .leading, spacing: 8) {
                pageTitle("Login Items & Extensions")
                Text("Extensions").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(faint).padding(.leading, 14)
                VStack(spacing: 0) {
                    extensionRow("Added Extensions", info: false)
                    extensionRow("File Providers", info: true)
                    extensionRow("Quick Look", info: false)
                    extensionRow("Sharing", info: false)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(card))
                .padding(.horizontal, 12)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(text)
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 4)
    }

    private func group(_ rows: [String], highlight: Int?) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, title in
                HStack {
                    Text(title).font(.system(size: 9.5)).foregroundStyle(text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(faint)
                }
                .padding(.horizontal, 10).padding(.vertical, 6.5)
                .background(index == highlight ? Color(hex: 0x0A84FF).opacity(0.18) : .clear)
                if index < rows.count - 1 { Rectangle().fill(line).frame(height: 1).padding(.leading, 10) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(card))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
    }

    private func extensionRow(_ title: String, info: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 9.5, weight: info ? .semibold : .regular)).foregroundStyle(text)
            Spacer()
            Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(info ? Color(hex: 0x0A84FF) : faint)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func providersSheet(on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("File Providers").font(.system(size: 11.5, weight: .bold)).foregroundStyle(text)
            VStack(spacing: 0) {
                providerRow("Google Drive", symbol: "externaldrive.fill", on: true, highlight: false)
                Rectangle().fill(line).frame(height: 1)
                providerRow("Pulli", symbol: "smartphone", on: on, highlight: true)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(dark ? Color(hex: 0x2A2A2E) : Color(hex: 0xF5F5F7)))
            HStack {
                Spacer()
                Text("Done").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(Color(hex: 0x0A84FF)))
            }
        }
        .padding(14)
        .frame(width: 230)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(card))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
        .position(x: 220, y: 175)
    }

    private func providerRow(_ name: String, symbol: String, on: Bool, highlight: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(text).frame(width: 14)
            Text(name).font(.system(size: 10, weight: highlight ? .semibold : .regular)).foregroundStyle(text)
            Spacer()
            Capsule().fill(on ? Color(hex: highlight && done ? 0x30D158 : 0x0A84FF) : faint.opacity(0.45))
                .frame(width: 26, height: 15)
                .overlay(alignment: on ? .trailing : .leading) { Circle().fill(.white).padding(1.5).shadow(radius: 0.5) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var pointerArrow: some View {
        Image(systemName: "cursorarrow")
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.black)
            .background(Image(systemName: "cursorarrow").font(.system(size: 17, weight: .black)).foregroundStyle(.white))
            .scaleEffect(pressed ? 0.85 : 1)
            .offset(x: 6, y: 33)  // the arrow's tip on the point (measured)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .opacity(done ? 0 : 1)
    }
}

/// Presents the tutorial as a sheet on Pulli's main window.
@MainActor
enum FinderLocationApprovalPresenter {
    private static weak var currentSheet: NSWindow?

    static func show(onDismiss: @escaping () -> Void, onOpenSettings: @escaping () -> Void,
                     isEnabled: @escaping () async -> Bool, onEnabled: @escaping () -> Void) {
        guard currentSheet == nil else { return }
        guard let parentWindow = NSApp.windows.first(where: { ($0.title == "Pulli" || $0.identifier?.rawValue == "main") && $0.isVisible })
            ?? NSApp.mainWindow
            ?? NSApp.keyWindow else {
            return
        }
        guard parentWindow.attachedSheet == nil else { return }

        let sheetWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        sheetWindow.isReleasedWhenClosed = false
        sheetWindow.titleVisibility = .hidden
        sheetWindow.titlebarAppearsTransparent = true

        func close() {
            if let sheet = currentSheet { parentWindow.endSheet(sheet) }
            currentSheet = nil
        }
        let view = FinderLocationApprovalSheet(
            dismiss: { onDismiss(); close() },
            openSettings: onOpenSettings,  // the sheet stays: it moves on once the switch is on
            isEnabled: isEnabled,
            enabled: { close(); onEnabled() }
        )
        .modifier(ToneProvider())
        sheetWindow.contentViewController = NSHostingController(rootView: view)
        currentSheet = sheetWindow
        parentWindow.beginSheet(sheetWindow)
    }
}
