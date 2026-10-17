import AppKit
import SceneKit
import SwiftUI

/// The hero phone as a real 3D object: a slim foldable (both halves, the front one facing you)
/// with a metal frame, a glowing glass screen and a USB-C cable, lit in the studio. It turns
/// toward the pointer. Same inputs as the old drawing.
struct PhoneArt: View {
    enum Screen: Hashable {
        case photos, notify, pause, check, blank
        /// The connection guide: lock screen, notification shade, USB options, allow dialog.
        case unlock, allow
        case shade(ShadeScreen)
        case usb(USBScreen)
    }

    struct ShadeScreen: Hashable {
        var title: String
        var detail: String
        /// Tapping the notification (else: swiping down to open the shade).
        var tapping: Bool
    }

    struct USBScreen: Hashable {
        var title: String
        var heading: String
        var options: [String]
        var selected: Int
    }
    enum Cable: Hashable { case plugged, unplugged, none }

    var width: CGFloat
    var palette: ArtPalette = .teal
    var screen: Screen = .photos
    var cable: Cable = .plugged
    /// 0…1: how far the photo tiles have "lit up" (the intro and copies animate it).
    var reveal: Double = 1
    /// Screen changes dim and brighten again, like a real display (the guide).
    var fades = false

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The pointer over the page (see `parallaxSource`), else over the phone itself.
    @Environment(\.parallax) private var sourced
    @State private var pointer = CGPoint.zero
    @State private var holder = SceneHolder()

    static let overscan: CGFloat = 1.5

    var body: some View {
        let height = width * 340 / 320
        let key = PhoneModel.Key(palette: palette, cable: cable)
        let screenImage = PhoneModel.screenImage(palette: palette, screen: screen, reveal: reveal)
        ZStack {
            // The screen's glow on what is behind the phone (drawn by SwiftUI: never clipped).
            Ellipse().fill(palette.colors[1].opacity(0.5))
                .frame(width: width * 0.62, height: height * 0.72)
                .blur(radius: width * 0.14)
                .offset(x: -width * 0.02)
                .allowsHitTesting(false)
            Group {
                if isSnapshot {
                    Image(nsImage: PhoneModel.image(key, screen: screenImage, screenKey: "\(screen)|\(Int(reveal * 15))", width: width))
                        .resizable()
                        .interpolation(.high)
                } else {
                    let scene = holder.scene(key.id) { PhoneModel.scene(key) }
                    let _ = PhoneModel.show(screenImage, inNode: scene.rootNode, fade: fades)
                    SceneView3D(scene: scene, pose: PhoneModel.pose(pointer: sourced ?? pointer))
                }
            }
            .frame(width: width * Self.overscan, height: height * Self.overscan)
        }
        .frame(width: width, height: height)
        .onContinuousHover { phase in
            guard sourced == nil, !reduceMotion else { return }
            switch phase {
            case .active(let location):
                pointer = CGPoint(x: max(-1, min(1, location.x / width * 2 - 1)), y: max(-1, min(1, location.y / height * 2 - 1)))
            case .ended:
                pointer = .zero
            }
        }
        .accessibilityHidden(true)
    }
}

@MainActor
enum PhoneModel {
    struct Key: Hashable {
        var palette: ArtPalette
        var cable: PhoneArt.Cable
        var id: String { "\(palette)|\(cable)|\(AppTheme.current.rawValue)" }
    }

    /// Scene units per point of the old 320 × 340 drawing.
    static let unit: CGFloat = 0.01
    static let display = CGSize(width: 116, height: 238)

    static func pose(pointer: CGPoint) -> SIMD3<Float> {
        SIMD3(Float(-0.06 + pointer.y * 0.125), Float(0.38 + pointer.x * 0.21), 0)
    }

    static func image(_ key: Key, screen: CGImage?, screenKey: String, width: CGFloat) -> NSImage {
        let size = CGSize(width: width * PhoneArt.overscan, height: width * 340 / 320 * PhoneArt.overscan)
        return SceneBaker.image(key: "phone|\(key.id)|\(screenKey)|\(SceneBaker.checkPointer)", points: size) {
            let scene = scene(key)
            show(screen, in: scene)
            if let subject = scene.rootNode.childNode(withName: "subject", recursively: true) {
                let pose = pose(pointer: SceneBaker.checkPointer)
                subject.eulerAngles = SCNVector3(CGFloat(pose.x), CGFloat(pose.y), 0)
            }
            return scene
        }
    }

