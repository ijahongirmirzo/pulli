import SceneKit
import SwiftUI

// Pulli's own glossy artwork (drawn, not bitmaps), matching the design canvas: a Fold-style phone
// with a USB-C cable, and badge "gems" in three shapes.

enum ArtPalette: Sendable {
    case teal, blue, violet, amber, green, pink, sky, slate

    /// The palette in the current theme (amber stays amber everywhere: it means "warning").
    var colors: [Color] {
        self == .amber ? original : AppTheme.current.colors(for: original)
    }

    /// The palette as first designed (the classic theme).
    var original: [Color] {
        switch self {
        case .teal: [Color(hex: 0xA6FFF3), Color(hex: 0x34C9B8), Color(hex: 0x0A6F6C)]
        case .blue: [Color(hex: 0xA9D4FF), Color(hex: 0x3F8CF0), Color(hex: 0x1B3FA8)]
        case .violet: [Color(hex: 0xD9C8FF), Color(hex: 0x8B63F2), Color(hex: 0x4424A8)]
        case .amber: [Color(hex: 0xFFE2A6), Color(hex: 0xF5A93A), Color(hex: 0xA8540C)]
        case .green: [Color(hex: 0xC9FFB8), Color(hex: 0x46C96A), Color(hex: 0x0D6B2E)]
        case .pink: [Color(hex: 0xFFC7DD), Color(hex: 0xF0609A), Color(hex: 0x9C1F5C)]
        case .sky: [Color(hex: 0xC7F1FF), Color(hex: 0x46B6E6), Color(hex: 0x135D93)]
        case .slate: [Color(hex: 0xE3EAF0), Color(hex: 0x8FA0AE), Color(hex: 0x42505C)]
        }
    }
}

/// A polygon with rounded corners (the hexagon gem).
struct RoundedPolygon: Shape {
    var sides = 6
    var cornerRadius: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let points = (0..<sides).map { index -> CGPoint in
            let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(sides)
            return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        var path = Path()
        let start = CGPoint(x: (points[0].x + points[sides - 1].x) / 2, y: (points[0].y + points[sides - 1].y) / 2)
        path.move(to: start)
        for index in 0..<sides {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % sides], radius: cornerRadius)
        }
        path.closeSubpath()
        return path
    }
}

/// Where the pointer is over something that tilts its art in 3D: -1…1 on each axis, (0, 0) when
/// the pointer is away. A card sets it for the whole card (`parallaxSource`), so its gem follows
/// the pointer anywhere on the card; a gem on its own tracks the pointer over itself.
extension EnvironmentValues {
    @Entry var parallax: CGPoint?
}

/// Tracks the pointer over this view and hands it to the art inside as `parallax`.
struct ParallaxSource: ViewModifier {
    @State private var point = CGPoint.zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.parallax, reduceMotion ? .zero : point)
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard !reduceMotion else { return }
                switch phase {
                case .active(let location):
                    // Relative to the view's own size, measured by the geometry reader below.
                    let target = CGPoint(x: max(-1, min(1, location.x / max(size.width, 1) * 2 - 1)),
                                         y: max(-1, min(1, location.y / max(size.height, 1) * 2 - 1)))
                    withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) { point = target }
                case .ended:
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { point = .zero }
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }

    @State private var size = CGSize(width: 1, height: 1)
}

extension View {
    /// The art inside tilts toward the pointer while it moves over this view.
    func parallaxSource() -> some View { modifier(ParallaxSource()) }

}

/// A glossy badge with a symbol: a real 3D object (see `GemModel`), bevelled candy glass with the
/// symbol raised on it in milky white, lit in a studio. It turns toward the pointer (over its
/// card, or over itself); big ones also drift gently. Small ones are rendered once to images.
struct Gem: View {
    enum Form: String { case disc, hexagon, squircle }
    var form: Form
    var palette: ArtPalette
    var symbol: String
    var size: CGFloat
    /// A white "button face" in the middle with the symbol in the dark colour (the Done disc).
    var face = false
    var tilt: Double = 0

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Views are this much bigger than the gem, so its shadow and turns are never cut off.
    static let overscan: CGFloat = 1.6

