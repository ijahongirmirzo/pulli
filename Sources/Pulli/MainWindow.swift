import PulliProtocol
import SwiftUI

/// What the main window shows, derived from the model.
enum Route: Equatable {
    case starting
    case failed(String)
    case welcome
    case opening(DeviceSnapshot)
    case overview(DeviceSnapshot)
    case guide(DeviceSnapshot)
    case busy(DeviceSnapshot, app: String)
    case replug(DeviceSnapshot)
    case browse(DeviceSnapshot, path: String)
    case storageMap(DeviceSnapshot)
    case freeUp(BatchSnapshot)
    case copying(BatchSnapshot)
    case paused(BatchSnapshot, PauseReason)
    case done(BatchSnapshot)
    case noCopies
    case history
    case attention

    var scene: SceneKind {
        switch self {
        case .copying: .copying
        case .paused(_, .queued): .copying
        case .paused: .paused
        case .done(let batch): batch.phase == .completed ? .done : .slate
        case .history, .attention, .storageMap, .freeUp: .history
        case .failed: .slate
        default: .home
        }
    }

    var title: String? {
        switch self {
        case .starting, .welcome, .failed: nil
        case .opening(let device), .overview(let device), .guide(let device), .busy(let device, _), .replug(let device): device.name
        case .browse(_, let path): path == "/" ? "Internal storage" : (path as NSString).lastPathComponent
        case .storageMap: "Storage Map"
        case .freeUp: "Free Up Space"
        case .copying: "Copying"
        case .paused(_, .queued): "Waiting"
        case .paused: "Paused"
        case .done(let batch): batch.phase == .completed ? "Copy finished" : "Copy stopped"
        case .noCopies: "Copies"
        case .history: "History"
        case .attention: "Needs attention"
        }
    }
}

