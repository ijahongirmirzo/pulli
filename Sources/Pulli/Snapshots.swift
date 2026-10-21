import AppKit
import PulliClient
import PulliProtocol
import PulliWidgetViews
import SceneKit
import SwiftUI
import WidgetKit

/// `Pulli --snapshot DIR`: renders every screen, in dark and light, from fixed sample data to PNG
/// files. Used to check the app against the design canvas without a screen.
@MainActor
enum Snapshots {
    static func render(to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scenarios: [(String, (AppModel) -> Void)] = [
            ("welcome", { $0.state.devices = [:]; $0.selectedDeviceID = nil }),
            ("overview", { _ in }),
            ("overview-update", { _ in Updates.shared.available = "0.4.2" }),
            ("overview-connected-note", { $0.connectedNote = "myGalaxy connected · ready to copy" }),
            ("browse-connected-note", { $0.browsePath = "/DCIM/Camera"; $0.connectedNote = "myGalaxy connected · ready to copy" }),
            ("overview-banner", { $0.banner = "Could not open myGalaxy in Finder: the phone was disconnected." }),
            ("guide", { $0.state.devices[phone.id]?.state = .notInFileTransferMode }),
            ("guide-locked", { $0.state.devices[phone.id]?.state = .locked }),
            ("busy", { $0.state.devices[phone.id]?.state = .heldBy(appName: "Photos") }),
            ("browse", { $0.browsePath = "/DCIM/Camera" }),
            ("copying", { $0.section = .copies; $0.focusedBatchID = 12 }),
            ("copying-chunk", { $0.section = .copies; $0.focusedBatchID = 12
                $0.state.devices[phone.id]?.chunkSuggestion = ChunkSuggestion(deviceID: phone.id, currentMiB: 8, suggestedMiB: 2, failures: 3) }),
            ("paused", { $0.section = .copies; $0.focusedBatchID = 11 }),
            ("done", { $0.section = .copies; $0.focusedBatchID = 10 }),
            ("history", { $0.section = .history }),
            ("attention", { $0.section = .attention }),
            ("apps", { $0.summaries[phone.id]?.apps = appMedia }),
            // Right after Allow a phone can list nothing yet: the Browse card must show only once.
            ("overview-empty", { $0.summaries[phone.id] = PhoneSummary(storageID: 0x10001, camera: nil, screenshots: nil, downloads: nil, cameraMark: nil) }),
            ("overview-camera-only", { $0.summaries[phone.id] = PhoneSummary(storageID: 0x10001, camera: summary.camera, screenshots: nil, downloads: nil, cameraMark: nil) }),
            ("storagemap", { $0.storageScan = storageScan; $0.storageScanID = storageScan.scanID; $0.showingStorageMap = true }),
            ("storagemap-skewed", { $0.storageScan = skewedScan; $0.storageScanID = skewedScan.scanID; $0.showingStorageMap = true }),
            ("browse-icons", { $0.browsePath = "/DCIM/Camera"; $0.browseOptions.layout = .icons }),
            ("freeup-check", { $0.section = .copies; $0.focusedBatchID = 10
                $0.freeUp = FreeUpState(batchID: 10, verifyID: UUID(), progress: verify(done: false), stage: .checking) }),
            ("freeup-confirm", { $0.section = .copies; $0.focusedBatchID = 10
                $0.freeUp = FreeUpState(batchID: 10, verifyID: UUID(), progress: verify(done: true), stage: .confirm) }),
            ("freeup-done", { $0.section = .copies; $0.focusedBatchID = 10
                $0.freeUp = FreeUpState(batchID: 10, verifyID: UUID(), progress: verify(done: true),
                                        stage: .done(DeleteSummary(deleted: 72, bytesFreed: 1_790_000_000, kept: []))) }),
        ] + appStoreScenarios
        for dark in [true, false] {
            for (name, configure) in scenarios {
                let model = AppModel(preview: state, summaries: [phone.id: summary])
                model.previewListings = ["/DCIM/Camera": cameraFiles]
                configure(model)
                write(MainWindow().environment(model), size: CGSize(width: 1120, height: 720), dark: dark, to: folder, name: name)
                Updates.shared.available = nil
            }
            let model = AppModel(preview: state, summaries: [phone.id: summary])
            write(IntroView(still: true, finish: {}).environment(model), size: CGSize(width: 1120, height: 720), dark: dark, to: folder, name: "intro")
            write(MenuBarView().environment(model).modifier(ToneProvider()), size: CGSize(width: 356, height: 560), dark: dark, to: folder, name: "menubar")
            Updates.shared.available = "0.4.2"
            write(MenuBarView().environment(model).modifier(ToneProvider()), size: CGSize(width: 356, height: 560), dark: dark, to: folder, name: "menubar-update")
            Updates.shared.available = nil
            for (index, scene) in [SettingsScene.sidebar, .general, .loginItems, .extensions, .providers(on: false), .providers(on: true)].enumerated() {
                write(FinderLocationApprovalSheet(still: scene).modifier(ToneProvider()), size: CGSize(width: 760, height: 420), dark: dark, to: folder,
                      name: "finder-approval-\(index + 1)")
            }
            write(GemSheet().environment(model), size: CGSize(width: 900, height: 620), dark: dark, to: folder, name: "gems")
            write(GuideScreens().environment(model), size: CGSize(width: 1100, height: 420), dark: dark, to: folder, name: "guide-screens")
            write(MoveToApplicationsView {}.background(SceneBackground(kind: .home, animated: false)).environment(model),
                  size: CGSize(width: 440, height: 400), dark: dark, to: folder, name: "move-to-applications")
            // Close-ups: a big gem, and a 40-point list icon blown up to show its real pixels.
            write(HStack(spacing: 20) {
                Gem(form: .hexagon, palette: .violet, symbol: "iphone.gen3", size: 360)
                Gem(form: .squircle, palette: .slate, symbol: "iphone.gen3", size: 40).scaleEffect(4).frame(width: 260, height: 260)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(hex: 0x2A2358)).environment(model),
                  size: CGSize(width: 900, height: 560), dark: dark, to: folder, name: "gems-zoom")
            write(AppIconArt().frame(width: 1024, height: 1024).scaleEffect(0.5).frame(width: 512, height: 512), size: CGSize(width: 512, height: 512), dark: dark, to: folder, name: "icon")
        }
        print("wrote snapshots to \(folder.path)")
    }

