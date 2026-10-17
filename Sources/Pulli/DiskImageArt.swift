import AppKit
import SwiftUI

/// `Pulli --dmg-background DIR [--unsigned]`: the disk image window's background
/// (background.png and background@2x.png): Pulli on the left, Applications on the right, an arrow
/// between them, and the steps. With --unsigned it also says how to allow a build that is not
/// notarised. scripts/make-dmg.sh places the icons on it (see `DiskImageArt.pulli`, `.applications`)
/// and makes the window's content exactly `window` (the frame adds the title bar).
@MainActor
enum DiskImageArt {
    static let window = CGSize(width: 660, height: 420)
    /// Icon centres in the window (Finder's icon positions), and their size.
    static let pulli = CGPoint(x: 170, y: 188)
    static let applications = CGPoint(x: 490, y: 188)
    static let iconSize: CGFloat = 112

    static func render(to folder: URL, unsigned: Bool) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let renderer = ImageRenderer(content: Background(unsigned: unsigned).frame(width: window.width, height: window.height))
            renderer.scale = CGFloat(scale)
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: folder.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
        }
        print("wrote \(folder.path)/background.png")
    }

    private struct Background: View {
        var unsigned: Bool
        private let ink = Color(hex: 0x1A1A1F)
        private let soft = Color(hex: 0x5C5B63)

        var body: some View {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: 0xFFFFFF), Color(hex: 0xF5F2EC), Color(hex: 0xEAE5DC)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.75), .clear], center: UnitPoint(x: 0.2, y: 0.05), startRadius: 0, endRadius: 320)
                RadialGradient(colors: [Color(hex: 0x3557E0).opacity(0.08), .clear], center: UnitPoint(x: 0.95, y: 0.95), startRadius: 0, endRadius: 300)

                VStack(spacing: 5) {
                    Text("Install Pulli").font(.pulli(25, .bold)).tracking(-0.3).foregroundStyle(ink)
                    Text("Drag Pulli onto the Applications folder.").font(.pulli(14, .medium)).foregroundStyle(soft)
                }
                .frame(width: DiskImageArt.window.width)
                .padding(.top, 26)

                spot(at: DiskImageArt.pulli, tint: Color(hex: 0xE4DCCD))
                spot(at: DiskImageArt.applications, tint: Color(hex: 0xC9D4FF))
                Arrow()
                    .frame(width: DiskImageArt.window.width, height: DiskImageArt.window.height)
                plate(at: DiskImageArt.pulli)
                plate(at: DiskImageArt.applications)

                steps
                    .frame(width: DiskImageArt.window.width)
                    // Clear of Finder's path bar (about 24 points at the bottom, when it is on).
                    .offset(y: unsigned ? 298 : 318)
                if unsigned {
                    Text("First time only: if macOS says it cannot check Pulli, open System Settings › Privacy & Security and click Open Anyway.")
                        .font(.pulli(10.5)).foregroundStyle(soft).multilineTextAlignment(.center)
                        .frame(width: 520)
                        .frame(width: DiskImageArt.window.width)
                        .offset(y: 338)
                }
            }
        }

        /// A soft pool of light for an icon to sit on, with its shadow on the "floor".
        private func spot(at point: CGPoint, tint: Color) -> some View {
            ZStack {
                Circle().fill(RadialGradient(colors: [.white.opacity(0.95), tint.opacity(0.25), .clear], center: .center, startRadius: 0, endRadius: 95))
                    .frame(width: 190, height: 190)
                Ellipse().fill(Color(hex: 0x1A1A1F).opacity(0.16)).frame(width: 110, height: 16).blur(radius: 7)
                    .offset(y: DiskImageArt.iconSize / 2 - 2)
            }
            .position(point)
        }

        /// Behind each icon's name, so Finder's label (white in dark mode, black in light mode)
        /// reads either way.
        private func plate(at point: CGPoint) -> some View {
            Capsule().fill(Color(hex: 0x8E8A82).opacity(0.9))
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
                .frame(width: 118, height: 22)
                .position(x: point.x, y: point.y + DiskImageArt.iconSize / 2 + 15)
        }

        private var steps: some View {
            HStack(spacing: 16) {
                step(1, "Drag Pulli to Applications")
                step(2, "Open Pulli from Applications")
                step(3, "Plug in your phone and unlock it")
            }
        }

        private func step(_ number: Int, _ text: String) -> some View {
            HStack(spacing: 7) {
                Text("\(number)").font(.pulli(11, .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(LinearGradient(colors: [Color(hex: 0x5873EE), Color(hex: 0x1C35A8)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Color(hex: 0x1C35A8).opacity(0.3), radius: 3, y: 2)
                Text(text).font(.pulli(11.5, .semibold)).foregroundStyle(ink)
            }
        }
    }

    /// A curved arrow from Pulli to Applications, teal to violet, with a soft glow.
    private struct Arrow: View {
        var body: some View {
            let from = CGPoint(x: DiskImageArt.pulli.x + 84, y: DiskImageArt.pulli.y - 6)
            let to = CGPoint(x: DiskImageArt.applications.x - 86, y: DiskImageArt.applications.y - 6)
            let control = CGPoint(x: (from.x + to.x) / 2, y: from.y - 58)
            let gradient = LinearGradient(colors: [Color(hex: 0x7C93F7), Color(hex: 0x1C35A8)], startPoint: UnitPoint(x: from.x / DiskImageArt.window.width, y: 0.5),
                                          endPoint: UnitPoint(x: to.x / DiskImageArt.window.width, y: 0.5))
            // Direction of the curve at its end, for the arrowhead.
            let angle = atan2(to.y - control.y, to.x - control.x)
            let head = Path { path in
                let length: CGFloat = 22, spread: CGFloat = 0.55
                path.move(to: CGPoint(x: to.x - length * cos(angle - spread), y: to.y - length * sin(angle - spread)))
                path.addLine(to: to)
                path.addLine(to: CGPoint(x: to.x - length * cos(angle + spread), y: to.y - length * sin(angle + spread)))
            }
            let curve = Path { path in
                path.move(to: from)
                path.addQuadCurve(to: to, control: control)
            }
            ZStack {
                curve.stroke(Color(hex: 0x3557E0).opacity(0.22), style: StrokeStyle(lineWidth: 14, lineCap: .round)).blur(radius: 8)
                curve.stroke(gradient, style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
                head.stroke(gradient, style: StrokeStyle(lineWidth: 6.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