extension AppModel {
    var route: Route {
        switch connection {
        case .starting: return .starting
        case .failed(let message): return .failed(message)
        case .embedded, .helper: break
        }
        switch section {
        case .phone:
            guard let device else { return .welcome }
            switch device.state {
            case .ready:
                if let browsePath { return .browse(device, path: browsePath) }
#if !PULLI_APP_STORE
                if showingStorageMap { return .storageMap(device) }
#endif
                return .overview(device)
            case .locked, .notInFileTransferMode: return .guide(device)
            case .heldBy(let app): return .busy(device, app: app)
            case .needsReplug: return .replug(device)
            case .connecting, .unknown: return .opening(device)
            }
        case .copies:
            guard let batch = focusedBatch else { return .noCopies }
            if let freeUp, freeUp.batchID == batch.id { return .freeUp(batch) }
            switch batch.phase {
            case .copying, .scanning, .unknown: return .copying(batch)
            case .paused(let reason): return .paused(batch, reason)
            case .completed, .cancelled: return .done(batch)
            }
        case .history: return .history
        case .attention: return .attention
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var search = ""
    @State private var offeringMove = false
    /// View › Hide Sidebar (⌘⌃S): the icon strip instead of the labelled sidebar; remembered.
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var windowWidth: CGFloat = 1300

    /// Below this width the sidebar folds to icons by itself, so the content keeps its room.
    static let foldWidth: CGFloat = 1100

    @ViewBuilder
    private var notices: some View {
        if let banner = model.banner {
            BannerView(text: banner) { model.banner = nil }
                .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if let troubleID = model.finderTrouble {
            let name = model.state.devices[troubleID]?.name ?? model.device?.name ?? "the phone"
            FinderTroubleNote(name: name) {
                model.finderTrouble = nil
            } onBrowse: {
                model.finderTrouble = nil
                if model.section != .phone {
                    model.show(.phone)
                }
                model.openBrowser(at: "/")
            }
            .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    var body: some View {
        let route = model.route
        let fullSidebar = !sidebarCollapsed && windowWidth >= Self.foldWidth
        ZStack(alignment: .top) {
            SceneBackground(kind: route.scene)
            HStack(spacing: 0) {
                Group {
                    if fullSidebar { FullSidebar() } else { Rail() }
                }
                .padding(.top, 52)
                .overlay(alignment: .trailing) { Rectangle().fill(.separator.opacity(0.5)).frame(width: 1).padding(.top, 52) }
                VStack(spacing: 0) {
                    // Lasting notices sit above the page and push it down: they never cover it.
                    notices
                    // The content area clips the sliding screens, so they scroll in and out of it.
                    ZStack {
                        screen(route)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(routeIdentity(route))
                            .transition(model.navTransition.transition)
                    }
                    // A page's own art (the welcome phone, the Done disc…) follows the pointer
                    // anywhere on the page; cards set their own, so their art follows the card.
                    .parallaxSource()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                .padding(.top, 52)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.pulliNavigation, value: model.banner)
                .animation(.pulliNavigation, value: model.finderTrouble)
            }
            .animation(model.navTransition == .fade ? .easeInOut(duration: 0.3) : .pulliNavigation, value: routeIdentity(route))
            TitleBar(route: route, sidebarWidth: fullSidebar ? FullSidebar.width : Rail.width, search: $search)
        }
        .overlay(alignment: .topLeading) {
            // Next to the window's buttons, as in Finder.
            Button { withAnimation(.pulliNavigation) { sidebarCollapsed.toggle() } } label: {
                Image(systemName: "sidebar.left").font(.system(size: 14, weight: .medium))
                    .frame(width: 30, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(fullSidebar ? "Hide Sidebar (⌃⌘S)" : "Show Sidebar (⌃⌘S)")
            .accessibilityLabel(fullSidebar ? "Hide Sidebar" : "Show Sidebar")
            .padding(.leading, 84).padding(.top, 9)
        }
        .animation(.pulliNavigation, value: fullSidebar)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .modifier(ToneProvider())
        .frame(minWidth: 1000, minHeight: 660)
        .ignoresSafeArea()
        .sheet(isPresented: Binding(get: { model.showingCableHelp }, set: { model.showingCableHelp = $0 })) { CableHelpSheet() }
#if !PULLI_APP_STORE
        // Opened from the disk image: offer to move to Applications (once the window is up).
        .sheet(isPresented: $offeringMove) { MoveToApplicationsView { offeringMove = false } }
        .onAppear {
            guard !isSnapshot, InstallLocation.shouldOffer else { return }
            // A timer, not a task: the window's first moments rebuild it, which would cancel a task.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { offeringMove = true }
        }
#endif
    }

    private func routeIdentity(_ route: Route) -> String {
        switch route {
        case .starting: "starting"
        case .failed: "failed"
        case .welcome: "welcome"
        case .opening(let device): "opening-\(device.id)"
        case .overview(let device): "overview-\(device.id)"
        case .guide(let device): "guide-\(device.id)"
        case .busy(let device, _): "busy-\(device.id)"
        case .replug(let device): "replug-\(device.id)"
        case .browse(let device, let path): "browse-\(device.id)-\(path)"
        case .storageMap(let device): "map-\(device.id)"
        case .freeUp(let batch): "freeup-\(batch.id)"
        case .copying(let batch): "copying-\(batch.id)"
        case .paused(let batch, let reason): "paused-\(batch.id)-\(reason == .queued)"
        case .done(let batch): "done-\(batch.id)"
        case .noCopies: "nocopies"
        case .history: "history"
        case .attention: "attention"
        }
    }

    @ViewBuilder
    private func screen(_ route: Route) -> some View {
        switch route {
        case .starting: StartingView()
        case .failed(let message): FailedView(message: message)
        case .welcome: WelcomeView()
        case .opening(let device): OpeningView(device: device)
        case .overview(let device): OverviewView(device: device)
        case .guide(let device): GuideView(device: device)
        case .busy(let device, let app): BusyView(device: device, app: app)
        case .replug(let device): ReplugView(device: device)
        case .browse(let device, let path): BrowseView(device: device, path: path, search: search, preloaded: model.previewListings[path])
        case .storageMap(let device): StorageMapView(device: device)
        case .freeUp(let batch): FreeUpView(batch: batch)
        case .copying(let batch): CopyingView(batch: batch)
        case .paused(let batch, let reason): PausedView(batch: batch, reason: reason)
        case .done(let batch): DoneView(batch: batch)
        case .noCopies: NoCopiesView()
        case .history: HistoryView(search: search)
        case .attention: AttentionView()
        }
    }
}

// MARK: - Title bar

private struct TitleBar: View {
    var route: Route
    var sidebarWidth: CGFloat
    @Binding var search: String
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        ZStack {
            // A short note ("myGalaxy connected") takes the title's place for a few seconds:
            // the title bar has room, and nothing on the page is covered.
            if model.connectedNote == nil, let title = route.title {
                Text(title).font(.pulli(13, .semibold)).foregroundStyle(tone.t2)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity)
            }
            HStack(spacing: 8) {
#if !PULLI_APP_STORE
                if case .storageMap(let device) = route {
                    Button { model.closeStorageMap() } label: {
                        Label(device.name, systemImage: "chevron.left").font(.pulli(13, .semibold))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .padding(.leading, sidebarWidth + 24)
                }
#endif
                if case .browse = route, let back = model.backTitle {
                    Button { model.goBack() } label: {
                        Label(back, systemImage: "chevron.left").font(.pulli(13, .semibold))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("[", modifiers: .command)
                    .padding(.leading, sidebarWidth + 24)
                }
                Spacer(minLength: 12)
                if let note = model.connectedNote {
                    // Centred in the free space between the sidebar and the buttons.
                    ConnectedNote(text: note)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    Spacer(minLength: 12)
                }
                trailing
            }
            .padding(.leading, model.connectedNote != nil && !hasLeadingButton ? sidebarWidth : 0)
            .padding(.trailing, 16)
        }
        .frame(height: 52)
    }

    /// A back button sits at the leading edge on these pages.
    private var hasLeadingButton: Bool {
        switch route {
        case .storageMap: true
        case .browse: model.backTitle != nil
        default: false
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch route {
        case .overview:
            Button { model.openInFinder() } label: {
                Label(model.driveStatus == nil ? "Open in Finder" : "Opening…", systemImage: "externaldrive.connected.to.line.below")
            }
            .buttonStyle(PillButtonStyle())
            .help("Show the phone in Finder's sidebar like a drive: browse, open and drag files both ways.")
            .disabled(model.driveStatus != nil)
#if !PULLI_APP_STORE
            Button { model.openStorageMap() } label: { Label("Storage Map", systemImage: "square.grid.3x3.square") }
                .buttonStyle(PillButtonStyle())
#endif
            Button { model.openBrowser(at: "/") } label: { Label("Browse Phone…", systemImage: "folder") }
                .buttonStyle(PillButtonStyle())
#if !PULLI_APP_STORE
        case .storageMap:
            Button { model.rescanStorage() } label: { Label("Scan Again", systemImage: "arrow.clockwise") }
                .buttonStyle(PillButtonStyle())
#endif
        case .browse(_, let path):
            Button { model.openInFinder() } label: { Image(systemName: "externaldrive.connected.to.line.below") }
                .buttonStyle(PillButtonStyle())
                .help("Open the phone in Finder")
            SearchField(text: $search, prompt: "Search \(path == "/" ? "phone" : (path as NSString).lastPathComponent)")
        case .history:
            SearchField(text: $search, prompt: "Search")
        default:
            EmptyView()
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String
    @Environment(\.tone) private var tone
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.t3)
            if isSnapshot {
                // Text fields cannot be drawn offscreen: the prompt stands in.
                Text(prompt).font(.pulli(13)).foregroundStyle(tone.t3).lineLimit(1)
                Spacer(minLength: 0)
            } else {
                TextField(prompt, text: $text)
                    .textFieldStyle(.plain)
                    .font(.pulli(13))
            }
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.pill))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tone.pillBorder))
    }
}

private struct BannerView: View {
    var text: String
    var dismiss: () -> Void
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone.amber)
            Text(text).font(.pulli(13, .medium)).lineLimit(2)
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .panel(radius: 14, tint: tone.amberFill, opaque: true)
        .frame(maxWidth: 560)
    }
}

/// A phone just became ready: a short, quiet confirmation at the top of the window.
private struct ConnectedNote: View {
    var text: String
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tone.green)
            Text(text).font(.pulli(13, .medium)).lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .panel(radius: 14, opaque: true)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Finder cannot show the phone even after a repair: a warning like `BannerView`, with a way to
/// browse the phone in Pulli instead.
private struct FinderTroubleNote: View {
    var name: String
    var onClose: () -> Void
    var onBrowse: () -> Void
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(tone.amber)
            Text("Finder can't show \(name) right now. Browse it here instead.")
                .font(.pulli(13, .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Browse in Pulli", action: onBrowse)
                .buttonStyle(PillButtonStyle(small: true))
            Button("Close", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .panel(radius: 14, tint: tone.amberFill, opaque: true)
        .frame(maxWidth: 600)
    }
}

// MARK: - Sidebar and rail

struct FullSidebar: View {
    static let width: CGFloat = 220
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.tone) private var tone

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            item(.phone, "iphone.gen3", model.device?.name ?? "Phone")
            item(.copies, "arrow.down.to.line", "Copies")
            item(.history, "clock", "History")
            if model.attentionCount > 0 { item(.attention, "exclamationmark.triangle", "Attention") }
            Spacer()
            Button { openSettings() } label: {
                Label { Text("Settings").font(.pulli(14.5, .medium)) } icon: { Image(systemName: "gearshape").font(.system(size: 18)) }
                    .padding(.horizontal, 16).frame(height: 50)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.top, 40).padding(.bottom, 22)
        .frame(width: Self.width)
    }

    private func item(_ section: AppModel.Section, _ symbol: String, _ title: String) -> some View {
        let selected = model.section == section
        return Button {
            model.show(section)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium)).frame(width: 24)
                Text(title).font(.pulli(14, .medium)).lineLimit(1)
                Spacer(minLength: 4)
                badge(section)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
            .modifier(SelectedTile(selected: selected, radius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Copy progress beside Copies, and the waiting dot beside Needs Attention.
    @ViewBuilder
    private func badge(_ section: AppModel.Section) -> some View {
        if section == .copies, let batch = model.activeBatch {
            let color: Color = if case .paused(let reason) = batch.phase, reason != .queued { Color(hex: 0xF5A93A) } else { .accent }
            PieBadge(fraction: batch.fractionDone, color: color)
        } else if section == .attention {
            Text("\(model.attentionCount)").font(.pulli(12, .semibold)).monospacedDigit()
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.pausedAmber.opacity(0.25)))
        }
    }
}

struct Rail: View {
    static let width: CGFloat = 88
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 14) {
            tile(.phone, "iphone.gen3", model.device?.name ?? "Phone")
            tile(.copies, "arrow.down.to.line", "Copies")
            tile(.history, "clock", "History")
            if model.attentionCount > 0 { tile(.attention, "exclamationmark.triangle", "Needs attention") }
            Spacer()
            Button { openSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 20)).frame(width: 54, height: 54).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .opacity(0.85)
        }
        .padding(.top, 40).padding(.bottom, 22)
        .frame(width: Self.width)
    }

    private func tile(_ section: AppModel.Section, _ symbol: String, _ label: String) -> some View {
        let selected = model.section == section
        return Button {
            model.show(section)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .medium))
                .frame(width: 54, height: 54)
                .contentShape(Rectangle())
                .modifier(SelectedTile(selected: selected, radius: 15))
                .overlay(alignment: .topTrailing) { status(section) }
                .opacity(selected ? 1 : 0.85)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func status(_ section: AppModel.Section) -> some View {
        if section == .copies, let batch = model.activeBatch {
            let color: Color = if case .paused(let reason) = batch.phase, reason != .queued { Color(hex: 0xF5A93A) } else { .copyBlue }
            PieBadge(fraction: batch.fractionDone, color: color).offset(x: 5, y: -5).shadow(color: .black.opacity(0.3), radius: 3, y: 2)
        } else if section == .attention {
            GlowDot(color: .pausedAmber, size: 9).offset(x: -2, y: 2)
        }
    }
}

struct SelectedTile: ViewModifier {
    var selected: Bool
    var radius: CGFloat
    func body(content: Content) -> some View {
        if selected { content.panel(radius: radius) } else { content }
    }
}

// MARK: - Simple states

private struct StartingView: View {
    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text("Starting Pulli…").font(.pulli(15, .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedView: View {
    var message: String
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        VStack(spacing: 16) {
            Gem(form: .disc, palette: .amber, symbol: "exclamationmark", size: 120)
            Text("Pulli could not start its copy engine").font(.pulli(26, .semibold))
            Text(message).font(.pulli(14)).foregroundStyle(tone.t2).multilineTextAlignment(.center).frame(maxWidth: 480)
            Button("Try Again") { Task { await model.reconnect() } }.buttonStyle(PillButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