    /// Puts a screen image on the display (only when it changed).
    @discardableResult
    static func show(_ image: CGImage?, in scene: SCNScene) -> Bool {
        show(image, inNode: scene.rootNode)
    }

    @discardableResult
    static func show(_ image: CGImage?, inNode root: SCNNode, fade: Bool = false) -> Bool {
        guard let image, let display = root.childNode(withName: "display", recursively: true),
              let material = display.geometry?.firstMaterial else { return false }
        let current = material.emission.contents as AnyObject?
        if current === image { return false }
        guard fade, current != nil else {
            material.emission.contents = image
            material.diffuse.contents = image
            return true
        }
        // Dim, change, brighten: the next screen comes up as on a real display.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.13
        material.emission.intensity = 0.12
        SCNTransaction.completionBlock = {
            DispatchQueue.main.async {
                material.emission.contents = image
                material.diffuse.contents = image
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.24
                material.emission.intensity = 1.05
                SCNTransaction.commit()
            }
        }
        SCNTransaction.commit()
        return true
    }

    /// The phone turns, the cable stays where it lies: the phone is "subject" (what the pointer
    /// turns), the cable sits beside it in the scene.
    static func scene(_ key: Key) -> SCNScene {
        let art = SCNNode()
        art.addChildNode(subject(key))
        addCable(key.cable, to: art)
        return Studio.scene(subject: art, visible: 2.95 * PhoneArt.overscan, shadowDepth: 0.5)
    }

    /// Where the drawing sits in the scene (scene units), and the USB port in the drawing's points.
    private static let lift: CGFloat = 0.1
    private static let port = SIMD3<Double>(0, -140, 0)

    /// The phone itself (the node named "subject"), at its resting pose. It turns around its USB
    /// port, so the plug stays in the cable.
    static func subject(_ key: Key) -> SCNNode {
        let colors = key.palette.colors
        let subject = SCNNode()
        subject.name = "subject"
        subject.position = SCNVector3(0, lift + CGFloat(port.y) * unit, 0)
        let pose = pose(pointer: .zero)
        subject.eulerAngles = SCNVector3(CGFloat(pose.x), CGFloat(pose.y), 0)
        let model = SCNNode()
        model.scale = SCNVector3(unit, unit, unit)
        model.position = SCNVector3(0, -CGFloat(port.y) * unit, 0)
        subject.addChildNode(model)

        // The frame: satin metal in the phone's colour.
        let frame = SCNMaterial()
        frame.lightingModel = .physicallyBased
        frame.diffuse.contents = NSColor(colors[1].mix(with: .white, by: 0.15))
        frame.metalness.contents = 0.85
        frame.roughness.contents = 0.28
        // Glass back: deep colour under a lacquer coat.
        let back = Studio.candy(key.palette, dark: true)
        // The black glass around the screen.
        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = NSColor(white: 0.02, alpha: 1)
        glass.metalness.contents = 0.0
        glass.roughness.contents = 0.05
        glass.clearCoat.contents = 1.0
        glass.clearCoatRoughness.contents = 0.02

        // The folded-open second half, behind and to the right.
        let rear = SCNNode(geometry: Studio.slab(roundedRect(CGSize(width: 122, height: 246), radius: 28), depth: 10, bevel: 3.5))
        rear.geometry?.materials = [back, back, frame, frame, frame]
        rear.position = SCNVector3(34, 12, -16)
        model.addChildNode(rear)

        // The front half.
        let body = SCNNode(geometry: Studio.slab(roundedRect(CGSize(width: 126, height: 250), radius: 30), depth: 11, bevel: 3.5))
        body.geometry?.materials = [glass, back, frame, frame, frame]
        model.addChildNode(body)

        // The display: a glowing image under glass.
        let plane = SCNPlane(width: display.width, height: display.height)
        plane.cornerRadius = 24
        let screen = SCNMaterial()
        screen.lightingModel = .physicallyBased
        screen.diffuse.contents = NSColor.black
        screen.emission.intensity = 1.05
        screen.metalness.contents = 0.0
        screen.roughness.contents = 0.04
        screen.clearCoat.contents = 1.0
        screen.clearCoatRoughness.contents = 0.0
        plane.materials = [screen]
        let displayNode = SCNNode(geometry: plane)
        displayNode.name = "display"
        displayNode.position = SCNVector3(0, 0, 5.6)
        model.addChildNode(displayNode)

        // Side buttons.
        for (y, length) in [(58.0, 30.0), (18.0, 20.0)] {
            let button = SCNNode(geometry: SCNBox(width: 3, height: length, length: 5, chamferRadius: 1.4))
            button.geometry?.materials = [frame]
            button.position = SCNVector3(64.2, y, 0)
            model.addChildNode(button)
        }

        if key.cable == .plugged {
            // The plug's moulded end, in the port: it turns with the phone.
            let boot = SCNNode(geometry: Studio.slab(Studio.stadium(width: 20, height: 11), depth: 16, bevel: 3))
            boot.geometry?.materials = [cableMaterial]
            boot.eulerAngles = SCNVector3(-CGFloat.pi / 2, 0, 0)
            boot.position = SCNVector3(0, -133, 0)
            model.addChildNode(boot)
        }
        return subject
    }