    var body: some View {
        let key = GemModel.Key(form: form, palette: palette, symbol: symbol, face: face)
        Group {
            if size < 90 {
                FlatGem(form: form, palette: palette, symbol: symbol, size: size, face: face, tilt: tilt)
            } else if isSnapshot {
                Image(nsImage: GemModel.image(key, size: size, tilt: tilt))
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .frame(width: size * Self.overscan, height: size * Self.overscan)
            } else {
                LiveGem(key: key, size: size, tilt: tilt, drifting: size >= 160 && !reduceMotion)
                    .frame(width: size * Self.overscan, height: size * Self.overscan)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Small badges (lists, rows, result lines): flat vector drawing, sharp at any scale. 3D reads as
/// noise at this size.
private struct FlatGem: View {
    var form: Gem.Form
    var palette: ArtPalette
    var symbol: String
    var size: CGFloat
    var face: Bool
    var tilt: Double

    var body: some View {
        let colors = palette.colors
        let side = size * 0.84
        let shape = GemModel.flatShape(form, side: side)
        ZStack {
            shape.fill(LinearGradient(colors: [colors[0].mix(with: colors[1], by: 0.35), colors[1], colors[2]],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            // Gloss on the upper half, as light from above.
            shape.fill(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06), .clear], startPoint: .top, endPoint: .center))
            shape.stroke(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.15)], startPoint: .top, endPoint: .bottom), lineWidth: max(0.75, size / 60))
            if face {
                Circle().fill(.white).frame(width: side * 0.56, height: side * 0.56)
                    .shadow(color: .black.opacity(0.2), radius: size * 0.03, y: size * 0.02)
                Image(systemName: symbol).font(.system(size: size * 0.24, weight: .heavy)).foregroundStyle(colors[2])
            } else {
                Image(systemName: symbol).font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(AppTheme.current.symbolOnArt(palette))
                    .shadow(color: colors[2].mix(with: .black, by: 0.4).opacity(0.5), radius: size * 0.015, y: size * 0.02)
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(tilt))
        .shadow(color: colors[2].mix(with: .black, by: 0.5).opacity(0.45), radius: size * 0.06, y: size * 0.05)
        .frame(width: size, height: size)
    }
}

/// A big gem, live: it follows the pointer over its card or page (`parallax`), or else over
/// itself. Only these read the pointer, so small icons are not redrawn as it moves.
private struct LiveGem: View {
    var key: GemModel.Key
    var size: CGFloat
    var tilt: Double
    var drifting: Bool
    @Environment(\.parallax) private var sourced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var own = CGPoint.zero
    @State private var holder = SceneHolder()

    var body: some View {
        SceneView3D(scene: holder.scene(key.id + (drifting ? "~" : "")) { GemModel.scene(key, drifting: drifting) },
                    pose: GemModel.pose(pointer: sourced ?? own, tilt: tilt), playing: drifting)
            .onContinuousHover { phase in
                guard sourced == nil, !reduceMotion else { return }
                switch phase {
                case .active(let location):
                    let side = size * Gem.overscan
                    own = CGPoint(x: max(-1, min(1, location.x / side * 2 - 1)), y: max(-1, min(1, location.y / side * 2 - 1)))
                case .ended:
                    own = .zero
                }
            }
    }
}

/// Keeps a view's scene across updates, rebuilt only when what it shows changes.
final class SceneHolder {
    private var key: String?
    private var scene: SCNScene?

    @MainActor
    func scene(_ key: String, build: () -> SCNScene) -> SCNScene {
        if let scene, self.key == key { return scene }
        let built = build()
        self.key = key
        scene = built
        return built
    }
}

/// The gem's 3D model. Built in points on a 100-point badge (the shape is 80 across), scaled to
/// scene units (1 unit = 100 points).
@MainActor
enum GemModel {
    struct Key: Hashable {
        var form: Gem.Form
        var palette: ArtPalette
        var symbol: String
        var face: Bool
        var id: String { "\(form.rawValue)|\(palette)|\(symbol)|\(face)|\(AppTheme.current.rawValue)" }
    }