    /// Screens only the App Store edition has.
    private static var appStoreScenarios: [(String, (AppModel) -> Void)] {
#if PULLI_APP_STORE
        [("guide-holder", { $0.state.devices[phone.id]?.state = .notInFileTransferMode; $0.previewHolder = "com.google.drivefs" })]
#else
        []
#endif
    }

    /// `Pulli --readme-frames DIR`: the frames of the README's animation, dark and light, from the
    /// sample phone. One copy of its Camera folder from start to finish (waiting, ready, copying,
    /// unplugged, copying again, done); every frame shows the same batch, so its numbers carry on
    /// from one scene to the next. Frames only: another tool puts them together.
    static func renderReadmeFrames(to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = cameraFiles
        let totalBytes = files.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        let speed = 31_400_000.0
        // How long the phone stays unplugged; the finished screen's time and average include it.
        let unplugged: TimeInterval = 8
        let now = Date()

        /// The Camera copy with `fraction` of its bytes on the Mac, files finished in order.
        func batch(_ fraction: Double, _ phase: BatchPhase, resumed: Bool = false) -> BatchSnapshot {
            let bytesDone = UInt64((Double(totalBytes) * fraction).rounded())
            var finished = 0
            var finishedBytes: UInt64 = 0
            while finished < files.count, finishedBytes + files[finished].sizeBytes <= bytesDone {
                finishedBytes += files[finished].sizeBytes
                finished += 1
            }
            let recent = (0..<finished).reversed().prefix(BatchSnapshot.recentLimit).map {
                FileSnapshot(jobID: Int64($0), name: files[$0].name, sizeBytes: files[$0].sizeBytes, bytesDone: files[$0].sizeBytes, state: .done)
            }
            let current = finished < files.count
                ? FileSnapshot(jobID: Int64(finished), name: files[finished].name, sizeBytes: files[finished].sizeBytes,
                               bytesDone: bytesDone - finishedBytes, state: .copying)
                : nil
            let copying = phase == .copying
            let remaining = Double(totalBytes - bytesDone)
            let elapsed = Double(bytesDone) / speed + (resumed ? unplugged : 0)
            return BatchSnapshot(id: 13, deviceID: phone.id, deviceName: "myGalaxy", title: "Camera",
                                 destinationPath: NSHomeDirectory() + "/Downloads/myGalaxy", phase: phase,
                                 filesTotal: files.count, filesDone: finished, filesSkipped: 0, filesNeedingAttention: 0,
                                 bytesTotal: totalBytes, bytesDone: bytesDone, bytesPerSecond: copying ? speed : 0,
                                 // No "1 s left" on the last frame, when nothing is left.
                                 secondsRemaining: copying && remaining > 0 ? remaining / speed : nil,
                                 current: phase == .completed ? nil : current, recent: recent,
                                 createdAt: now.addingTimeInterval(-elapsed), finishedAt: phase == .completed ? now : nil)
        }

        /// The sample state with only this copy and one older, finished one (nothing else running
        /// or needing attention to catch the eye).
        func model(_ batch: BatchSnapshot?, connected: Bool = true) -> AppModel {
            var story = state
            story.batches = story.batches.filter { $0.key == 9 }
            if let batch { story.batches[batch.id] = batch }
            if !connected { story.devices = [:] }
            let model = AppModel(preview: story, summaries: [phone.id: summary])
            model.previewListings = ["/DCIM/Camera": cameraFiles]
            model.picks = [.camera]
            if let batch { model.section = .copies; model.focusedBatchID = batch.id }
            return model
        }

        var frames: [(String, AppModel)] = [("01-waiting", model(nil, connected: false)), ("02-ready", model(nil))]
        for index in 0..<30 {
            frames.append((String(format: "03-copying-%03d", index), model(batch(0.62 * Double(index) / 29, .copying))))
        }
        frames.append(("04-unplugged", model(batch(0.62, .paused(.phoneDisconnected)), connected: false)))
        for index in 0..<20 {
            frames.append((String(format: "05-resuming-%03d", index), model(batch(0.62 + 0.38 * Double(index) / 19, .copying, resumed: true))))
        }
        frames.append(("06-done", model(batch(1, .completed, resumed: true))))

        for dark in [true, false] {
            for (name, model) in frames {
                write(MainWindow().environment(model), size: CGSize(width: 1120, height: 720), dark: dark, to: folder, name: name)
            }
        }
        print("wrote README frames to \(folder.path)")
    }

