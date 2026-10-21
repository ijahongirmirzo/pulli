import AppKit
import PulliClient
import PulliProtocol
import SwiftUI
import UniformTypeIdentifiers

/// How the Choose list shows a folder, as Finder's View options: as a list or as icons, sorted by
/// a column either way, folders on top or mixed in.
struct BrowseOptions: Codable, Equatable, Sendable {
    enum Layout: String, Codable, Sendable { case list, icons }
    enum SortKey: String, Codable, CaseIterable, Sendable {
        case name, kind, date, size
        var title: String {
            switch self {
            case .name: "Name"
            case .kind: "Kind"
            case .date: "Date Modified"
            case .size: "Size"
            }
        }
    }

    var layout = Layout.list
    var sort = SortKey.name
    var ascending = true
    var foldersFirst = true
    /// Icon view: the pictures' size in points.
    var iconSize: Double = 96

    static let iconSizes: ClosedRange<Double> = 56...200

    static var saved: BrowseOptions {
        guard let data = UserDefaults.standard.data(forKey: "browseOptions"),
              let options = try? JSONDecoder().decode(BrowseOptions.self, from: data) else { return BrowseOptions() }
        return options
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "browseOptions") }
    }
}

/// Choose: one folder of the phone at a time, streamed page by page, with tick boxes. Ticking a
/// folder copies everything inside it. Shown as a list or as icons (View options, ⌘1 and ⌘2).
struct BrowseView: View {
    var device: DeviceSnapshot
    var path: String
    var search: String
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    /// The folder, sorted by name alone.
    @State private var entries: [FolderEntry] = []
    /// The folder in the order shown (see `reorder`), dot files left out.
    @State private var ordered: [FolderEntry] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var selection: [String: FolderEntry] = [:]
    private let preloaded: [FolderEntry]?

    init(device: DeviceSnapshot, path: String, search: String, preloaded: [FolderEntry]? = nil) {
        self.device = device
        self.path = path
        self.search = search
        self.preloaded = preloaded
        _entries = State(initialValue: Self.sorted(preloaded ?? []))
        _ordered = State(initialValue: Self.order(Self.sorted(preloaded ?? []), BrowseOptions()))
        _loading = State(initialValue: preloaded == nil)
        if let preloaded {
            // Snapshots show a few ticked rows.
            _selection = State(initialValue: Dictionary(uniqueKeysWithValues: preloaded.prefix(4).map { ((path == "/" ? "/" : path + "/") + $0.name, $0) }))
        }
    }

    /// The row last clicked: the start of a Shift-click range, and what Space previews.
    @State private var anchor: Int?
    /// A drag across rows in progress: from where, whether it ticks or unticks, and the ticks
    /// before it began (so dragging back shrinks the range again).
    @State private var paint: (start: Int, tick: Bool, before: [String: FolderEntry], moved: Bool)?
    /// Files in this folder already on the Mac (by content, any name): phone path → Mac path.
    @State private var onMac: [String: String] = [:]
    @State private var dropTargeted = false
    @State private var hoverRow: Int?
    /// The list's width (the icon view fits as many columns as it can).
    @State private var width: CGFloat = 900
    @Environment(\.isSnapshot) private var isSnapshot

    static let rowHeight: CGFloat = 40
    static let gridInset: CGFloat = 14

    private var options: BrowseOptions { model.browseOptions }

    private func layout(count: Int) -> ItemLayout {
        switch options.layout {
        case .list:
            return .list(count: count, rowHeight: Self.rowHeight)
        case .icons:
            let icon = CGFloat(options.iconSize)
            let usable = max(width - Self.gridInset * 2, icon + 44)
            let columns = max(1, Int(usable / (icon + 44)))
            return ItemLayout(style: .grid, count: count, cell: CGSize(width: usable / CGFloat(columns), height: icon + 80),
                              columns: columns, inset: Self.gridInset)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                pathBar
                if !onMac.isEmpty { duplicateBanner }
                if options.layout == .list {
                    header
                } else {
                    Rectangle().fill(tone.separator).frame(height: 1)
                }
                Scrolling {
                    let rows = visible
                    let partly = partlyTicked
                    let layout = layout(count: rows.count)
                    Group {
                        switch options.layout {
                        case .list:
                            LazyVStack(spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.name) { index, entry in
                                    row(entry, partly: partly, focused: index == anchor, hovered: index == hoverRow)
                                }
                            }
                        case .icons:
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.cell.width), spacing: 0), count: layout.columns), spacing: 0) {
                                ForEach(Array(rows.enumerated()), id: \.element.name) { index, entry in
                                    cell(entry, partly: partly, focused: index == anchor, hovered: index == hoverRow)
                                        .frame(width: layout.cell.width, height: layout.cell.height)
                                }
                            }
                            .padding(layout.inset)
                            // Fills the width it is offered and never asks for more: the column
                            // count comes from the measured width, so a grid that set its own
                            // width would keep the list from ever getting narrower again.
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .overlay { if !isSnapshot { mouse(rows, layout: layout) } }
                    if loading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the phone…").font(.pulli(13)) }
                            .foregroundStyle(tone.t2).padding(16)
                    } else if let failure {
                        Text(failure).font(.pulli(13)).foregroundStyle(tone.amber).padding(16)
                    } else if rows.isEmpty {
                        Text(search.isEmpty ? "This folder is empty." : "Nothing matches \u{201C}\(search)\u{201D}.")
                            .font(.pulli(13)).foregroundStyle(tone.t2).padding(20)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
#if !PULLI_APP_STORE
            .overlay { if dropTargeted { dropOverlay } }
            .panel(radius: 22)
            .modifier(DropFiles(enabled: !isSnapshot) { providers in model.receive(providers, into: path) } targeted: { dropTargeted = $0 })
            .animation(.easeOut(duration: 0.2), value: dropTargeted)
#else
            .panel(radius: 22)
#endif
            .padding(.horizontal, 32).padding(.top, 16)
            footer
                .frame(height: 96)
        }
