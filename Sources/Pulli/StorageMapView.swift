import PulliProtocol
import SwiftUI

/// What fills the phone, as tiles sized by bytes (a squarified treemap), filled in live while the
/// phone is scanned. Big folders show what is inside them, so one huge folder is a map of its
/// own contents rather than one flat block; items too small to read are gathered into one
/// "smaller items" tile. Clicking a tile selects it; clicking it again looks inside.
struct StorageMapView: View {
    var device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    /// The folders looked into, from the top.
    @State private var trail: [String] = []
    /// The selected tile, and the folders from the current one down to it.
    @State private var selected: StorageNode?
    @State private var selectedTrail: [String] = []

    var body: some View {
        let scan = model.storageScan
        let node = current(scan?.root)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("What's filling \(device.name)").font(.pulli(26, .medium)).lineLimit(1)
                Spacer(minLength: 12)
                Text(status(scan)).font(.pulli(13)).foregroundStyle(tone.t2).monospacedDigit().lineLimit(1)
            }
            crumbs(scan?.root)
            HStack(alignment: .top, spacing: 18) {
                Group {
                    if let node, node.bytes > 0 {
                        TreemapTiles(node: node, selected: selected?.path) { tile, path in tap(tile, path: path) }
                            .id(node.path)
                            .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
                    } else {
                        VStack(spacing: 14) {
                            ProgressView().controlSize(.large)
                            Text("Looking through \(device.name)…").font(.pulli(15, .medium))
                            Text("Big phones take a minute: Pulli reads every folder.").font(.pulli(13)).foregroundStyle(tone.t2)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                side(node: node)
                    .frame(width: 290)
            }
        }
        .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 32)
    }

    // MARK: Navigation

    private func current(_ root: StorageNode?) -> StorageNode? {
        var node = root
        for path in trail { node = node?.children.first { $0.path == path } ?? node }
        return node
    }

    /// First click selects; clicking the selected tile again looks inside it.
    private func tap(_ tile: StorageNode, path: [String]) {
        if selected?.path == tile.path, !tile.children.isEmpty, !TreemapTiles.isGroup(tile) {
            look(into: path)
        } else {
            withAnimation(.easeOut(duration: 0.2)) {
                selected = tile
                selectedTrail = path
            }
        }
    }

    private func look(into path: [String]) {
        withAnimation(.pulliNavigation) {
            trail += path
            selected = nil
            selectedTrail = []
        }
    }

    /// The selected tile with the latest numbers (the scan keeps updating it).
    private func fresh(_ node: StorageNode?) -> StorageNode? {
        guard let selected else { return nil }
        guard !TreemapTiles.isGroup(selected), var found = node else { return selected }
        for path in selectedTrail {
            guard let next = found.children.first(where: { $0.path == path }) else { return selected }
            found = next
        }
        return found
    }

    private func status(_ scan: StorageScan?) -> String {
        guard let scan else { return "Starting…" }
        if let error = scan.error { return "Stopped: \(error)" }
        let files = "\(scan.root.files.formatted()) files"
        return scan.done ? "\(files) · click a tile, click again to look inside" : "Scanning… \(files) in \(scan.foldersScanned.formatted()) folders"
    }

