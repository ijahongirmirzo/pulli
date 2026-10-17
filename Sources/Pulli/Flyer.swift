import AppKit
import PulliProtocol
import SwiftUI

/// `Pulli --flyer DIR`: a one-page A4 flyer for testers (Pulli-flyer.pdf and .png), made from the
/// app's own screens (the same sample data as the snapshots) and a list of what it does.
@MainActor
enum Flyer {
    static let page = CGSize(width: 595, height: 842)

    static func render(to folder: URL) {
        _ = NSApplication.shared
        AppTheme.current = .porcelain
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shots = Shots(
            overview: screenshot { _ in },
            browse: screenshot { $0.browsePath = "/DCIM/Camera"; $0.browseOptions.layout = .icons },
            map: screenshot { $0.storageScan = Snapshots.storageScan; $0.storageScanID = Snapshots.storageScan.scanID; $0.showingStorageMap = true },
            copying: screenshot { $0.section = .copies; $0.focusedBatchID = 12 })
        let content = FlyerPage(shots: shots)
            .frame(width: page.width, height: page.height)
            .environment(\.colorScheme, .light)
            .environment(\.isSnapshot, true)
            .environment(AppModel(preview: Snapshots.state, summaries: [Snapshots.phone.id: Snapshots.summary]))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 4
        guard let image = renderer.cgImage else {
            print("could not render the flyer")
            return
        }
        let png = folder.appendingPathComponent("Pulli-flyer.png")
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: png)
        // The PDF holds the page as one high-resolution picture (blurs and glass need rasterising).
        let pdf = folder.appendingPathComponent("Pulli-flyer.pdf")
        var box = CGRect(origin: .zero, size: page)
        if let context = CGContext(pdf as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "Pulli", kCGPDFContextCreator as String: "Pulli"] as CFDictionary) {
            context.beginPDFPage(nil)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPDFPage()
            context.closePDF()
        }
        print("wrote \(pdf.path) and \(png.path)")
    }

    /// A screen of the app with the sample phone, as a picture.
    private static func screenshot(_ configure: (AppModel) -> Void) -> NSImage {
        let model = AppModel(preview: Snapshots.state, summaries: [Snapshots.phone.id: Snapshots.summary])
        model.previewListings = ["/DCIM/Camera": Snapshots.cameraFiles]
        configure(model)
        let renderer = ImageRenderer(content: MainWindow().environment(model)
            .frame(width: 1120, height: 720)
            .environment(\.colorScheme, .light)
            .environment(\.isSnapshot, true))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return NSImage() }
        return NSImage(cgImage: image, size: NSSize(width: 1120, height: 720))
    }

    struct Shots {
        var overview: NSImage
        var browse: NSImage
        var map: NSImage
        var copying: NSImage
    }
}

private struct FlyerPage: View {
    var shots: Flyer.Shots

    private let features: [(ArtPalette, String, String, String)] = [
        (.teal, "arrow.clockwise", "Never starts over", "Pull the cable or close the lid: copies pause and pick up where they stopped, checked chunk by chunk."),
        (.blue, "sparkles", "Only what's new", "Copies new photos since last time, and skips ones already on your Mac, even under other names."),
        (.violet, "smartphone", "Your phone in Finder", "Under Locations in Finder, with a phone icon. Open, copy and drag files both ways."),
        (.sky, "doc.on.clipboard.fill", "Copy, paste, drop", "⌘C and ⌘V with Finder. Drop files from Telegram, WhatsApp or a browser onto the phone."),
        (.slate, "square.grid.2x2.fill", "Browse like Finder", "Icons or list, photo previews, sorting, Quick Look, open files straight from the phone."),
        (.green, "checkmark.shield.fill", "Free up space safely", "Checks every copy against the phone byte for byte before anything is deleted."),
        (.amber, "chart.pie.fill", "See what fills it", "A storage map of the whole phone. WhatsApp, Telegram and Instagram media in one click."),
        (.pink, "bolt.fill", "Knows your cable", "Measures the real speed and tells you when a USB 3 cable would be faster."),
        (.teal, "bell.badge.fill", "Ready when you are", "A chime when a phone is plugged in. Opens at login and keeps copying after you close it."),
        (.blue, "rectangle.3.group.fill", "Fits in on your Mac", "Menu bar, desktop widget, notifications, Shortcuts, and animated guides for every step."),
    ]

    var body: some View {
        ZStack {
            SceneBackground(kind: .home, animated: false)
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 16)
                screen(shots.overview)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 10)
                HStack(spacing: 8) {
                    screen(shots.copying, radius: 7)
                    screen(shots.browse, radius: 7)
                    screen(shots.map, radius: 7)
                }
                .padding(.bottom, 18)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(Array(features.enumerated()), id: \.offset) { _, feature in
                        HStack(alignment: .top, spacing: 9) {
                            Gem(form: .squircle, palette: feature.0, symbol: feature.1, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feature.2).font(.pulli(10.5, .bold)).foregroundStyle(Color(hex: 0x1A1A1F))
                                Text(feature.3).font(.pulli(8.2)).foregroundStyle(Color(hex: 0x1A1A1F, opacity: 0.68))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 12)
                footer
            }
            .padding(.horizontal, 34).padding(.top, 32).padding(.bottom, 26)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppIconArt()
                .frame(width: 1024, height: 1024)
                .scaleEffect(84.0 / 1024)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pulli").font(.pulli(40, .bold)).tracking(-1).foregroundStyle(Color(hex: 0x1A1A1F))
                Text("Your Android phone's photos and files, on your Mac. Over the cable, and it never loses its place.")
                    .font(.pulli(12.5, .medium)).foregroundStyle(Color(hex: 0x1A1A1F, opacity: 0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func screen(_ image: NSImage, radius: CGFloat = 12) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(1120.0 / 720.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color(hex: 0x1A1A1F, opacity: 0.10), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(Color(hex: 0x1A1A1F, opacity: 0.12)).frame(height: 0.6)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GET STARTED").font(.pulli(8, .bold)).tracking(0.8).foregroundStyle(Color(hex: 0x2443C2))
                    Text("Open the disk image, drag Pulli to Applications, and open it. It is signed and checked by Apple, so it opens with a double-click.")
                        .font(.pulli(8.2)).foregroundStyle(Color(hex: 0x1A1A1F, opacity: 0.7)).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("YOU NEED").font(.pulli(8, .bold)).tracking(0.8).foregroundStyle(Color(hex: 0x2443C2))
                    Text("A Mac with Apple silicon and macOS 26, an Android phone and a USB data cable.")
                        .font(.pulli(8.2)).foregroundStyle(Color(hex: 0x1A1A1F, opacity: 0.7)).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 170, alignment: .leading)
            }
        }
    }
}