#if !PULLI_APP_STORE
        .overlay(alignment: .bottomTrailing) { uploadCards.padding(.trailing, 40).padding(.bottom, 120) }
#endif
        .overlay(alignment: .bottomTrailing) {
            let empty = selection.isEmpty
            CornerAction {
                Button("Copy") { copySelection() }
                    .buttonStyle(RoundActionButtonStyle())
                    .disabled(empty)
            }
        }
        .overlay(alignment: .top) {
            if let note = model.quickLookLoading.map({ "Opening \($0)…" }) ?? model.dragOutNotice {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(note).font(.pulli(13, .medium))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .panel(radius: 99)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.quickLookLoading ?? model.dragOutNotice)
        .overlay(alignment: .top) {
            if let toast = model.toast, model.quickLookLoading == nil, model.dragOutNotice == nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(tone.green)
                    Text(toast).font(.pulli(13, .medium)).lineLimit(2)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .panel(radius: 99)
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.toast)
        .task(id: "\(path)#\(model.browseReloadToken)") { await load() }
        .onChange(of: path) { anchor = nil }
        .onChange(of: options) { old, new in
            // Only a change of order re-sorts (a new icon size does not).
            guard old.sort != new.sort || old.ascending != new.ascending || old.foldersFirst != new.foldersFirst else { return }
            withAnimation(.easeInOut(duration: 0.25)) { reorder() }
        }
        .background {
            // Keyboard: Esc clears the ticks, Space previews the last clicked file.
            // Return copies selected, ⌘1 and ⌘2 change layouts, and ⌘A selects all via the menu bar.
            Button("") { selection.removeAll() }.keyboardShortcut(.escape, modifiers: []).opacity(0)
            Button("") { previewAnchor() }.keyboardShortcut(.space, modifiers: []).opacity(0)
        }
        .focusedSceneValue(\.browseCommands, browseCommands)
    }

    private var browseCommands: BrowseCommands {
        let selectionBinding = $selection
        let currentVisible = visible
        let currentOnMac = onMac
        let currentFolder = path
        let currentClipboardPaths = clipboardPaths(currentVisible)
        let currentSelectionPaths = Array(selection.keys).sorted()
        let fullPath: @Sendable (String) -> String = { name in currentFolder == "/" ? "/" + name : currentFolder + "/" + name }

        return BrowseCommands(
            hasSelection: !selection.isEmpty,
            copySelected: {
                guard !currentSelectionPaths.isEmpty else { return }
                Task { await model.copy(paths: currentSelectionPaths) }
            },
            canCopy: !currentClipboardPaths.isEmpty,
            copy: {
                if !currentClipboardPaths.isEmpty { model.copyToClipboard(currentClipboardPaths) }
            },
            canPaste: model.clipboardHasSomethingForPhone,
            paste: {
                model.pasteFromClipboard(into: currentFolder)
            },
            canSelectAll: !currentVisible.isEmpty,
            selectAll: {
                for entry in currentVisible where currentOnMac[fullPath(entry.name)] == nil {
                    selectionBinding.wrappedValue[fullPath(entry.name)] = entry
                }
            },
            canDelete: false,
            delete: {},
            layout: options.layout,
            setLayout: { layout in
                guard model.browseOptions.layout != layout else { return }
                withAnimation(.easeInOut(duration: 0.25)) { model.browseOptions.layout = layout }
            },
            sortKey: options.sort,
            setSortKey: { key in
                model.browseOptions.sort = key
                model.browseOptions.ascending = key == .name || key == .kind
            },
            ascending: options.ascending,
            setAscending: { asc in
                model.browseOptions.ascending = asc
            }
        )
    }

    private func copySelection() {
        guard !selection.isEmpty else { return }
        Task { await model.copy(paths: Array(selection.keys).sorted()) }
    }

    private func setLayout(_ layout: BrowseOptions.Layout) {
        guard options.layout != layout else { return }
        withAnimation(.easeInOut(duration: 0.25)) { model.browseOptions.layout = layout }
    }

    // MARK: Mouse: clicks, painting ticks, dragging out, menus (ListMouse)

    private func mouse(_ rows: [FolderEntry], layout: ItemLayout) -> ListMouse {
        let pasteAction: (() -> Void)? = {
#if !PULLI_APP_STORE
            return { model.pasteFromClipboard(into: path) }
#else
            return nil
#endif
        }()
        return ListMouse(layout: layout,
                         isTicked: { rows.indices.contains($0) && selection[full(rows[$0].name)] != nil },
                         click: { row, onTick, flags, count in click(row, rows, onTick: onTick, flags: flags, count: count) },
                         paint: { from, to in paintTicks(rows, from: from, to: to) },
                         paintEnded: { paint = nil },
                         hover: { hoverRow = $0 },
                         dragItems: { dragItems(rows, from: $0, layout: layout) },
                         menu: { menu(rows, row: $0) },
                         copyItems: clipboardPaths(rows).isEmpty ? nil : { model.copyToClipboard(clipboardPaths(rows)) },
                         pasteItems: pasteAction)
    }

    /// A click: only the tick box ticks (⌘-click ticks any row too, folders without opening them;
    /// ⇧-click ticks every row from the last one clicked). Clicking a file's name highlights it
    /// (Space previews it, a double click opens it); clicking a folder opens it.
    private func click(_ position: Int, _ rows: [FolderEntry], onTick: Bool, flags: NSEvent.ModifierFlags, count: Int) {
        guard rows.indices.contains(position) else { return }
        let entry = rows[position]
        let path = full(entry.name)
        if count >= 2 {
            if !entry.isFolder, !onTick { model.openFile(entry, at: path) }
            return
        }
        if flags.contains(.shift), let anchor, rows.indices.contains(anchor) {
            for row in rows[min(anchor, position)...max(anchor, position)] { selection[full(row.name)] = row }
            return
        }
        anchor = position
        if flags.contains(.command) || onTick {
            toggle(entry, at: path, partly: partlyTicked)
        } else if entry.isFolder {
            model.browse(to: path)
        }
    }

    /// Dragging across rows ticks (or unticks, when the first row was ticked) every row crossed.
    private func paintTicks(_ rows: [FolderEntry], from start: Int, to end: Int) {
        guard rows.indices.contains(start), rows.indices.contains(end) else { return }
        if paint == nil { paint = (start, selection[full(rows[start].name)] == nil, selection, true) }
        guard let current = paint else { return }
        var ticks = current.before
        for row in rows[min(start, end)...max(start, end)] {
            if current.tick { ticks[full(row.name)] = row } else { ticks[full(row.name)] = nil }
        }
        selection = ticks
        anchor = end
    }

    /// Dragged out to Finder: every ticked item when the drag starts on a ticked row, else that row.
    private func dragItems(_ rows: [FolderEntry], from position: Int, layout: ItemLayout) -> [NSDraggingItem] {
        guard rows.indices.contains(position) else { return [] }
        let start = full(rows[position].name)
        let chosen: [(String, FolderEntry)] = selection[start] != nil
            ? selection.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            : [(start, rows[position])]
        let items = chosen.map { DragOut.Item(path: $0.0, entry: $0.1) }
        let delivery = DragOut(model: model, items: items)
        model.dragOuts.insert(delivery)
        let frames = chosen.map { path, _ -> NSRect in
            let index = rows.firstIndex { full($0.name) == path } ?? position
            return layout.iconFrame(index)
        }
        let images = chosen.map { path, entry -> NSImage in
            if let thumb = model.thumbnails.cached(deviceID: device.id, path: path, entry: entry) { return thumb }
            return SystemIcons.icon(forName: entry.name, isFolder: entry.isFolder)
        }
        return delivery.draggingItems(frames: frames, images: images)
    }

    /// Right-click: open (or Open With, as in Finder), Quick Look, copy, tick.
    private func menu(_ rows: [FolderEntry], row position: Int) -> NSMenu? {
        guard rows.indices.contains(position) else { return nil }
        let entry = rows[position]
        let path = full(entry.name)
        let menu = NSMenu()
        if entry.isFolder {
            menu.addItem(ClosureMenuItem("Open", symbol: "folder") { model.browse(to: path) })
        } else {
            menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app") { model.openFile(entry, at: path) })
            menu.addItem(openWithItem(entry, path: path))
            menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye") { model.quickLook(entry, at: path) })
        }
        menu.addItem(.separator())
        let targets = selection[path] != nil && selection.count > 1 ? selection.keys.sorted() : [path]
        let what = targets.count > 1 ? "\(targets.count) Items" : "\u{201C}\(entry.name)\u{201D}"
        menu.addItem(ClosureMenuItem("Copy \(what) to \(Format.place(model.destination))", symbol: "arrow.down.to.line") {
            Task { await model.copy(paths: targets) }
        })
        menu.addItem(ClosureMenuItem("Copy \(what) To…", symbol: "folder.badge.plus") { model.copy(targets, chooseFolder: true) })
        let clipboard = ClosureMenuItem(targets.count > 1 ? "Copy \(targets.count) Items" : "Copy", symbol: "doc.on.clipboard") { model.copyToClipboard(targets) }
        clipboard.keyEquivalent = "c"
        clipboard.keyEquivalentModifierMask = .command
        menu.addItem(clipboard)
#if !PULLI_APP_STORE
        if model.clipboardHasSomethingForPhone {
            let paste = ClosureMenuItem("Paste into \(path == "/" ? device.name : (path as NSString).lastPathComponent)", symbol: "doc.on.clipboard.fill") {
                model.pasteFromClipboard(into: path)
            }
            paste.keyEquivalent = "v"
            paste.keyEquivalentModifierMask = .command
            menu.addItem(paste)
        }
#endif
        if let mac = onMac[path] {
            menu.addItem(ClosureMenuItem("Show the Copy on Your Mac", symbol: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: mac)])
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(selection[path] == nil ? "Tick" : "Untick", symbol: "checkmark.square") {
            toggle(entry, at: path, partly: partlyTicked)
        })
        return menu
    }

    /// Finder's Open With: the default app first, the other apps for this kind of file, Other….
    private func openWithItem(_ entry: FolderEntry, path: String) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        let submenu = NSMenu()
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: type)
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: type)
        let ordered = (preferred.map { [$0] } ?? []) + apps.filter { $0 != preferred }
        for (index, app) in ordered.prefix(20).enumerated() {
            let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
            let appItem = ClosureMenuItem(index == 0 && preferred != nil ? "\(name) (default)" : name) {
                model.openFile(entry, at: path, with: app)
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            appItem.image = icon
            submenu.addItem(appItem)
            if index == 0 && preferred != nil && ordered.count > 1 { submenu.addItem(.separator()) }
        }
        if !ordered.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem("Other…") {
            let panel = NSOpenPanel()
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
            panel.prompt = "Open"
            if panel.runModal() == .OK, let app = panel.url { model.openFile(entry, at: path, with: app) }
        })
        item.submenu = submenu
        return item
    }

    /// What ⌘C copies: the ticked items, or else the highlighted one.
    private func clipboardPaths(_ rows: [FolderEntry]) -> [String] {
        if !selection.isEmpty { return selection.keys.sorted() }
        guard let anchor, rows.indices.contains(anchor) else { return [] }
        return [full(rows[anchor].name)]
    }

    private func previewAnchor() {
        let rows = visible
        guard let anchor, rows.indices.contains(anchor), !rows[anchor].isFolder else { return }
        model.quickLook(rows[anchor], at: full(rows[anchor].name))
    }

    /// The order is worked out once per listing or change of sort (`reorder`), so a tick only
    /// filters: re-sorting a big folder with localised comparison on every change was what made
    /// ticking lag.
    private var visible: [FolderEntry] {
        search.isEmpty ? ordered : ordered.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func reorder() {
        ordered = Self.order(entries, options)
    }

    /// `byName` is sorted by name; ties in the other orders keep name order.
    static func order(_ byName: [FolderEntry], _ options: BrowseOptions) -> [FolderEntry] {
        let ranked = byName.filter { !$0.name.hasPrefix(".") }.enumerated().map { (rank: $0.offset, entry: $0.element) }
        let up = options.ascending
        var sorted: [(rank: Int, entry: FolderEntry)]
        switch options.sort {
        case .name:
            sorted = up ? ranked : ranked.reversed()
        case .date:
            sorted = ranked.sorted { a, b in
                a.entry.modifiedWallClock == b.entry.modifiedWallClock ? a.rank < b.rank
                    : (up ? a.entry.modifiedWallClock < b.entry.modifiedWallClock : a.entry.modifiedWallClock > b.entry.modifiedWallClock)
            }
        case .size:
            sorted = ranked.sorted { a, b in
                a.entry.sizeBytes == b.entry.sizeBytes ? a.rank < b.rank : (up ? a.entry.sizeBytes < b.entry.sizeBytes : a.entry.sizeBytes > b.entry.sizeBytes)
            }
        case .kind:
            let kinds = ranked.map { kindName($0.entry) }
            sorted = ranked.sorted { a, b in
                let x = kinds[a.rank], y = kinds[b.rank]
                return x == y ? a.rank < b.rank : (up ? x < y : x > y)
            }
        }
        let shown = sorted.map(\.entry)
        return options.foldersFirst ? shown.filter(\.isFolder) + shown.filter { !$0.isFolder } : shown
    }

    /// Folders with something ticked inside them (shown as a dash), worked out once per update.
    private var partlyTicked: Set<String> {
        var result: Set<String> = []
        for path in selection.keys {
            var parent = (path as NSString).deletingLastPathComponent
            while parent.count > 1, result.insert(parent).inserted {
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        return result
    }

    /// By name as Finder sorts names ("IMG 2" before "IMG 10").
    static func sorted(_ entries: [FolderEntry]) -> [FolderEntry] {
        entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func full(_ name: String) -> String { path == "/" ? "/" + name : path + "/" + name }

    private var pathBar: some View {
        let parts = path.split(separator: "/").map(String.init)
        return HStack(spacing: 7) {
            Image(systemName: "iphone.gen3").font(.system(size: 13, weight: .semibold))
            crumb(device.name, target: nil)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(tone.t3)
            crumb("Internal storage", target: "/", last: parts.isEmpty)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(tone.t3)
                crumb(part, target: "/" + parts[...index].joined(separator: "/"), last: index == parts.count - 1)
            }
            Spacer()
            viewControls
#if !PULLI_APP_STORE
            Button { model.chooseFilesToUpload(to: path) } label: { Label("Add…", systemImage: "square.and.arrow.up") }
                .buttonStyle(PillButtonStyle(small: true))
                .help("Copy files from your Mac into this folder on the phone. You can also drop them here.")
#endif
            Button("Select All") {
                // Files already on the Mac are left out.
                for entry in visible where onMac[full(entry.name)] == nil { selection[full(entry.name)] = entry }
            }
            .buttonStyle(PillButtonStyle(small: true))
            if !selection.isEmpty {
                Button("Clear") { selection.removeAll() }.buttonStyle(PillButtonStyle(small: true))
            }
        }
        .font(.pulli(13.5))
        .foregroundStyle(tone.t2)
        .padding(.horizontal, 18).frame(height: 48)
    }

    private func crumb(_ title: String, target: String?, last: Bool = false) -> some View {
        Button(title) { if let target { model.browse(to: target) } else { model.closeBrowser() } }
            .buttonStyle(.plain)
            .fontWeight(last ? .semibold : .regular)
            .foregroundStyle(last ? tone.t1 : tone.t2)
            .disabled(last)
    }

    /// Finder's View options: list or icons, the icon size, and how to sort.
    private var viewControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                layoutButton(.icons, symbol: "square.grid.2x2", help: "Show as Icons (⌘1)")
                layoutButton(.list, symbol: "list.bullet", help: "Show as List (⌘2)")
            }
            .padding(2)
            .background(Capsule().fill(tone.pill))
            if options.layout == .icons {
                HStack(spacing: 5) {
                    Image(systemName: "photo").font(.system(size: 9, weight: .semibold))
                    Slider(value: Binding(get: { options.iconSize }, set: { model.browseOptions.iconSize = $0 }), in: BrowseOptions.iconSizes)
                        .controlSize(.mini)
                        .frame(width: 80)
                    Image(systemName: "photo").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(tone.t3)
                .help("Icon size")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            sortMenu
        }
        .animation(.easeOut(duration: 0.2), value: options.layout)
    }

    private func layoutButton(_ layout: BrowseOptions.Layout, symbol: String, help: String) -> some View {
        let on = options.layout == layout
        return Button { setLayout(layout) } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 24)
                .background(Capsule().fill(on ? Color.accent.opacity(0.9) : .clear))
                .foregroundStyle(on ? .white : tone.t2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var sortMenu: some View {
        let label = HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down").font(.system(size: 11, weight: .semibold))
            Text(options.sort.title)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(tone.t3)
        }
        .font(.pulli(12.5, .semibold))
        .foregroundStyle(tone.t1)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(tone.pill))
        return Group {
            if isSnapshot {
                label
            } else {
                Menu {
                    Picker("Sort By", selection: Binding(get: { options.sort }, set: { key in
                        model.browseOptions.sort = key
                        model.browseOptions.ascending = key == .name || key == .kind
                    })) {
                        ForEach(BrowseOptions.SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Order", selection: Binding(get: { options.ascending }, set: { model.browseOptions.ascending = $0 })) {
                        Text(options.sort == .date ? "Oldest First" : options.sort == .size ? "Smallest First" : "Ascending (A to Z)").tag(true)
                        Text(options.sort == .date ? "Newest First" : options.sort == .size ? "Largest First" : "Descending (Z to A)").tag(false)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Keep Folders on Top", isOn: Binding(get: { options.foldersFirst }, set: { model.browseOptions.foldersFirst = $0 }))
                } label: {
                    label
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort by")
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            column("Name", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 68)
            column("Date Modified", .date).frame(width: 170, alignment: .leading)
            column("Kind", .kind).frame(width: 90, alignment: .leading)
            column("Size", .size).frame(width: 80, alignment: .trailing)
        }
        .font(.pulli(12, .semibold)).foregroundStyle(tone.t3)
        .padding(.horizontal, 18).frame(height: 30)
        .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1) }
    }

    /// A column title that sorts by it; clicking the current one reverses the order.
    private func column(_ title: String, _ key: BrowseOptions.SortKey) -> some View {
        Button {
            if options.sort == key { model.browseOptions.ascending.toggle() } else {
                model.browseOptions.sort = key
                model.browseOptions.ascending = key == .name || key == .kind
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(options.sort == key ? tone.t1 : tone.t3)
                if options.sort == key {
                    Image(systemName: options.ascending ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title)")
    }

    private func row(_ entry: FolderEntry, partly: Set<String>, focused: Bool, hovered: Bool) -> some View {
        let fullPath = full(entry.name)
        let state: CheckBox.State = selection[fullPath] != nil ? .on : (partly.contains(fullPath) ? .mixed : .off)
        let storage = device.storages.first?.id ?? 0
        return BrowseRow(entry: entry, state: state, kind: entry.isFolder ? "Folder" : kindName(entry), focused: focused, hovering: hovered,
                         onMac: onMac[fullPath] != nil,
                         preview: entry.isFolder ? nil : (device.id, storage, fullPath, entry),
                         toggle: { toggle(entry, at: fullPath, partly: partly) },
                         open: { model.browse(to: fullPath) })
    }

    private func cell(_ entry: FolderEntry, partly: Set<String>, focused: Bool, hovered: Bool) -> some View {
        let fullPath = full(entry.name)
        let state: CheckBox.State = selection[fullPath] != nil ? .on : (partly.contains(fullPath) ? .mixed : .off)
        let storage = device.storages.first?.id ?? 0
        return BrowseCell(entry: entry, state: state, iconSize: CGFloat(options.iconSize),
                          detail: entry.isFolder ? "Folder" : Format.bytes(entry.sizeBytes),
                          focused: focused, hovering: hovered, showTick: hovered || state != .off || !selection.isEmpty,
                          onMac: onMac[fullPath] != nil,
                          preview: entry.isFolder ? nil : (device.id, storage, fullPath, entry),
                          toggle: { toggle(entry, at: fullPath, partly: partly) },
                          open: { model.browse(to: fullPath) })
    }

    private func toggle(_ entry: FolderEntry, at fullPath: String, partly: Set<String>) {
        if selection[fullPath] != nil {
            selection[fullPath] = nil
        } else {
            // Ticking a folder covers what was ticked inside it.
            if partly.contains(fullPath) { selection = selection.filter { !$0.key.hasPrefix(fullPath + "/") } }
            selection[fullPath] = entry
        }
    }

    private func kindName(_ entry: FolderEntry) -> String { Self.kindName(entry) }

    static func kindName(_ entry: FolderEntry) -> String {
        switch KindThumb.kind(forName: entry.name, isFolder: false) {
        case .image: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .folder: "Folder"
        case .document: (entry.name as NSString).pathExtension.uppercased().isEmpty ? "File" : (entry.name as NSString).pathExtension.uppercased()
        }
    }

    private var footer: some View {
        let files = selection.values.filter { !$0.isFolder }
        let folders = selection.values.filter(\.isFolder).count
        let bytes = files.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let times = device.cable?.duration(ofBytes: bytes)
        return HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    if selection.isEmpty {
                        Text("Tick files or folders to copy").font(.pulli(15, .semibold))
                    } else {
                        Text(summary(files: files.count, folders: folders, bytes: bytes, time: folders == 0 ? times?.now : nil))
                            .font(.pulli(15, .semibold))
                    }
                    HStack(spacing: 0) {
                        Text("to \(Format.place(model.destination)) · ").foregroundStyle(tone.t2)
                        Button("Change") { model.chooseDestination() }.buttonStyle(InlineLinkStyle())
                    }
                    .font(.pulli(13))
                }
                .monospacedDigit()
                Spacer()
                if let faster = times?.faster, bytes > 0, (device.cable?.suggestion ?? .none) != .none {
                    HStack(spacing: 10) {
                        Image(systemName: "cable.connector").foregroundStyle(tone.amber)
                        Text("About \(Format.duration(faster)) with a USB 3 cable.").font(.pulli(12.5))
                        Button("Which cable?") { model.showingCableHelp = true }.buttonStyle(InlineLinkStyle()).font(.pulli(12.5, .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tone.amberFill))
                }
        }
        // The Copy button hangs over the bottom-right corner.
        .padding(.leading, 40).padding(.trailing, 190).padding(.bottom, 30)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func summary(files: Int, folders: Int, bytes: UInt64, time: Double?) -> String {
        var parts: [String] = []
        if folders > 0 { parts.append(Format.count(folders, "folder")) }
        if files > 0 { parts.append(Format.count(files, "file")) }
        var text = parts.joined(separator: " and ")
        if files > 0 { text += " · \(Format.bytes(bytes))\(folders > 0 ? " + folders" : "")" }
        if let time { text += " · \(Format.about(time))" }
        return text
    }

    private func load() async {
        guard preloaded == nil else { return }
        entries = []
        ordered = []
        failure = nil
        loading = true
        defer { loading = false }
        guard let stream = await model.list(path) else {
            failure = "The phone is not available."
            return
        }
        var all: [FolderEntry] = []
        for await page in stream {
            if let error = page.error { failure = "Could not read this folder: \(error)" }
            all += page.entries
            // Show the first pages straight away (big folders arrive in several), sorted at the end.
            if entries.count < 400 {
                entries = all
                reorder()
            }
        }
        entries = Self.sorted(all)
        reorder()
        await findDuplicates()
    }

    /// Settings › Skip files already on my Mac: mark files whose content is already there.
    private func findDuplicates() async {
        onMac = [:]
        guard UserDefaults.standard.object(forKey: "skipDuplicates") as? Bool ?? true, let storage = device.storages.first else { return }
        let files = entries.filter { !$0.isFolder && !$0.name.hasPrefix(".") }.map { full($0.name) }
        let matches = await model.findDuplicates(deviceID: device.id, storageID: storage.id, paths: files)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            onMac = Dictionary(matches.map { ($0.path, $0.macPath) }, uniquingKeysWith: { first, _ in first })
            for path in onMac.keys { selection[path] = nil }
        }
    }

    private var duplicateBanner: some View {
        let files = entries.filter { !$0.isFolder }.count
        let bytes = entries.filter { onMac[full($0.name)] != nil }.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        return HStack(spacing: 14) {
            Gem(form: .disc, palette: .green, symbol: "square.on.square", size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(onMac.count.formatted()) of \(files.formatted()) are already on your Mac").font(.pulli(14, .semibold))
                Text("Found by content in Pictures and the destination, even under other names (\(Format.bytes(bytes))). They are left unticked.")
                    .font(.pulli(12.5)).foregroundStyle(tone.t2).lineLimit(2)
            }
            Spacer()
            Button("Show on Mac") {
                NSWorkspace.shared.activateFileViewerSelecting(onMac.values.prefix(50).map { URL(fileURLWithPath: $0) })
            }
            .buttonStyle(PillButtonStyle(small: true))
            Button("Tick Them Anyway") {
                for entry in entries where onMac[full(entry.name)] != nil { selection[full(entry.name)] = entry }
            }
            .buttonStyle(PillButtonStyle(small: true))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(tone.greenFill)
        .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1) }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .foregroundStyle(Color.accent)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.accent.opacity(0.16)))
            .overlay {
                VStack(spacing: 12) {
                    Gem(form: .squircle, palette: .teal, symbol: "square.and.arrow.up", size: 96, tilt: -6)
                    Text("Drop to copy to \(path == "/" ? "the phone" : (path as NSString).lastPathComponent) on \(device.name)").font(.pulli(22, .semibold))
                    Text("Files and folders from your Mac").font(.pulli(13.5)).foregroundStyle(tone.t2)
                }
            }
            .padding(14)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    /// Copies from the Mac to this phone, with their progress.
    private var uploadCards: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(model.uploads.values.filter { $0.deviceID == device.id }.sorted { $0.uploadID.uuidString < $1.uploadID.uuidString }, id: \.uploadID) { upload in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Gem(form: .squircle, palette: upload.error == nil ? .teal : .amber, symbol: upload.done && upload.error == nil ? "checkmark" : "square.and.arrow.up", size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(upload.done ? (upload.error == nil ? "Copied to \(device.name)" : "Copying stopped") : "Copying to \(device.name)").font(.pulli(13.5, .semibold))
                            Text(upload.error ?? "\(upload.current ?? "") → \(upload.destination.split(separator: "/").joined(separator: " › "))")
                                .font(.pulli(12)).foregroundStyle(tone.t2).lineLimit(1)
                        }
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tone.track)
                            Capsule().fill(Color.accent).frame(width: max(7, proxy.size.width * (upload.bytesTotal == 0 ? 0 : Double(upload.bytesDone) / Double(upload.bytesTotal))))
                        }
                    }
                    .frame(height: 7)
                    Text("\(upload.filesDone) of \(upload.filesTotal) · \(Format.bytes(upload.bytesDone)) of \(Format.bytes(upload.bytesTotal))")
                        .font(.pulli(12)).foregroundStyle(tone.t2).monospacedDigit()
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(width: 360)
                .panel(radius: 16)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.uploads.count)
    }
}