    /// At rest the gem is turned a little, so its thickness shows (lower left, as in a photograph
    /// from slightly below); the pointer turns it further toward itself.
    static func pose(pointer: CGPoint, tilt: Double) -> SIMD3<Float> {
        SIMD3(Float(-0.2 + pointer.y * 0.19), Float(0.3 + pointer.x * 0.25), Float(-tilt * .pi / 180))
    }

    /// Small icons in lists and rows: almost face on, still (only a hint of their depth).
    static func flatPose(tilt: Double) -> SIMD3<Float> {
        SIMD3(-0.07, 0.1, Float(-tilt * .pi / 180))
    }

    static func image(_ key: Key, size: CGFloat, tilt: Double) -> NSImage {
        let side = size * Gem.overscan
        return SceneBaker.image(key: "gem|\(key.id)|\(tilt)|\(size < 90)|\(SceneBaker.checkPointer)", points: CGSize(width: side, height: side), scale: size < 90 ? 4 : 3) {
            let scene = scene(key, drifting: false)
            if let subject = scene.rootNode.childNode(withName: "subject", recursively: true) {
                let pose = size < 90 ? flatPose(tilt: tilt) : pose(pointer: SceneBaker.checkPointer, tilt: tilt)
                subject.eulerAngles = SCNVector3(CGFloat(pose.x), CGFloat(pose.y), CGFloat(pose.z))
            }
            return scene
        }
    }

    static func scene(_ key: Key, drifting: Bool) -> SCNScene {
        let subject = SCNNode()
        subject.name = "subject"
        let pose = pose(pointer: .zero, tilt: 0)
        subject.eulerAngles = SCNVector3(CGFloat(pose.x), CGFloat(pose.y), CGFloat(pose.z))
        let model = SCNNode()
        model.scale = SCNVector3(0.01, 0.01, 0.01)
        subject.addChildNode(model)

        let depth: CGFloat = 20
        let body = SCNNode(geometry: Studio.slab(outline(key.form), depth: depth, bevel: 7))
        let front = Studio.candy(key.palette), deep = Studio.candy(key.palette, dark: true)
        body.geometry?.materials = [front, deep, deep, front, deep]
        model.addChildNode(body)

        if key.face {
            let disc = SCNNode(geometry: Studio.slab(NSBezierPath(ovalIn: NSRect(x: -24, y: -24, width: 48, height: 48)), depth: 8, bevel: 3.5))
            disc.geometry?.materials = [Studio.milk()]
            disc.position = SCNVector3(0, 0, depth / 2 + 3)
            model.addChildNode(disc)
            if let path = SymbolOutline.path(key.symbol, side: 22) {
                let mark = SCNNode(geometry: Studio.slab(path, depth: 4, bevel: 1.2))
                mark.geometry?.materials = [Studio.candy(key.palette, dark: true)]
                mark.position = SCNVector3(0, 0, depth / 2 + 3 + 4 + 1.5)
                model.addChildNode(mark)
            }
        } else if let path = SymbolOutline.path(key.symbol, side: 40) {
            let mark = SCNNode(geometry: Studio.slab(path, depth: 8, bevel: 2.0))
            let ink = AppTheme.current.symbolOnArt(key.palette)
            mark.geometry?.materials = [AppTheme.current == .porcelain ? Studio.milk(tint: ink) : Studio.milk()]
            mark.position = SCNVector3(0, 0, depth / 2 + 2.5)
            model.addChildNode(mark)
        }

        let holder = SCNNode()
        holder.addChildNode(subject)
        if drifting {
            // A slow drift, as if floating.
            let up = SCNAction.moveBy(x: 0, y: 0.025, z: 0, duration: 2.6)
            up.timingMode = .easeInEaseOut
            let turn = SCNAction.rotateBy(x: 0, y: 0.12, z: 0, duration: 3.4)
            turn.timingMode = .easeInEaseOut
            holder.runAction(.repeatForever(.sequence([up, up.reversed()])))
            holder.runAction(.repeatForever(.sequence([turn, turn.reversed()])))
        }
        return Studio.scene(subject: holder, visible: Gem.overscan)
    }