    /// `Pulli --themes DIR`: the phone screen in every theme, dark and light, one file each, and a
    /// board with all of them side by side (themes.png) to choose from.
    static func renderThemes(to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var shots: [(AppTheme, NSImage, NSImage)] = []
        for theme in AppTheme.allCases {
            AppTheme.current = theme
            func shot(dark: Bool) -> NSImage {
                let model = AppModel(preview: state, summaries: [phone.id: summary])
                model.summaries[phone.id]?.apps = appMedia
                let content = MainWindow().environment(model)
                    .frame(width: 1120, height: 720)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.isSnapshot, true)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.cgImage else { return NSImage() }
                let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                try? data?.write(to: folder.appendingPathComponent("theme-\(theme.rawValue)\(dark ? "-dark" : "-light").png"))
                return NSImage(cgImage: image, size: NSSize(width: 1120, height: 720))
            }
            shots.append((theme, shot(dark: true), shot(dark: false)))
        }
        AppTheme.current = AppTheme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .porcelain
        let board = VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 24) {
                Text("Dark").frame(width: 672, alignment: .leading)
                Text("Light").frame(width: 672, alignment: .leading)
            }
            .font(.pulli(20, .semibold)).foregroundStyle(.white.opacity(0.7)).padding(.leading, 4)
            ForEach(Array(shots.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 10) {
                    Text(entry.0 == .classic ? "Classic (now)" : entry.0.title).font(.pulli(30, .bold)).foregroundStyle(.white)
                    HStack(spacing: 24) {
                        ForEach([entry.1, entry.2], id: \.self) { image in
                            Image(nsImage: image).resizable().interpolation(.high)
                                .frame(width: 672, height: 432)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15)))
                        }
                    }
                }
            }
        }
        .padding(40)
        .background(Color(hex: 0x0C0C0E))
        let renderer = ImageRenderer(content: board)
        renderer.scale = 2
        if let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? data.write(to: folder.appendingPathComponent("themes.png"))
        }
        print("wrote \(folder.path)/themes.png")
    }

    /// `Pulli --widget-snapshots DIR`: renders the desktop widget views for all three states (connected,
    /// copying, and no phone) in small and medium, light and dark, to PNG files.
    static func renderWidgetSnapshots(to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()

        let connected = WidgetSnapshot(
            updated: Date(),
            phone: "myGalaxy",
            hint: "USB 2 · 3× faster with USB 3",
            copies: [],
            photos: 166,
            newPhotos: 9,
            lastCopy: WidgetSnapshot.LastCopy(title: "Camera", date: yesterday, files: 166)
        )

        let copying = WidgetSnapshot(
            updated: Date(),
            phone: "myGalaxy",
            hint: nil,
            copies: [
                WidgetSnapshot.Copy(
                    id: 1,
                    device: "myGalaxy",
                    title: "Camera",
                    fraction: 0.62,
                    detail: "23 s left",
                    tint: .copying,
                    bytesDone: 3_400_000_000,
                    bytesTotal: 5_600_000_000
                ),
                WidgetSnapshot.Copy(
                    id: 2,
                    device: "myGalaxy",
                    title: "Downloads",
                    fraction: 0.15,
                    detail: "paused",
                    tint: .paused,
                    bytesDone: 150_000_000,
                    bytesTotal: 1_000_000_000
                ),
            ],
            photos: 166,
            newPhotos: 9,
            lastCopy: nil
        )

        let noPhone = WidgetSnapshot(
            updated: Date(),
            phone: nil,
            hint: nil,
            copies: [],
            photos: nil,
            newPhotos: nil,
            lastCopy: WidgetSnapshot.LastCopy(title: "Camera", date: yesterday, files: 166)
        )

        let scenarios: [(String, WidgetSnapshot)] = [
            ("connected", connected),
            ("copying", copying),
            ("nophone", noPhone),
        ]

        let sizes: [(String, WidgetFamily, CGSize)] = [
            ("small", .systemSmall, CGSize(width: 170, height: 170)),
            ("medium", .systemMedium, CGSize(width: 364, height: 170)),
        ]

        for dark in [true, false] {
            let mode = dark ? "dark" : "light"
            for (stateName, snapshot) in scenarios {
                for (sizeName, family, size) in sizes {
                    let view = WidgetBody(snapshot: snapshot, family: family)
                        .frame(width: size.width, height: size.height)
                        .background(WidgetTheme.surface(dark: dark))
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08), lineWidth: 1)
                        )
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .environment(\.isSnapshot, true)

                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else {
                        print("could not render widget \(sizeName) \(stateName) \(mode)")
                        continue
                    }

                    let filename = "widget-\(sizeName)-\(stateName)-\(mode).png"
                    try? data.write(to: folder.appendingPathComponent(filename))
                    if dark {
                        let altName = "widget-\(sizeName)-\(stateName).png"
                        try? data.write(to: folder.appendingPathComponent(altName))
                    }
                }
            }
        }
        print("wrote widget snapshots to \(folder.path)")
    }

    /// `Pulli --art-poses DIR`: the 3D phone (plugged and unplugged) and a big gem turned to the
    /// pointer's extremes, each on grey with the edge of its view drawn in red and its layout
    /// frame in blue: anything touching the red line is cut off on screen.
    static func renderArtPoses(to folder: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        let pointers = [-1.0, 0, 1].flatMap { y in [-1.0, 0, 1].map { x in CGPoint(x: x, y: y) } }
        func board(_ name: String, layout: CGSize, overscan: CGFloat, scene: @escaping () -> SCNScene, pose: @escaping (CGPoint) -> SIMD3<Float>) {
            let cell = CGSize(width: layout.width * overscan, height: layout.height * overscan)
            let image = NSImage(size: CGSize(width: cell.width * 3, height: cell.height * 3), flipped: true) { _ in
                for (index, pointer) in pointers.enumerated() {
                    let origin = CGPoint(x: CGFloat(index % 3) * cell.width, y: CGFloat(index / 3) * cell.height)
                    let built = scene()
                    let p = pose(pointer)
                    built.rootNode.childNode(withName: "subject", recursively: true)?.eulerAngles = SCNVector3(CGFloat(p.x), CGFloat(p.y), CGFloat(p.z))
                    renderer.scene = built
                    renderer.pointOfView = built.rootNode.childNode(withName: "camera", recursively: false)
                    let shot = renderer.snapshot(atTime: 0, with: CGSize(width: cell.width * 2, height: cell.height * 2), antialiasingMode: .multisampling4X)
                    let rect = CGRect(origin: origin, size: cell)
                    NSColor(white: 0.9, alpha: 1).setFill(); rect.fill()
                    shot.draw(in: rect)
                    NSColor.red.setStroke(); NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                    let inner = CGRect(x: rect.midX - layout.width / 2, y: rect.midY - layout.height / 2, width: layout.width, height: layout.height)
                    NSColor.systemBlue.withAlphaComponent(0.5).setStroke(); NSBezierPath(rect: inner).stroke()
                }
                return true
            }
            if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: folder.appendingPathComponent("\(name).png"))
            }
        }
        let width = Double(ProcessInfo.processInfo.environment["PULLI_POSE_WIDTH"] ?? "") ?? 250
        for cable in [PhoneArt.Cable.plugged, .unplugged] {
            let key = PhoneModel.Key(palette: .teal, cable: cable)
            let screen = PhoneModel.screenImage(palette: .teal, screen: .photos, reveal: 1)
            board("phone-\(cable)", layout: CGSize(width: width, height: width * 340 / 320), overscan: PhoneArt.overscan,
                  scene: { let built = PhoneModel.scene(key); PhoneModel.show(screen, in: built); return built },
                  pose: { PhoneModel.pose(pointer: $0) })
        }
        let gem = GemModel.Key(form: .disc, palette: .green, symbol: "checkmark", face: true)
        board("gem-disc", layout: CGSize(width: 300 * width / 250, height: 300 * width / 250), overscan: Gem.overscan,
              scene: { GemModel.scene(gem, drifting: false) }, pose: { GemModel.pose(pointer: $0, tilt: 0) })
        let squircle = GemModel.Key(form: .squircle, palette: .sky, symbol: "arrow.down.to.line", face: false)
        board("gem-squircle", layout: CGSize(width: 150 * width / 250, height: 150 * width / 250), overscan: Gem.overscan,
              scene: { GemModel.scene(squircle, drifting: false) }, pose: { GemModel.pose(pointer: $0, tilt: 8) })
        print("wrote \(folder.path)")
    }

    /// The app icon at 1024 × 1024 (scripts/make-app.sh turns it into AppIcon.icns).
    static func renderIcon(to url: URL) {
        _ = NSApplication.shared
        // The icon is Porcelain whatever look is chosen in Settings.
        AppTheme.current = .porcelain
        let renderer = ImageRenderer(content: AppIconArt().frame(width: 1024, height: 1024))
        renderer.scale = 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func write(_ view: some View, size: CGSize, dark: Bool, to folder: URL, name: String) {
        let content = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.isSnapshot, true)
        let renderer = ImageRenderer(content: content)
        // PULLI_SNAPSHOT_SCALE=2 renders Retina images (the README's screenshots).
        renderer.scale = Double(ProcessInfo.processInfo.environment["PULLI_SNAPSHOT_SCALE"] ?? "") ?? 1
        guard let image = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("could not render \(name)")
            return
        }
        try? data.write(to: folder.appendingPathComponent("\(name)\(dark ? "" : "-light").png"))
    }

    // MARK: Sample data (the Galaxy Z Fold7 from the device tests)

    static let phone = DeviceSnapshot(
        id: "04e8:R5CX00DEMO1", name: "myGalaxy", model: "Galaxy Z Fold7", manufacturer: "Samsung", link: .usb2,
        linkBitsPerSecond: 480_000_000, state: .ready,
        storages: [StorageSnapshot(id: 0x10001, name: "Internal storage", capacityBytes: 234_900_000_000, freeBytes: 42_600_000_000)],
        resumable: true,
        cable: CableAdvice(link: .usb2, phoneSupports: .usb3, throughHub: false, suggestion: .useUSB3Cable,
                           bytesPerSecond: 30_000_000, fasterBytesPerSecond: 90_000_000, measured: true))

    static let cameraFiles: [FolderEntry] = (0..<74).map { index in
        let video = index % 9 == 4
        let day = 1 + index / 3
        return FolderEntry(name: String(format: "202609%02d_%02d%02d%02d.%@", day, 9 + index % 3, index % 60, index % 50, video ? "mp4" : "jpg"),
                           isFolder: false, sizeBytes: video ? UInt64(120_000_000 + index * 1_000_000) : UInt64(3_900_000 + index * 11_000),
                           modifiedWallClock: 1_788_000_000 + Int64(index * 36_000))
    }

    static let summary = PhoneSummary(
        storageID: 0x10001,
        camera: PhoneSummary.Folder(path: "/DCIM/Camera", files: cameraFiles, folderCount: 0),
        screenshots: PhoneSummary.Folder(path: "/DCIM/Screenshots", files: (0..<212).map {
            FolderEntry(name: "Screenshot_\($0).png", isFolder: false, sizeBytes: 1_000_000, modifiedWallClock: 1_788_000_000)
        }, folderCount: 0),
        downloads: PhoneSummary.Folder(path: "/Download", files: (0..<38).map {
            FolderEntry(name: "file\($0).pdf", isFolder: false, sizeBytes: 6_300_000, modifiedWallClock: 1_788_000_000)
        }, folderCount: 5),
        cameraMark: 1_788_000_000 + 40 * 36_000)

    static let appMedia = [
        AppMedia(pick: .whatsapp, name: "WhatsApp media", path: "/Android/media/com.whatsapp/WhatsApp/Media", files: 3_412, bytes: 18_200_000_000),
        AppMedia(pick: .telegram, name: "Telegram", path: "/Android/media/org.telegram.messenger/Telegram", files: 860, bytes: 6_100_000_000),
        AppMedia(pick: .instagram, name: "Instagram", path: "/Pictures/Instagram", files: 214, bytes: 1_300_000_000),
    ]

    static var storageScan: StorageScan {
        func node(_ name: String, _ path: String, _ gb: Double, video: Double = 0, image: Double = 0, children: [StorageNode] = []) -> StorageNode {
            StorageNode(name: name, path: path, bytes: UInt64(gb * 1e9), files: Int(gb * 120), images: UInt64(image * 1e9), videos: UInt64(video * 1e9), audio: 0, children: children)
        }
        let whatsapp = node("com.whatsapp", "/Android/media/com.whatsapp", 18.2, video: 12.1, image: 4.6)
        let children = [
            node("DCIM", "/DCIM", 44.6, video: 30, image: 14, children: [node("Camera", "/DCIM/Camera", 42.8, video: 30, image: 12.8)]),
            node("Android", "/Android", 27.3, video: 12.1, image: 4.6, children: [node("media", "/Android/media", 18.2, children: [whatsapp]), node("data", "/Android/data", 9.1)]),
            node("Movies", "/Movies", 12.4, video: 12.4), node("Telegram", "/Telegram", 6.1, video: 3, image: 2),
            node("Music", "/Music", 3.4), node("Download", "/Download", 1.8), node("Documents", "/Documents", 0.9),
        ]
        let root = StorageNode(name: "Internal storage", path: "/", bytes: UInt64(98.7e9), files: 48_210, images: UInt64(21e9), videos: UInt64(58e9), audio: UInt64(3e9), children: children)
        return StorageScan(scanID: UUID(), root: root, foldersScanned: 3_120, done: true, error: nil)
    }

    /// One folder much bigger than everything else (a drone's footage), as on the test phone.
    static var skewedScan: StorageScan {
        func node(_ name: String, _ path: String, _ gb: Double, video: Double = 0, children: [StorageNode] = []) -> StorageNode {
            StorageNode(name: name, path: path, bytes: UInt64(gb * 1e9), files: Int(gb * 40), images: 0, videos: UInt64(video * 1e9), audio: 0, children: children)
        }
        let dji = node("dji nano private don't touch", "/dji nano private don't touch", 75.67, video: 74, children: [
            node("2025-08 Alps", "/dji nano private don't touch/2025-08 Alps", 31.2, video: 31),
            node("2025-06 Coast", "/dji nano private don't touch/2025-06 Coast", 18.4, video: 18),
            node("2026-01 City", "/dji nano private don't touch/2026-01 City", 12.9, video: 12.9),
            node("Raw", "/dji nano private don't touch/Raw", 8.1),
            node("Edits", "/dji nano private don't touch/Edits", 3.6, video: 3),
            node("Panoramas", "/dji nano private don't touch/Panoramas", 0.9),
            node("Logs", "/dji nano private don't touch/Logs", 0.2),
        ])
        var children = [dji,
                        node("Recordings", "/Recordings", 4.1), node("DCIM", "/DCIM", 3.9, video: 2, children: [node("Camera", "/DCIM/Camera", 3.7)]),
                        node("Android", "/Android", 2.6, children: [node("media", "/Android/media", 1.9), node("data", "/Android/data", 0.7)]),
                        node("Download", "/Download", 1.2), node("Pictures", "/Pictures", 0.4), node("Music", "/Music", 0.2)]
        for index in 0..<9 { children.append(node("Folder \(index + 1)", "/Folder \(index + 1)", 0.02 * Double(index + 1))) }
        let bytes = children.reduce(UInt64(0)) { $0 + $1.bytes }
        let root = StorageNode(name: "Internal storage", path: "/", bytes: bytes, files: 2_809, images: 0, videos: 0, audio: 0, children: children)
        return StorageScan(scanID: UUID(), root: root, foldersScanned: 739, done: false, error: nil)
    }

    static func verify(done: Bool) -> VerifyProgress {
        let recent = [VerifyProgress.Item(name: "20260916_193002.mp4", sizeBytes: 96_200_000, result: .identical),
                      VerifyProgress.Item(name: "20260917_081544.jpg", sizeBytes: 4_100_000, result: .identical),
                      VerifyProgress.Item(name: "20260917_081540.jpg", sizeBytes: 3_800_000, result: .identical)]
        return VerifyProgress(verifyID: UUID(), batchID: 10, filesTotal: 74, bytesTotal: 1_790_000_000, bytesChecked: done ? 1_790_000_000 : 1_020_000_000,
                              identical: done ? 72 : 42, identicalBytes: done ? 1_780_000_000 : 1_020_000_000,
                              problems: done ? [VerifyProgress.Item(name: "20260903_101512.jpg", sizeBytes: 4_000_000, result: .missingOnPhone),
                                                VerifyProgress.Item(name: "20260911_220145.mp4", sizeBytes: 6_000_000, result: .different)] : [],
                              recent: recent, current: done ? nil : "20260917_081927.mp4", done: done, error: nil)
    }

    static var state: PulliState {
        var state = PulliState()
        state.devices = [phone.id: phone]
        let now = Date()
        func file(_ id: Int64, _ name: String, _ size: UInt64, _ state: FileSnapshot.FileState, done: UInt64? = nil) -> FileSnapshot {
            FileSnapshot(jobID: id, name: name, sizeBytes: size, bytesDone: done ?? size, state: state)
        }
        let recent = [file(45, "20260916_193002.mp4", 96_200_000, .done), file(44, "20260917_081544.jpg", 4_100_000, .done),
                      file(43, "20260917_081540.jpg", 3_800_000, .done), file(42, "20260915_120000.jpg", 4_000_000, .done)]
        func batch(_ id: Int64, _ title: String, _ phase: BatchPhase, done: Int, total: Int, bytes: UInt64, of totalBytes: UInt64,
                   attention: Int = 0, current: FileSnapshot? = nil, started: TimeInterval, finished: TimeInterval? = nil, destination: String = "Downloads/myGalaxy") -> BatchSnapshot {
            BatchSnapshot(id: id, deviceID: phone.id, deviceName: "myGalaxy", title: title, destinationPath: NSHomeDirectory() + "/" + destination,
                          phase: phase, filesTotal: total, filesDone: done, filesSkipped: 0, filesNeedingAttention: attention,
                          bytesTotal: totalBytes, bytesDone: bytes, bytesPerSecond: phase == .copying ? 31_400_000 : 0,
                          secondsRemaining: phase == .copying ? 23 : nil, current: current, recent: recent,
                          createdAt: now.addingTimeInterval(-started), finishedAt: finished.map { now.addingTimeInterval(-$0) })
        }
        state.batches = [
            12: batch(12, "Camera", .copying, done: 46, total: 74, bytes: 1_130_000_000, of: 1_830_000_000,
                      current: file(46, "20260917_081927.mp4", 385_400_000, .copying, done: 158_000_000), started: 40),
            11: batch(11, "Movies", .paused(.phoneDisconnected), done: 45, total: 73, bytes: 1_130_000_000, of: 1_830_000_000,
                      current: file(90, "20260917_081927.mp4", 385_400_000, .copying, done: 158_000_000), started: 600, destination: "Movies/Phone"),
            10: batch(10, "Download", .completed, done: 72, total: 74, bytes: 1_790_000_000, of: 1_790_000_000, attention: 2, started: 7200, finished: 7142,
                      destination: "Desktop/Phone downloads"),
            9: batch(9, "DCIM, Pictures", .completed, done: 1284, total: 1284, bytes: 42_800_000_000, of: 42_800_000_000, started: 400_000, finished: 398_000),
            8: batch(8, "Movies", .cancelled, done: 1, total: 3, bytes: 800_000_000, of: 2_300_000_000, started: 300_000, finished: 299_000,
                     destination: "Movies/Phone"),
        ]
        return state
    }
}