/// One row of the Choose list. Clicks and drags are handled once for the whole list (see
/// `selectionGesture`), so rows hold no buttons or gestures: nothing makes a click wait, which
/// is what made the tick boxes lag with a double-click recogniser.
private struct BrowseRow: View {
    var entry: FolderEntry
    var state: CheckBox.State
    var kind: String
    var focused: Bool
    var hovering = false
    var onMac = false
    var preview: (deviceID: String, storageID: UInt32, path: String, entry: FolderEntry)?
    var toggle: () -> Void
    var open: () -> Void
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                CheckBox(state: state)
                FileIcon(name: entry.name, isFolder: entry.isFolder, size: 30, preview: preview)
                Text(entry.name).font(.pulli(13.5, entry.isFolder ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                if onMac {
                    Chip(text: "On your Mac", color: tone.green, fill: tone.greenFill, small: true)
                }
                if entry.isFolder {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(tone.t3)
                        .offset(x: hovering ? 3 : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isFolder ? "—" : Format.phoneDate(entry.modifiedWallClock)).frame(width: 170, alignment: .leading).foregroundStyle(tone.t2)
            Text(kind).frame(width: 90, alignment: .leading).foregroundStyle(tone.t2)
            Text(entry.isFolder ? "" : Format.bytes(entry.sizeBytes)).frame(width: 80, alignment: .trailing).foregroundStyle(tone.t2)
        }
        .font(.pulli(13.5)).monospacedDigit()
        .padding(.horizontal, 18).frame(height: BrowseView.rowHeight)
        .background(focused ? Color.accent.opacity(0.24) : (state == .on ? tone.pill.opacity(0.55) : (hovering ? tone.pill.opacity(0.35) : .clear)))
        .overlay(alignment: .leading) { if focused { Capsule().fill(Color.accent).frame(width: 3, height: 22).padding(.leading, 4) } }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state == .on ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(entry.isFolder ? "Opens the folder. Command-click to tick it." : "Ticks the file for copying.")
        .accessibilityAction { entry.isFolder ? open() : toggle() }
        .accessibilityAction(named: "Tick") { toggle() }
    }
}

/// One item in the icon view: its picture (the phone's preview, or Finder's icon), its name under
/// it, and its size. The tick box shows in the corner on hover and while anything is ticked.
/// Like rows, cells hold no gestures (see `ListMouse`).
private struct BrowseCell: View {
    var entry: FolderEntry
    var state: CheckBox.State
    var iconSize: CGFloat
    var detail: String
    var focused: Bool
    var hovering: Bool
    var showTick: Bool
    var onMac: Bool
    var preview: (deviceID: String, storageID: UInt32, path: String, entry: FolderEntry)?
    var toggle: () -> Void
    var open: () -> Void
    @Environment(\.tone) private var tone