    /// The badge's outline for flat drawing, `side` across.
    static func flatShape(_ form: Gem.Form, side: CGFloat) -> AnyShape {
        switch form {
        case .disc: AnyShape(Circle())
        case .hexagon: AnyShape(RoundedPolygon(sides: 6, cornerRadius: side * 0.11))
        case .squircle: AnyShape(RoundedRectangle(cornerRadius: side * 0.29, style: .continuous))
        }
    }

    /// The badge's outline, 80 points across, centred on the origin.
    static func outline(_ form: Gem.Form) -> NSBezierPath {
        let rect = CGRect(x: -40, y: -40, width: 80, height: 80)
        let path: Path = switch form {
        case .disc: Circle().path(in: rect)
        case .hexagon: RoundedPolygon(sides: 6, cornerRadius: 9).path(in: CGRect(x: -43, y: -43, width: 86, height: 86))
        case .squircle: RoundedRectangle(cornerRadius: 23, style: .continuous).path(in: rect)
        }
        return NSBezierPath(cgPath: path.cgPath)
    }
}

/// The hero phone drawn flat (the app icon). Drawn in the canvas's 320 × 340 coordinate space and
/// scaled to `width`. Screens use the 3D `PhoneArt`.
struct PhoneDrawing: View {
    typealias Screen = PhoneArt.Screen
    typealias Cable = PhoneArt.Cable

    var width: CGFloat
    var palette: ArtPalette = .teal
    var screen: Screen = .photos
    var cable: Cable = .plugged
    /// 0…1: how far the photo tiles have "lit up" (the intro animates it).
    var reveal: Double = 1

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 320
            context.scaleBy(x: scale, y: scale)
            let colors = palette.colors

            var glow = context
            glow.addFilter(.blur(radius: 30))
            glow.opacity = 0.55
            glow.fill(Path(ellipseIn: CGRect(x: 42, y: 32, width: 236, height: 276)), with: .color(colors[1]))

            var floor = context
            floor.addFilter(.blur(radius: 7))
            floor.opacity = 0.35
            floor.fill(Path(ellipseIn: CGRect(x: 72, y: 306, width: 184, height: 20)), with: .color(.black))

            let back = RoundedRectangle(cornerRadius: 28, style: .continuous).path(in: CGRect(x: 132, y: 38, width: 120, height: 236))
            context.fill(back, with: .linearGradient(Gradient(colors: [colors[1], Color(hex: 0x062B33)]), startPoint: CGPoint(x: 132, y: 38), endPoint: CGPoint(x: 252, y: 274)))
            context.stroke(back, with: .color(.white.opacity(0.25)), lineWidth: 1.5)

            let front = RoundedRectangle(cornerRadius: 28, style: .continuous).path(in: CGRect(x: 92, y: 52, width: 124, height: 240))
            context.fill(front, with: .linearGradient(Gradient(colors: colors), startPoint: CGPoint(x: 92, y: 52), endPoint: CGPoint(x: 216, y: 292)))
            context.stroke(front, with: .color(.white.opacity(0.6)), lineWidth: 1.5)

            let display = RoundedRectangle(cornerRadius: 20, style: .continuous).path(in: CGRect(x: 101, y: 62, width: 106, height: 220))
            context.fill(display, with: .linearGradient(Gradient(colors: [Color(hex: 0x16384A), Color(hex: 0x0A1824)]), startPoint: CGPoint(x: 101, y: 62), endPoint: CGPoint(x: 150, y: 282)))

            Self.drawScreen(in: &context, screen: screen, reveal: reveal)

            var shine = context
            shine.clip(to: front)
            var band = Path()
            band.move(to: CGPoint(x: 92, y: 52))
            band.addLine(to: CGPoint(x: 182, y: 52))
            band.addLine(to: CGPoint(x: 92, y: 196))
            band.closeSubpath()
            shine.opacity = 0.55
            shine.fill(band, with: .linearGradient(Gradient(colors: [.white.opacity(0.6), .white.opacity(0)]), startPoint: CGPoint(x: 92, y: 52), endPoint: CGPoint(x: 160, y: 150)))