    private func crumbs(_ root: StorageNode?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3").font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.t2)
            if trail.isEmpty {
                Text("Internal storage").fontWeight(.semibold)
            } else {
                Button("Internal storage") { withAnimation(.pulliNavigation) { trail = []; selected = nil } }.buttonStyle(InlineLinkStyle())
            }
            ForEach(Array(trail.enumerated()), id: \.offset) { index, path in
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(tone.t3)
                let name = StorageStyle.style(path: path, name: (path as NSString).lastPathComponent).name
                if index == trail.count - 1 {
                    Text(name).fontWeight(.semibold)
                } else {
                    Button(name) { withAnimation(.pulliNavigation) { trail = Array(trail.prefix(index + 1)); selected = nil } }.buttonStyle(InlineLinkStyle())
                }
            }
            if let root, let node = current(root), node.bytes > 0 {
                Text("· \(Format.bytes(node.bytes))").foregroundStyle(tone.t2).monospacedDigit()
            }
        }
        .font(.pulli(13))
        .lineLimit(1)
    }

    // MARK: Side panel

    @ViewBuilder
    private func side(node: StorageNode?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tile = fresh(node) {
                selectedCard(tile).transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SELECTED").font(.pulli(12, .bold)).tracking(0.8).foregroundStyle(tone.t3)
                    Text("Click a tile to see what is in it, then copy it to your Mac or look inside.").font(.pulli(13)).foregroundStyle(tone.t2)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panel(radius: 18)
            }
            if let node, !node.children.isEmpty {
                largest(node)
            }
            if let storage = device.storages.first, let capacity = storage.capacityBytes, let free = storage.freeBytes, capacity > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Phone storage").font(.pulli(13.5, .semibold))
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(tone.track)
                            Capsule().fill(LinearGradient(colors: [Color(hex: 0x5AA2FF), Color(hex: 0x63D98A), Color(hex: 0xA58BFF)], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * CGFloat(Double(capacity - free) / Double(capacity)))
                        }
                    }
                    .frame(height: 8)
                    Text("\(Format.bytes(capacity - free)) used · \(Format.bytes(free)) free").font(.pulli(12.5)).foregroundStyle(tone.t2).monospacedDigit()
                }
                .padding(16)
                .panel(radius: 18)
            }
            Spacer(minLength: 0)
        }
    }

    private func selectedCard(_ tile: StorageNode) -> some View {
        let style = TreemapTiles.style(tile)
        let group = TreemapTiles.isGroup(tile)
        let looseFiles = TreemapTiles.isLooseFiles(tile)
        return VStack(alignment: .leading, spacing: 10) {
            Text("SELECTED").font(.pulli(12, .bold)).tracking(0.8).foregroundStyle(tone.t3)
            HStack(spacing: 10) {
                Gem(form: .disc, palette: style.palette, symbol: style.symbol, size: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text(style.name).font(.pulli(16, .bold)).lineLimit(2)
                    Text(looseFiles || group ? "In \(folderName(of: tile))" : tile.path.split(separator: "/").joined(separator: " › "))
                        .font(.pulli(12)).foregroundStyle(tone.t2).lineLimit(2)
                }
            }
            Text(Format.bytes(tile.bytes)).font(.pulli(26, .bold)).monospacedDigit()
            if group {
                // What the "smaller items" tile holds, biggest first; click one to select it.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tile.children.prefix(8)) { child in
                        Button { tap(child, path: selectedTrail.dropLast() + [child.path]) } label: {
                            HStack {
                                Text(StorageStyle.style(path: child.path, name: child.name).name).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(Format.bytes(child.bytes)).foregroundStyle(tone.t2).monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if tile.children.count > 8 {
                        Text("and \(tile.children.count - 8) more").foregroundStyle(tone.t3)
                    }
                }
                .font(.pulli(12.5))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    breakdown("Video", tile.videos)
                    breakdown("Images", tile.images)
                    breakdown("Audio", tile.audio)
                    breakdown("Other", tile.bytes - min(tile.bytes, tile.videos + tile.images + tile.audio))
                    if tile.files > 0 { Text(Format.count(tile.files, "file")).font(.pulli(12.5)).foregroundStyle(tone.t2) }
                }
                .monospacedDigit()
            }
            HStack(spacing: 8) {
                if !looseFiles {
                    Button {
                        let paths = group ? tile.children.map(\.path) : [tile.path]
                        Task { await model.copy(paths: paths) }
                    } label: { Label("Copy to Mac", systemImage: "arrow.down.to.line") }
                        .buttonStyle(PillButtonStyle(kind: .accent, small: true))
                }
                Button("Open") { model.openBrowser(at: looseFiles || group ? parentPath(of: tile) : tile.path) }.buttonStyle(PillButtonStyle(small: true))
                if !tile.children.isEmpty, !group {
                    Button { look(into: selectedTrail) } label: { Label("Look Inside", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(PillButtonStyle(small: true))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 18)
    }

    /// The biggest things in the folder shown, as a ranked list with bars.
    private func largest(_ node: StorageNode) -> some View {
        let top = node.children.filter { $0.bytes > 0 }.sorted { $0.bytes > $1.bytes }.prefix(6)
        let biggest = Double(top.first?.bytes ?? 1)
        return VStack(alignment: .leading, spacing: 9) {
            Text("LARGEST HERE").font(.pulli(12, .bold)).tracking(0.8).foregroundStyle(tone.t3)
            ForEach(Array(top)) { child in
                let style = StorageStyle.style(path: child.path, name: child.name)
                Button { tap(child, path: [child.path]) } label: {
                    HStack(spacing: 9) {
                        Gem(form: .disc, palette: style.palette, symbol: style.symbol, size: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(style.name).font(.pulli(12.5, .semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(Format.bytes(child.bytes)).font(.pulli(12)).foregroundStyle(tone.t2).monospacedDigit()
                            }
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(tone.track)
                                    Capsule().fill(LinearGradient(colors: [style.palette.colors[1], style.palette.colors[2]], startPoint: .leading, endPoint: .trailing))
                                        .frame(width: max(4, proxy.size.width * Double(child.bytes) / biggest))
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(.vertical, 2)
                    .background(selected?.path == child.path ? Color.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(radius: 18)
    }

    private func parentPath(of tile: StorageNode) -> String {
        let path = String(tile.path.prefix { $0 != "·" }.dropLast())
        return path.isEmpty ? "/" : path
    }

    private func folderName(of tile: StorageNode) -> String {
        let path = parentPath(of: tile)
        return path == "/" ? "Internal storage" : StorageStyle.style(path: path, name: (path as NSString).lastPathComponent).name
    }

    private func breakdown(_ label: String, _ bytes: UInt64) -> some View {
        Group {
            if bytes > 0 { Text("\(label) · \(Format.bytes(bytes))").font(.pulli(12.5)).foregroundStyle(tone.t2) }
        }
    }
}

/// The tiles for one folder's children, laid out by `Treemap`. Tiles with room show their own
/// children inside them (one level deep).
private struct TreemapTiles: View {
    var node: StorageNode
    var selected: String?
    /// A tile was clicked: the tile, and the folders from this one down to it.
    var tap: (StorageNode, [String]) -> Void

    static let gap: CGFloat = 3
    /// Tiles smaller than this (in square points) are gathered into one "smaller items" tile.
    static let minArea: CGFloat = 3_600

    var body: some View {
        GeometryReader { proxy in
            let tiles = Self.tiles(node, in: proxy.size)
            let rects = Treemap.layout(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.path) { index, tile in
                    let rect = rects[index].insetBy(dx: Self.gap, dy: Self.gap)
                    if rect.width > 4, rect.height > 4 {
                        Group {
                            if NestedTile.fits(tile, rect.size) {
                                NestedTile(node: tile, size: rect.size, selected: selected) { child in
                                    tap(child, child.path == tile.path ? [tile.path] : [tile.path, child.path])
                                }
                            } else {
                                Tile(node: tile, size: rect.size, selected: selected == tile.path)
                                    .onTapGesture { tap(tile, Self.isGroup(tile) ? [] : [tile.path]) }
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.45), value: tiles.map(\.bytes))
        }
        .padding(-Self.gap)
    }

    /// The children big enough to see, biggest first; the bytes directly in the folder as
    /// "Files here"; and everything too small for its own tile gathered into one.
    static func tiles(_ node: StorageNode, in size: CGSize) -> [StorageNode] {
        var items = node.children.filter { $0.bytes > 0 }
        let rest = node.bytes - min(node.bytes, items.reduce(0) { $0 + $1.bytes })
        if rest > node.bytes / 200 || items.isEmpty {
            items.append(StorageNode(name: items.isEmpty ? node.name : "Files here", path: node.path + "/·files", bytes: rest, files: 0,
                                     images: 0, videos: 0, audio: 0, children: []))
        }
        items.sort { $0.bytes > $1.bytes }
        let total = Double(max(items.reduce(UInt64(0)) { $0 + $1.bytes }, 1))
        let area = Double(size.width * size.height)
        var kept: [StorageNode] = []
        var small: [StorageNode] = []
        for item in items {
            if kept.isEmpty || Double(item.bytes) / total * area >= Double(minArea) { kept.append(item) } else { small.append(item) }
        }
        if small.count == 1 {
            kept += small
        } else if !small.isEmpty {
            let sum = { (key: KeyPath<StorageNode, UInt64>) in small.reduce(UInt64(0)) { $0 + $1[keyPath: key] } }
            kept.append(StorageNode(name: "\(small.count) smaller items", path: node.path + "/·more", bytes: sum(\.bytes),
                                    files: small.reduce(0) { $0 + $1.files }, images: sum(\.images), videos: sum(\.videos), audio: sum(\.audio),
                                    children: small.filter { !isLooseFiles($0) }))
        }
        return kept
    }

    static func isGroup(_ node: StorageNode) -> Bool { node.path.hasSuffix("/·more") }
    static func isLooseFiles(_ node: StorageNode) -> Bool { node.path.hasSuffix("/·files") }

    static func style(_ node: StorageNode) -> StorageStyle.Style {
        if isGroup(node) { return StorageStyle.Style(name: node.name, palette: .slate, symbol: "square.grid.3x3.fill") }
        if isLooseFiles(node) { return StorageStyle.Style(name: node.name, palette: .slate, symbol: "doc.on.doc.fill") }
        return StorageStyle.style(path: node.path, name: node.name)
    }
}

/// A big folder's tile: a title strip, and its own contents as smaller tiles in its colour.
private struct NestedTile: View {
    var node: StorageNode
    var size: CGSize
    var selected: String?
    var tap: (StorageNode) -> Void
    @State private var hovering = false

    static let strip: CGFloat = 34

    static func fits(_ node: StorageNode, _ size: CGSize) -> Bool {
        !node.children.isEmpty && !TreemapTiles.isGroup(node) && size.width >= 150 && size.height >= 130
    }

    var body: some View {
        let style = TreemapTiles.style(node)
        let colors = MapColors.colors(style.palette)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let inner = CGSize(width: size.width - 12, height: size.height - Self.strip - 6)
        let tiles = TreemapTiles.tiles(node, in: inner)
        let rects = Treemap.layout(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: inner))
        ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(colors: [colors[2].mix(with: .black, by: MapColors.deepen.0), colors[2].mix(with: .black, by: MapColors.deepen.1)],
                                      startPoint: .top, endPoint: .bottom))
                .overlay(shape.fill(.white.opacity(hovering ? 0.05 : 0)))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 4)
                .contentShape(shape)
                .onTapGesture { tap(node) }
                .onHover { hovering = $0 }
            HStack(spacing: 7) {
                Image(systemName: style.symbol).font(.system(size: 12, weight: .bold))
                Text(style.name).font(.pulli(14, .bold)).lineLimit(1)
                Spacer(minLength: 6)
                Text(Format.bytes(node.bytes)).font(.pulli(14, .bold)).monospacedDigit()
            }
            .foregroundStyle(MapColors.ink)
            .padding(.horizontal, 12)
            .frame(width: size.width, height: Self.strip)
            .allowsHitTesting(false)
            ForEach(Array(tiles.enumerated()), id: \.element.path) { index, tile in
                let rect = rects[index].insetBy(dx: 2, dy: 2)
                if rect.width > 3, rect.height > 3 {
                    Tile(node: tile, size: rect.size, selected: selected == tile.path, nested: true, shade: index, parentPalette: style.palette)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: 6 + rect.minX, y: Self.strip + rect.minY)
                        .onTapGesture { tap(tile) }
                }
            }
            shape.strokeBorder(.white.opacity(selected == node.path ? 1 : 0.22), lineWidth: selected == node.path ? 3 : 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.name), \(Format.bytes(node.bytes))")
    }
}

private struct Tile: View {
    var node: StorageNode
    var size: CGSize
    var selected: Bool
    /// Inside a big folder's tile: its colour, lighter or darker by position.
    var nested = false
    var shade = 0
    var parentPalette: ArtPalette?
    @State private var hovering = false

    var body: some View {
        let style = TreemapTiles.style(node)
        let colors = MapColors.colors(parentPalette ?? style.palette)
        let radius: CGFloat = nested ? 10 : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let area = size.width * size.height
        let big = area > 40_000
        // Neighbours inside a folder differ in shade, so their edges read at a glance.
        let lift: [Double] = [0.1, 0.26, 0.02, 0.18, 0.32]
        let top = nested ? colors[1].mix(with: .white, by: lift[shade % lift.count]) : colors[1].mix(with: .white, by: 0.12)
        let bottom = nested ? colors[2].mix(with: .white, by: lift[(shade + 2) % lift.count] * 0.6) : colors[2]
        shape
            .fill(LinearGradient(colors: TreemapTiles.isGroup(node) || TreemapTiles.isLooseFiles(node) ? MapColors.neutral : [top, bottom],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.fill(.white.opacity(hovering ? 0.12 : 0)))
            .overlay(shape.strokeBorder(.white.opacity(selected ? 1 : (nested ? 0.18 : 0.25)), lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topLeading) { label(style, big: big) }
            .shadow(color: .black.opacity(nested ? 0 : 0.2), radius: 6, y: 4)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            .contentShape(shape)
            .help("\(style.name) · \(Format.bytes(node.bytes))")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(style.name), \(Format.bytes(node.bytes))")
            .accessibilityAddTraits(.isButton)
    }

    /// As much as fits: symbol, name (one or two lines) and size; a narrow tile shows the
    /// symbol only (its name is in the tooltip and the side panel).
    @ViewBuilder
    private func label(_ style: StorageStyle.Style, big: Bool) -> some View {
        let w = size.width, h = size.height
        if w >= 76, h >= 54 {
            VStack(alignment: .leading, spacing: 2) {
                Image(systemName: style.symbol).font(.system(size: big ? 17 : 12, weight: .bold)).opacity(0.9)
                Text(style.name).font(.pulli(big ? 16 : 12.5, .bold))
                    .lineLimit(h >= 90 ? 2 : 1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Text(Format.bytes(node.bytes)).font(.pulli(big ? 22 : 12.5, big ? .bold : .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .foregroundStyle(MapColors.ink)
            .shadow(color: .black.opacity(AppTheme.current == .porcelain ? 0 : 0.25), radius: 1, y: 1)
            .padding(big ? 14 : 8)
            .frame(width: w, height: h, alignment: .topLeading)
        } else if w >= 26, h >= 26 {
            Image(systemName: style.symbol).font(.system(size: min(min(w, h) * 0.42, 18), weight: .bold))
                .foregroundStyle(MapColors.ink.opacity(0.9))
                .frame(width: w, height: h)
        }
    }
}

/// Names, colours and symbols for well-known phone folders.
enum StorageStyle {
    struct Style {
        var name: String
        var palette: ArtPalette
        var symbol: String
    }

    static func style(path: String, name: String) -> Style {
        let lower = path.lowercased()
        if lower.contains("com.whatsapp") || lower.hasSuffix("/whatsapp") { return Style(name: "WhatsApp", palette: .green, symbol: "bubble.left.and.bubble.right.fill") }
        if lower.contains("telegram") { return Style(name: "Telegram", palette: .sky, symbol: "paperplane.fill") }
        if lower.contains("instagram") { return Style(name: "Instagram", palette: .pink, symbol: "camera.fill") }
        if lower.contains("viber") { return Style(name: "Viber", palette: .violet, symbol: "phone.bubble.fill") }
        switch lower {
        case "/dcim": return Style(name: "DCIM", palette: .blue, symbol: "camera.aperture")
        case "/dcim/camera": return Style(name: "Camera", palette: .blue, symbol: "camera.aperture")
        case "/dcim/screenshots", "/pictures/screenshots": return Style(name: "Screenshots", palette: .violet, symbol: "iphone.gen3")
        case "/android": return Style(name: "Android (apps)", palette: .slate, symbol: "square.stack.3d.up.fill")
        case "/android/data": return Style(name: "App data", palette: .slate, symbol: "square.stack.3d.up.fill")
        case "/android/media": return Style(name: "App media", palette: .teal, symbol: "photo.stack.fill")
        case "/download": return Style(name: "Downloads", palette: .amber, symbol: "arrow.down.circle.fill")
        case "/movies": return Style(name: "Movies", palette: .violet, symbol: "film.fill")
        case "/music": return Style(name: "Music", palette: .pink, symbol: "music.note")
        case "/pictures": return Style(name: "Pictures", palette: .sky, symbol: "photo.fill")
        case "/documents": return Style(name: "Documents", palette: .amber, symbol: "doc.fill")
        case "/recordings", "/voice recorder": return Style(name: name, palette: .pink, symbol: "waveform")
        default:
            let palettes: [ArtPalette] = [.teal, .blue, .violet, .amber, .sky, .pink, .green]
            // A stable hash (hashValue changes every launch): the same folder keeps its colour.
            let index = path.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFF } % palettes.count
            return Style(name: name, palette: palettes[index], symbol: "folder.fill")
        }
    }
}

/// Squarified treemap (Bruls, Huizing, van Wijk): rectangles as close to square as possible,
/// with areas proportional to the values.
enum Treemap {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        let total = values.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
        let area = Double(rect.width * rect.height)
        let scaled = values.map { $0 / total * area }
        var rects = [CGRect](repeating: .zero, count: values.count)
        var remaining = rect
        var start = 0
        while start < scaled.count {
            let side = Double(min(remaining.width, remaining.height))
            var end = start + 1
            var best = worst(scaled[start..<end], side)
            while end < scaled.count {
                let candidate = worst(scaled[start...end], side)
                if candidate > best { break }
                best = candidate
                end += 1
            }
            let rowArea = scaled[start..<end].reduce(0, +)
            if remaining.width >= remaining.height {
                let width = CGFloat(rowArea / Double(remaining.height))
                var y = remaining.minY
                for index in start..<end {
                    let height = CGFloat(scaled[index]) / width
                    rects[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                let height = CGFloat(rowArea / Double(remaining.width))
                var x = remaining.minX
                for index in start..<end {
                    let width = CGFloat(scaled[index]) / height
                    rects[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(remaining.height - height, 0))
            }
            start = end
        }
        return rects
    }

    private static func worst(_ row: ArraySlice<Double>, _ side: Double) -> Double {
        let sum = row.reduce(0, +)
        guard sum > 0, side > 0, let largest = row.max(), let smallest = row.min(), smallest > 0 else { return .infinity }
        return max(side * side * largest / (sum * sum), (sum * sum) / (side * side * smallest))
    }
}

/// The map's colours. Colour tells folders apart here, so Porcelain (white art elsewhere) uses
/// soft tints of each folder's own colour, with ink labels; other themes use the art colours.
enum MapColors {
    static func colors(_ palette: ArtPalette) -> [Color] {
        guard AppTheme.current == .porcelain else { return palette.colors }
        let o = palette.original
        let paper = Color(hex: 0xFBFAF8)
        return [paper.mix(with: o[0], by: 0.30), paper.mix(with: o[1], by: 0.34), paper.mix(with: o[2], by: 0.30)]
    }

    /// "Smaller items" and loose files: no folder colour of their own.
    static var neutral: [Color] {
        AppTheme.current == .porcelain ? [Color(hex: 0xEDEBE6), Color(hex: 0xD9D6CF)] : [Color(hex: 0x8FA0AE), Color(hex: 0x4A5864)]
    }

    static var ink: Color { AppTheme.current == .porcelain ? Color(hex: AppTheme.current.ink) : .white }

    /// How much darker a big folder's own tile is than the folders inside it (top, bottom).
    static var deepen: (Double, Double) { AppTheme.current == .porcelain ? (0.06, 0.14) : (0.2, 0.5) }
}