    private static var cableMaterial: SCNMaterial { Studio.plastic(NSColor(white: 0.93, alpha: 1), roughness: 0.45) }

    /// A USB-C cable lying in front of the phone: a soft white lead in loose coils, and a plug at the far end with
    /// its oval metal tip toward you. Unplugged, the phone's end lies below the port, its tip
    /// pointing back at it. Built in the drawing's points.
    private static func addCable(_ cable: PhoneArt.Cable, to art: SCNNode) {
        guard cable != .none else { return }
        let node = SCNNode()
        node.scale = SCNVector3(unit, unit, unit)
        node.position = SCNVector3(0, lift, 0)
        art.addChildNode(node)
        let plugged = cable == .plugged
        // The far end: out of the coils toward you, then the plug, its tip turned to you.
        let exit = [SIMD3<Double>(86, -182, 68), SIMD3(100, -179, 84)]
        let path: [SIMD3<Double>]
        if plugged {
            // From inside the plug in the port, down into two loose coils on the table.
            path = [SIMD3(0, -134, 0), SIMD3(0, -152, 2)]
                + coil(center: SIMD3(10, -176, 28), radius: 30, from: .pi, turns: 2.25, spread: 24) + exit
        } else {
            // The pulled plug lies to the left, tip toward the port; its lead runs into the coils.
            let toward = simd_normalize(SIMD3<Double>(0.48, 0.7, 0.53))
            let back = SIMD3<Double>(-40, -160, 30) - plugLength * toward
            node.addChildNode(plug(at: back, toward: toward))
            path = [back, back - 10 * toward, SIMD3(-50, -199, 24), SIMD3(-20, -196, 46)]
                + coil(center: SIMD3(10, -176, 28), radius: 30, from: 1.5 * .pi, turns: 2, spread: 24) + exit
        }
        let curve = spline(path)
        let lead = SCNNode(geometry: Studio.tube(curve, radius: 4))
        lead.geometry?.materials = [cableMaterial]
        node.addChildNode(lead)
        let toward = simd_normalize(exit[1] - exit[0])
        node.addChildNode(plug(at: exit[1], toward: toward))
        // The cable lies on the desk: no shadow on the wall behind the phone, only its own soft
        // shadow on the desk under it.
        node.enumerateHierarchy { child, _ in child.castsShadow = false }
        node.addChildNode(deskShadow(curve + [exit[1] + plugLength * toward]))
        if !plugged {
            // Sparks where it was pulled out.
            let spark = SCNMaterial()
            spark.lightingModel = .constant
            spark.diffuse.contents = NSColor(red: 1, green: 0.78, blue: 0.45, alpha: 1)
            for (x, y, angle) in [(-24.0, -141.0, 0.9), (-10.0, -134.0, -0.3), (-36.0, -150.0, 1.6)] {
                let line = SCNNode(geometry: SCNCapsule(capRadius: 1.8, height: 14))
                line.geometry?.materials = [spark]
                line.position = SCNVector3(x, y, 20)
                line.eulerAngles = SCNVector3(0, 0, angle)
                node.addChildNode(line)
            }
        }
    }

    /// The desk the cable lies on: the plane the coils lie in, at the cable's underside.
    private static let lean = 0.55
    private static let deskAcross = SIMD3<Double>(0, sin(lean), -cos(lean))
    private static let deskUp = SIMD3<Double>(0, cos(lean), sin(lean))
    private static let deskOrigin = SIMD3<Double>(10, -176, 28) - 4 * deskUp