            context.fill(Path(ellipseIn: CGRect(x: 150.6, y: 66.6, width: 6.8, height: 6.8)), with: .color(.black.opacity(0.55)))
            drawCable(in: &context)
        } symbols: {
            Image(systemName: "lock.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).tag(1)
            Image(systemName: "pause.fill").font(.system(size: 44, weight: .bold)).foregroundStyle(Color(hex: 0xFFD58A)).tag(2)
            Image(systemName: "checkmark").font(.system(size: 44, weight: .heavy)).foregroundStyle(.white).tag(3)
        }
        .frame(width: width, height: width * 340 / 320)
        .accessibilityHidden(true)
    }

    /// What the display shows, in canvas coordinates (the display is at 101, 62, 106 × 220).
    /// Needs the symbols 1 (lock), 2 (pause) and 3 (check).
    static func drawScreen(in context: inout GraphicsContext, screen: PhoneArt.Screen, reveal: Double) {
        switch screen {
        case .photos:
            let tiles: [UInt32] = [0x7FE3D6, 0xFFB86B, 0xA58BFF, 0x6BB8FF, 0xFF8FB1, 0x9BE38F]
            for index in 0..<15 {
                let lit = Double(index) / 15 < reveal
                let rect = CGRect(x: 107 + CGFloat(index % 3) * 32, y: 96 + CGFloat(index / 3) * 32, width: 26, height: 26)
                context.fill(RoundedRectangle(cornerRadius: 6, style: .continuous).path(in: rect),
                             with: .color(Color(hex: tiles[(index * 5) % 6], opacity: lit ? 0.92 : 0.12)))
            }
            context.fill(Capsule().path(in: CGRect(x: 112, y: 76, width: 40, height: 6)), with: .color(.white.opacity(0.7)))
        case .notify:
            context.fill(RoundedRectangle(cornerRadius: 11).path(in: CGRect(x: 108, y: 76, width: 92, height: 58)), with: .color(.white.opacity(0.95)))
            context.fill(Capsule().path(in: CGRect(x: 117, y: 86, width: 48, height: 6)), with: .color(Color(hex: 0x0B1D26, opacity: 0.5)))
            context.fill(Capsule().path(in: CGRect(x: 117, y: 98, width: 70, height: 6)), with: .color(Color(hex: 0x0B1D26, opacity: 0.8)))
            context.fill(Capsule().path(in: CGRect(x: 117, y: 113, width: 40, height: 12)), with: .color(.accent))
            context.fill(Capsule().path(in: CGRect(x: 161, y: 113, width: 30, height: 12)), with: .color(Color(hex: 0x0B1D26, opacity: 0.15)))
            if let lock = context.resolveSymbol(id: 1) { context.draw(lock, at: CGPoint(x: 154, y: 210)) }
        case .pause:
            if let pause = context.resolveSymbol(id: 2) { context.draw(pause, at: CGPoint(x: 154, y: 172)) }
        case .check:
            if let check = context.resolveSymbol(id: 3) { context.draw(check, at: CGPoint(x: 154, y: 172)) }
        case .blank, .unlock, .allow, .shade, .usb:
            break
        }
    }