/// Pulli's icon on the standard macOS icon grid (an 824-point rounded square in a 1024 canvas,
/// with its shadow): warm Porcelain glass, and Pulli's mark in 3D (`PulliIcon`) on it.
struct AppIconArt: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape.fill(.black.opacity(0.22)).frame(width: 824, height: 824).blur(radius: 22).offset(y: 16)
            ZStack {
                // Porcelain: warm white to soft paper grey, lit from the top left.
                shape.fill(LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF4F1EB), Color(hex: 0xE2DDD3)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                shape.fill(RadialGradient(colors: [.white, .white.opacity(0)], center: UnitPoint(x: 0.2, y: 0.1),
                                          startRadius: 0, endRadius: 520))
                shape.fill(RadialGradient(colors: [Color(hex: 0x3557E0).opacity(0.10), .clear], center: UnitPoint(x: 0.95, y: 1),
                                          startRadius: 0, endRadius: 560))
                Image(nsImage: PulliIcon.image(side: 824))
                    .resizable()
                    .frame(width: 824, height: 824)
                // Glazed edge: bright at the top, a fine dark line below.
                shape.strokeBorder(LinearGradient(colors: [.white, Color(hex: 0x1A1A1F, opacity: 0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 4)
            }
            .frame(width: 824, height: 824)
            .clipShape(shape)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// Close-ups of the 3D art (snapshots only).
private struct GemSheet: View {
    var body: some View {
        VStack(spacing: 30) {
            HStack(spacing: 40) {
                Gem(form: .disc, palette: .blue, symbol: "camera.aperture", size: 180)
                Gem(form: .hexagon, palette: .violet, symbol: "iphone.gen3", size: 180)
                Gem(form: .squircle, palette: .sky, symbol: "arrow.down.to.line", size: 180, tilt: 8)
                Gem(form: .disc, palette: .slate, symbol: "stop.fill", size: 180, face: true)
            }
            HStack(spacing: 30) {
                Gem(form: .disc, palette: .green, symbol: "checkmark", size: 60)
                Gem(form: .disc, palette: .amber, symbol: "exclamationmark", size: 60)
                Gem(form: .squircle, palette: .teal, symbol: "iphone.gen3", size: 40)
                PhoneArt(width: 220, palette: .teal, screen: .notify, cable: .plugged)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SceneBackground(kind: .home, animated: false))
    }
}

/// Every screen the connection guide shows on the phone (snapshots only).
private struct GuideScreens: View {
    var body: some View {
        let words = PhoneWords(manufacturer: "Samsung", model: "SM-F966B")
        HStack(spacing: 0) {
            ForEach(Array(GuideView.chargingSteps(words).enumerated()), id: \.offset) { _, step in
                PhoneArt(width: 210, palette: .teal, screen: step.screen, cable: .none)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SceneBackground(kind: .home, animated: false))
    }
}