    var body: some View {
        let ticked = state == .on
        VStack(spacing: 4) {
            FileIcon(name: entry.name, isFolder: entry.isFolder, size: iconSize, preview: preview, fit: true)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ticked ? Color.accent.opacity(0.28) : (focused || hovering ? tone.pill.opacity(focused ? 0.9 : 0.5) : .clear)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(ticked ? Color.accent.opacity(0.8) : .clear, lineWidth: 1.5))
                .scaleEffect(hovering ? 1.03 : 1)
            Text(entry.name)
                .font(.pulli(12, entry.isFolder ? .semibold : .medium))
                .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                .foregroundStyle(focused ? .white : tone.t1)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(focused ? Color.accent : .clear))
            HStack(spacing: 4) {
                if onMac { Image(systemName: "checkmark.circle.fill").foregroundStyle(tone.green) }
                Text(onMac ? "On your Mac" : detail)
            }
            .font(.pulli(11)).foregroundStyle(tone.t3).monospacedDigit().lineLimit(1)
        }
        .padding(.top, 8).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .topLeading) {
            if showTick {
                CheckBox(state: state)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tone.dark ? Color.black.opacity(0.35) : Color.white.opacity(0.8)))
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: showTick)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state == .on ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { entry.isFolder ? open() : toggle() }
        .accessibilityAction(named: "Tick") { toggle() }
    }
}

/// Accepts drops from any app: Finder's files, files other apps write when dropped (Telegram,
/// WhatsApp, Photos, browsers), pictures and web links (left out of screen snapshots, which
/// cannot draw it).
private struct DropFiles: ViewModifier {
    var enabled: Bool
    var drop: ([NSItemProvider]) -> Void
    var targeted: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL, .image, .movie, .audio, .pdf, .data, .url], isTargeted: Binding(get: { false }, set: { targeted($0) })) { providers in
                drop(providers)
                return true
            }
        } else {
            content
        }
    }
}