    private func drawCable(in context: inout GraphicsContext) {
        let metal = GraphicsContext.Shading.linearGradient(Gradient(colors: [Color(hex: 0xF4F8FA), Color(hex: 0x9FB0B8)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 20))
        let wire = GraphicsContext.Shading.linearGradient(Gradient(colors: [Color(hex: 0xE9F1F3), Color(hex: 0xB8C6CC)]), startPoint: CGPoint(x: 150, y: 0), endPoint: CGPoint(x: 300, y: 0))
        switch cable {
        case .plugged:
            var path = Path()
            path.move(to: CGPoint(x: 152, y: 292))
            path.addCurve(to: CGPoint(x: 256, y: 318), control1: CGPoint(x: 152, y: 318), control2: CGPoint(x: 196, y: 324))
            context.stroke(path, with: wire, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.fill(RoundedRectangle(cornerRadius: 4).path(in: CGRect(x: 140, y: 284, width: 24, height: 12)), with: metal)
            context.fill(RoundedRectangle(cornerRadius: 7).path(in: CGRect(x: 250, y: 308, width: 44, height: 20)), with: metal)
            context.fill(RoundedRectangle(cornerRadius: 2).path(in: CGRect(x: 292, y: 313, width: 10, height: 10)), with: .color(Color(hex: 0x8FA0A7)))
        case .unplugged:
            var path = Path()
            path.move(to: CGPoint(x: 226, y: 324))
            path.addCurve(to: CGPoint(x: 262, y: 318), control1: CGPoint(x: 240, y: 322), control2: CGPoint(x: 250, y: 320))
            context.stroke(path, with: wire, style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.fill(RoundedRectangle(cornerRadius: 7).path(in: CGRect(x: 258, y: 308, width: 44, height: 20)), with: metal)
            var sparks = Path()
            sparks.move(to: CGPoint(x: 200, y: 300)); sparks.addLine(to: CGPoint(x: 192, y: 290))
            sparks.move(to: CGPoint(x: 212, y: 296)); sparks.addLine(to: CGPoint(x: 214, y: 284))
            sparks.move(to: CGPoint(x: 188, y: 312)); sparks.addLine(to: CGPoint(x: 176, y: 308))
            context.stroke(sparks, with: .color(Color(hex: 0xFFC873)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .none:
            break
        }
    }
}

/// A small gradient tile with a file-kind symbol (rows in lists).
struct KindThumb: View {
    enum Kind { case image, video, folder, document, audio }
    var kind: Kind
    var size: CGFloat = 28

    static func kind(forName name: String, isFolder: Bool) -> Kind {
        if isFolder { return .folder }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "raw", "bmp", "tif", "tiff": return .image
        case "mp4", "mov", "m4v", "3gp", "mkv", "avi", "webm": return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "amr": return .audio
        default: return .document
        }
    }

    var body: some View {
        let (colors, symbol): ([Color], String) = switch kind {
        case .video: ([Color(hex: 0xB7A2FF), Color(hex: 0x6B4BE0)], "video.fill")
        case .image: ([Color(hex: 0x7FEBDD), Color(hex: 0x1C9C91)], "photo.fill")
        case .folder: ([Color(hex: 0x8CC6FF), Color(hex: 0x2F6FE0)], "folder.fill")
        case .document: ([Color(hex: 0xFFD28F), Color(hex: 0xD98A1C)], "doc.fill")
        case .audio: ([Color(hex: 0xFFB1CF), Color(hex: 0xD9467F)], "music.note")
        }
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.8))
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.46, weight: .semibold)).foregroundStyle(.white))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(.black.opacity(0.18)).blur(radius: 3).offset(y: 3))
            .accessibilityHidden(true)
    }
}

/// A progress pie on a white disc (rail tile status, "now copying" rows).
struct PieBadge: View {
    var fraction: Double
    var color: Color
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.95))
            PieSlice(fraction: fraction).fill(color).padding(size * 0.083)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PieSlice: Shape {
    var fraction: Double
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: center)
        path.addArc(center: center, radius: rect.width / 2, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(max(fraction, 0), 1)), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// The ring around the hero phone on the Copying and Paused screens.
struct HeroRing<Art: View>: View {
    var fraction: Double
    var color: Color
    var size: CGFloat = 330
    var glow = true
    @ViewBuilder var art: Art
    @Environment(\.tone) private var tone

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: 10).padding(12)
            if glow {
                Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(12).blur(radius: 6).opacity(0.8)
            }
            Circle().trim(from: 0, to: fraction).stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(12)
            // Raised a little: the phone's cable lies below it, above the percentage.
            art.padding(.bottom, 44)
            VStack {
                Spacer()
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.pulli(15, .bold)).monospacedDigit()
                    .padding(.horizontal, 14).padding(.vertical, 5)
                    .panel(radius: 99)
                    .padding(.bottom, 2)
            }
        }
        .frame(width: size, height: size)
        .animation(.easeInOut(duration: 0.6), value: fraction)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Copy progress")
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