    /// A contact shadow: the cable's path drawn soft and dark on the desk where it touches it,
    /// fading out where the cable rises off it (up to the phone).
    private static func deskShadow(_ points: [SIMD3<Double>]) -> SCNNode {
        let flat = points.map { point -> SIMD3<Double> in
            let offset = point - deskOrigin
            return SIMD3(offset.x, simd_dot(offset, deskAcross), simd_dot(offset, deskUp) - 4)
        }
        let margin = 24.0
        let minU = flat.map(\.x).min()! - margin, maxU = flat.map(\.x).max()! + margin
        let minV = flat.map(\.y).min()! - margin, maxV = flat.map(\.y).max()! + margin
        let scale = 6.0
        let width = Int((maxU - minU) * scale), height = Int((maxV - minV) * scale)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setLineCap(.round)
        context.setLineWidth(9 * scale)
        for index in 0..<(flat.count - 1) {
            let a = flat[index], b = flat[index + 1]
            let rise = max(0, (a.z + b.z) / 2)
            let strength = max(0, 1 - rise / 16)
            guard strength > 0 else { continue }
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.32 * strength))
            context.move(to: CGPoint(x: (a.x - minU) * scale, y: (a.y - minV) * scale))
            context.addLine(to: CGPoint(x: (b.x - minU) * scale, y: (b.y - minV) * scale))
            context.strokePath()
        }
        var image = context.makeImage()!
        let blurred = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: 4 * scale)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        if let soft = CIContext().createCGImage(blurred, from: blurred.extent) { image = soft }

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.writesToDepthBuffer = false
        material.blendMode = .alpha
        let plane = SCNPlane(width: maxU - minU, height: maxV - minV)
        plane.materials = [material]
        let shadow = SCNNode(geometry: plane)
        shadow.castsShadow = false
        // The plane's face turned up to the desk's normal; its height runs along the desk.
        shadow.eulerAngles = SCNVector3(-(CGFloat.pi / 2 - CGFloat(lean)), 0, 0)
        let centre = deskOrigin + SIMD3((minU + maxU) / 2, 0, 0) + (minV + maxV) / 2 * deskAcross
        shadow.position = SCNVector3(centre.x, centre.y, centre.z)
        return shadow
    }

    /// Loops of cable lying on the table (a plane leaning back from you), each a little to the
    /// right of the last and lying on top of it, as a real coil does. Angle 3π/2 is the loop's
    /// front, moving right.
    private static func coil(center: SIMD3<Double>, radius: Double, from start: Double, turns: Double, spread: Double) -> [SIMD3<Double>] {
        let across = deskAcross, up = deskUp
        let step = Double.pi / 4
        return (0...Int((turns * 2 * .pi / step).rounded())).map { index in
            let angle = start + Double(index) * step, turn = (angle - start) / (2 * .pi)
            return center + SIMD3(spread * turn + radius * cos(angle), 0, 0) + radius * sin(angle) * across + 6 * turn * up
        }
    }

    /// A smooth curve through `points` (centripetal Catmull-Rom: no kinks or overshoot where
    /// points bunch up).
    private static func spline(_ points: [SIMD3<Double>], samples: Int = 12) -> [SIMD3<Double>] {
        let p = [2 * points[0] - points[1]] + points + [2 * points[points.count - 1] - points[points.count - 2]]
        func knot(_ t: Double, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { t + max(simd_distance(a, b).squareRoot(), 1e-6) }
        var result: [SIMD3<Double>] = []
        for i in 1..<(p.count - 2) {
            let p0 = p[i - 1], p1 = p[i], p2 = p[i + 1], p3 = p[i + 2]
            let t0 = 0.0, t1 = knot(t0, p0, p1), t2 = knot(t1, p1, p2), t3 = knot(t2, p2, p3)
            for sample in 0..<samples {
                let t = t1 + (t2 - t1) * Double(sample) / Double(samples)
                let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
                let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
                let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3
                let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
                let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3
                result.append((t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2)
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// From the plug's back (where the lead goes in) to its metal tip.
    private static let plugLength = 36.0

    /// A USB-C plug: a moulded body with round ends, then the thin oval metal shell with its dark
    /// opening. `back` is where the lead enters; the plug points along `toward`, lying flat.
    private static func plug(at back: SIMD3<Double>, toward: SIMD3<Double>) -> SCNNode {
        let plug = SCNNode()
        plug.position = SCNVector3(back.x, back.y, back.z)
        let ahead = back + toward
        plug.look(at: SCNVector3(ahead.x, ahead.y, ahead.z), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, 1))

        let body = SCNNode(geometry: Studio.slab(Studio.stadium(width: 20, height: 11), depth: 26, bevel: 3.5))
        body.geometry?.materials = [cableMaterial]
        body.position = SCNVector3(0, 0, 10)
        plug.addChildNode(body)

        let shell = SCNNode(geometry: Studio.slab(Studio.stadium(width: 12.5, height: 5.2), depth: 13, bevel: 1.1))
        shell.geometry?.materials = [Studio.metal(0.82, roughness: 0.18)]
        shell.position = SCNVector3(0, 0, plugLength - 6.5)
        plug.addChildNode(shell)

        // The opening: dark inside, with the contacts' pale strip.
        let inside = SCNMaterial()
        inside.lightingModel = .physicallyBased
        inside.diffuse.contents = NSColor(white: 0.03, alpha: 1)
        inside.roughness.contents = 0.7
        let opening = SCNNode(geometry: Studio.slab(Studio.stadium(width: 10, height: 2.9), depth: 0.6, bevel: 0.25))
        opening.geometry?.materials = [inside]
        opening.position = SCNVector3(0, 0, plugLength + 0.05)
        plug.addChildNode(opening)
        let contacts = SCNNode(geometry: SCNBox(width: 6.6, height: 0.7, length: 0.4, chamferRadius: 0.2))
        contacts.geometry?.materials = [Studio.metal(0.7, roughness: 0.3)]
        contacts.position = SCNVector3(0, 0, plugLength + 0.3)
        plug.addChildNode(contacts)
        return plug
    }

    private static func roundedRect(_ size: CGSize, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(cgPath: RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)).cgPath)
    }

    // MARK: Screen

    private static var screens: [String: CGImage] = [:]

    /// The display's picture, drawn at three times its size.
    static func screenImage(palette: ArtPalette, screen: PhoneArt.Screen, reveal: Double) -> CGImage? {
        let step = Int((min(max(reveal, 0), 1) * 15).rounded())
        let key = "\(palette)|\(screen)|\(step)|\(AppTheme.current.rawValue)"
        if let cached = screens[key] { return cached }
        let renderer = ImageRenderer(content: PhoneScreen(palette: palette, screen: screen, reveal: Double(step) / 15)
            .frame(width: display.width, height: display.height))
        renderer.scale = 3
        let image = renderer.cgImage
        screens[key] = image
        return image
    }
}

/// What the phone's display shows: a wallpaper, and photos lighting up, a request to allow
/// access, a pause or a tick.
private struct PhoneScreen: View {
    var palette: ArtPalette
    var screen: PhoneArt.Screen
    var reveal: Double

    var body: some View {
        let colors = palette.colors
        ZStack(alignment: .top) {
            // Wallpaper: deep colour with soft light from the top.
            LinearGradient(colors: [Color(hex: 0x0B1F2C), Color(hex: 0x050B12)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [colors[1].opacity(0.55), .clear], center: UnitPoint(x: 0.2, y: 0.05), startRadius: 0, endRadius: 170)
            RadialGradient(colors: [Color(hex: 0x6B4BE0).opacity(0.35), .clear], center: UnitPoint(x: 1, y: 0.95), startRadius: 0, endRadius: 150)
            statusBar
            switch screen {
            case .photos: gallery
            case .notify: request
            case .unlock: lockScreen
            case .allow: allowDialog
            case .shade(let shade): notifications(shade)
            case .usb(let usb): usbOptions(usb)
            case .pause: symbol("pause.fill", Color(hex: 0xFFD58A))
            case .check: symbol("checkmark", .white, circle: Color(hex: 0x46C96A))
            case .blank: EmptyView()
            }
            // The front camera.
            Circle().fill(.black).frame(width: 7, height: 7).padding(.top, 7)
        }
        .frame(width: PhoneModel.display.width, height: PhoneModel.display.height)
    }

    /// A fingertip: where to touch.
    private func finger(_ size: CGFloat = 18) -> some View {
        ZStack {
            Circle().fill(Color.accent.opacity(0.22)).frame(width: size * 1.7, height: size * 1.7)
            Circle().fill(Color.accent.opacity(0.6)).frame(width: size, height: size)
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.2))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
        }
        .allowsHitTesting(false)
    }

    /// A swipe: a fading trail with the fingertip at its end.
    private func swipe(down: Bool, length: CGFloat) -> some View {
        VStack(spacing: 0) {
            if down {
                Capsule().fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 10, height: length)
                finger(20).padding(.top, -12)
            } else {
                finger(20).padding(.bottom, -12).zIndex(1)
                Capsule().fill(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 10, height: length)
            }
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 3) {
            Text("9:41").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white).padding(.top, 30)
            Text("Saturday 27 September").font(.system(size: 7, weight: .medium)).foregroundStyle(.white.opacity(0.8))
            Spacer()
            swipe(down: false, length: 46)
            Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.9)).padding(.top, 8)
            Text("Swipe up to unlock").font(.system(size: 6.5, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 14)
        }
    }

    private var allowDialog: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow access to phone data?").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.black)
                Text("The connected device will be able to access data on this phone.")
                    .font(.system(size: 6.5)).foregroundStyle(.black.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Text("Deny").font(.system(size: 7.5, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
                    Text("Allow").font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.accentDeep)
                        .padding(.leading, 12)
                        .overlay(alignment: .bottomTrailing) { finger(16).offset(x: 12, y: 12) }
                }
                .padding(.top, 4)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
            .padding(.horizontal, 8)
        }
    }

    private func notifications(_ shade: PhoneArt.ShadeScreen) -> some View {
        ZStack(alignment: .top) {
            Color.black.opacity(shade.tapping ? 0.62 : 0.45)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("9:41").font(.system(size: 10, weight: .bold))
                    Text("Sat 27 Sep").font(.system(size: 6.5, weight: .medium)).opacity(0.75)
                    Spacer()
                }
                .foregroundStyle(.white)
                HStack(spacing: 6) {
                    ForEach(Array(["wifi", "antenna.radiowaves.left.and.right", "flashlight.off.fill", "airplane"].enumerated()), id: \.offset) { index, symbol in
                        Image(systemName: symbol).font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(index == 0 ? .black : .white)
                            .frame(width: 21, height: 21)
                            .background(Circle().fill(index == 0 ? Color.accent : .white.opacity(0.18)))
                    }
                }
                Capsule().fill(.white.opacity(0.2)).frame(height: 5)
                    .overlay(alignment: .leading) { Capsule().fill(.white.opacity(0.85)).frame(width: 60, height: 5) }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "cable.connector").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 15, height: 15).background(Circle().fill(Color(hex: 0x3F8CF0)))
                    VStack(alignment: .leading, spacing: 1.5) {
                        Text("Android System · now").font(.system(size: 5.5, weight: .medium)).foregroundStyle(.black.opacity(0.5))
                        Text(shade.title).font(.system(size: 7.5, weight: .bold)).foregroundStyle(.black).lineLimit(2)
                        Text(shade.detail).font(.system(size: 6.5)).foregroundStyle(.black.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.white.opacity(0.95)))
                .overlay(alignment: .trailing) { if shade.tapping { finger(18).offset(x: -6, y: 6) } }
                .scaleEffect(shade.tapping ? 0.97 : 1)
            }
            .padding(.horizontal, 9).padding(.top, 20)
            if !shade.tapping {
                // From the top edge, down the right-hand side (clear of the words).
                swipe(down: true, length: 84).padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 14)
            }
        }
    }

    private func usbOptions(_ usb: PhoneArt.USBScreen) -> some View {
        ZStack(alignment: .top) {
            Color(hex: 0x0E1318)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold))
                    Text(usb.title).font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.bottom, 10)
                Text(usb.heading).font(.system(size: 6.5, weight: .semibold)).foregroundStyle(Color.accent)
                    .padding(.bottom, 4)
                ForEach(Array(usb.options.enumerated()), id: \.offset) { index, option in
                    let on = index == usb.selected
                    HStack(spacing: 7) {
                        ZStack {
                            Circle().strokeBorder(on ? Color.accent : .white.opacity(0.5), lineWidth: 1.2).frame(width: 10, height: 10)
                            if on { Circle().fill(Color.accent).frame(width: 5, height: 5) }
                        }
                        Text(option).font(.system(size: 7.5, weight: on ? .semibold : .regular)).foregroundStyle(.white.opacity(on ? 1 : 0.8))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accent.opacity(0.16) : .clear))
                    .overlay(alignment: .trailing) { if on { finger(16).offset(x: 2, y: 6) } }
                }
            }
            .padding(.horizontal, 10).padding(.top, 22)
        }
    }

    private var statusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 7.5, weight: .semibold))
            Spacer()
            HStack(spacing: 2) {
                Image(systemName: "wifi")
                Image(systemName: "battery.75")
            }
            .font(.system(size: 6.5, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12).padding(.top, 6)
    }

    /// A photo grid; each tile a tiny landscape, lit in turn as `reveal` grows.
    private var gallery: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Photos").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
            Text("Today").font(.system(size: 6.5, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(31), spacing: 3), count: 3), spacing: 3) {
                ForEach(0..<15, id: \.self) { index in
                    Landscape(seed: index)
                        .frame(width: 31, height: 31)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .opacity(Double(index) / 15 < reveal ? 1 : 0.14)
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var request: some View {
        VStack(spacing: 10) {
            Text("9:41").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white).padding(.top, 26)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "cable.connector").font(.system(size: 6.5, weight: .bold))
                    Text("USB").font(.system(size: 6, weight: .semibold))
                }
                .foregroundStyle(.black.opacity(0.55))
                Text("Allow access to phone data?").font(.system(size: 7.5, weight: .bold)).foregroundStyle(.black)
                HStack(spacing: 5) {
                    Text("Allow").font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 13)
                        .background(Capsule().fill(Color.accent))
                    Text("Deny").font(.system(size: 6.5, weight: .semibold)).foregroundStyle(.black.opacity(0.6))
                        .frame(maxWidth: .infinity).frame(height: 13)
                        .background(Capsule().fill(.black.opacity(0.08)))
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.95)))
            .padding(.horizontal, 8)
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 22)
        }
    }

    private func symbol(_ name: String, _ color: Color, circle: Color? = nil) -> some View {
        ZStack {
            if let circle { Circle().fill(circle).frame(width: 64, height: 64).shadow(color: circle.opacity(0.7), radius: 12) }
            Image(systemName: name).font(.system(size: circle == nil ? 44 : 30, weight: .heavy)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A tiny made-up photo: sky, sun and hills in one of a few moods.
private struct Landscape: View {
    var seed: Int

    var body: some View {
        let moods: [(sky: [UInt32], hill: [UInt32], sun: UInt32)] = [
            ([0xFFB36B, 0xFF7A8A], [0x6B3A7A, 0x3A1F4F], 0xFFF1C2),
            ([0x7FD6FF, 0xC9F0FF], [0x3F9A5A, 0x236B3C], 0xFFFFFF),
            ([0x2A2F7A, 0x9A6BD9], [0x1B1F4A, 0x0E1030], 0xFFE9A8),
            ([0x9BE7D8, 0xFFE3B3], [0x2F8C86, 0x17605C], 0xFFFFFF),
            ([0xFF9A6B, 0xFFD18F], [0xB0503A, 0x6E2A22], 0xFFF6D9),
            ([0x6BB8FF, 0xA9E1FF], [0x3A6FB8, 0x1F3F7A], 0xFFFFFF),
        ]
        let mood = moods[(seed * 7 + 3) % moods.count]
        let sunX = [0.25, 0.7, 0.5, 0.8, 0.35][seed % 5]
        return Canvas { context, size in
            let w = size.width, h = size.height
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: mood.sky.map { Color(hex: $0) }), startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            context.fill(Path(ellipseIn: CGRect(x: w * sunX - 4, y: h * 0.28, width: 8, height: 8)), with: .color(Color(hex: mood.sun)))
            var far = Path()
            far.move(to: CGPoint(x: 0, y: h * 0.72))
            far.addQuadCurve(to: CGPoint(x: w, y: h * 0.6), control: CGPoint(x: w * 0.45, y: h * (0.35 + Double(seed % 3) * 0.08)))
            far.addLine(to: CGPoint(x: w, y: h)); far.addLine(to: CGPoint(x: 0, y: h)); far.closeSubpath()
            context.fill(far, with: .color(Color(hex: mood.hill[0])))
            var near = Path()
            near.move(to: CGPoint(x: 0, y: h * 0.85))
            near.addQuadCurve(to: CGPoint(x: w, y: h * 0.8), control: CGPoint(x: w * 0.7, y: h * 0.62))
            near.addLine(to: CGPoint(x: w, y: h)); near.addLine(to: CGPoint(x: 0, y: h)); near.closeSubpath()
            context.fill(near, with: .color(Color(hex: mood.hill[1])))
        }
    }
}
