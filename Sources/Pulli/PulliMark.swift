import AppKit
import SceneKit
import SwiftUI

// Pulli's mark (owner request, 2026-10-14): a pulley wheel with its rope hanging from the left
// edge, which reads as a lowercase "p" (the wheel is the bowl, the rope the stem), and the rope
// ends in a down arrow: pulled down to your Mac. The app icon is the mark in 3D; the menu bar
// shows it as a template glyph.

/// The menu bar glyph, drawn as a template image (macOS tints it for the menu bar).
@MainActor
enum PulliGlyph {
    enum State: Hashable { case idle, copying, paused }

    private static var cache: [State: NSImage] = [:]

    static func image(_ state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // The wheel (the bowl of the p), with its rope over it.
            let wheel = NSBezierPath(ovalIn: NSRect(x: 6.4, y: 1.6, width: 10, height: 10))
            wheel.lineWidth = 1.7
            wheel.stroke()
            // The rope down the left side (the stem of the p), ending in an arrow.
            let rope = NSBezierPath()
            rope.move(to: NSPoint(x: 6.4, y: 6.6))
            rope.line(to: NSPoint(x: 6.4, y: 16.2))
            rope.lineWidth = 1.7
            rope.lineCapStyle = .round
            rope.stroke()
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 3.6, y: 13.4))
            arrow.line(to: NSPoint(x: 6.4, y: 16.4))
            arrow.line(to: NSPoint(x: 9.2, y: 13.4))
            arrow.lineWidth = 1.7
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            // The axle: a dot, or two bars while paused.
            switch state {
            case .paused:
                NSBezierPath(roundedRect: NSRect(x: 9.6, y: 4.4, width: 1.5, height: 4.4), xRadius: 0.75, yRadius: 0.75).fill()
                NSBezierPath(roundedRect: NSRect(x: 12.0, y: 4.4, width: 1.5, height: 4.4), xRadius: 0.75, yRadius: 0.75).fill()
            case .idle, .copying:
                NSBezierPath(ovalIn: NSRect(x: 9.9, y: 5.1, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pulli"
        cache[state] = image
        return image
    }
}

/// The app icon's art: the mark as a 3D object in the studio, glossy ink-blue wheel, soft white
/// rope, a milk-white hub, seen a little from the side.
@MainActor
enum PulliIcon {
    static func image(side: CGFloat) -> NSImage {
        SceneBaker.image(key: "pulli-icon|\(AppTheme.current.rawValue)", points: CGSize(width: side, height: side), scale: 1) {
            Studio.scene(subject: subject(), visible: 3.9, shadowDepth: 0.45)
        }
    }

    static func subject() -> SCNNode {
        let group = SCNNode()
        group.name = "subject"
        group.eulerAngles = SCNVector3(-0.14, 0.34, 0)

        let ink = Studio.candy(.blue)
        ink.diffuse.contents = Studio.gradientImage([Color(hex: 0x7C93F7), Color(hex: 0x3557E0), Color(hex: 0x1C35A8)])
        ink.emission.contents = NSColor(red: 0.05, green: 0.08, blue: 0.25, alpha: 1)
        let rope = Studio.plastic(NSColor(white: 0.96, alpha: 1), roughness: 0.42)

        // Built in points (100 = 1 unit), like the other models.
        let model = SCNNode()
        model.scale = SCNVector3(0.01, 0.01, 0.01)
        model.position = SCNVector3(0.22, 0.12, 0)
        group.addChildNode(model)

        let centre = SIMD3<Double>(30, 48, 0)
        let radius = 84.0

        // The wheel: a thick rounded disc.
        let wheel = SCNNode(geometry: Studio.slab(NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)),
                                                  depth: 46, bevel: 14))
        wheel.geometry?.materials = [ink, ink, ink, ink, ink]
        wheel.position = SCNVector3(centre.x, centre.y, centre.z)
        model.addChildNode(wheel)

        // The hub: a milk-white cap with a blue axle.
        let hub = SCNNode(geometry: Studio.slab(NSBezierPath(ovalIn: NSRect(x: -30, y: -30, width: 60, height: 60)), depth: 14, bevel: 6))
        hub.geometry?.materials = [Studio.milk()]
        hub.position = SCNVector3(centre.x, centre.y, 27)
        model.addChildNode(hub)
        let axle = SCNNode(geometry: Studio.slab(NSBezierPath(ovalIn: NSRect(x: -11, y: -11, width: 22, height: 22)), depth: 8, bevel: 3.5))
        axle.geometry?.materials = [ink]
        axle.position = SCNVector3(centre.x, centre.y, 36)
        model.addChildNode(axle)

        // The rope: a seamless ring in the wheel's groove, and the hanging end down the left
        // side, starting inside the ring so no cut end shows.
        let ropeRadius = 9.0
        let ring = SCNTorus(ringRadius: radius + 2, pipeRadius: ropeRadius)
        ring.ringSegmentCount = 160
        ring.pipeSegmentCount = 32
        ring.materials = [rope]
        let ringNode = SCNNode(geometry: ring)
        ringNode.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        ringNode.position = SCNVector3(centre.x, centre.y, centre.z)
        model.addChildNode(ringNode)
        let drop = 150.0
        let stem: [SIMD3<Double>] = (0...40).map { step in
            SIMD3(centre.x - radius - 2, centre.y - Double(step) / 40 * drop, 0)
        }
        let ropeNode = SCNNode(geometry: Studio.tube(stem, radius: ropeRadius))
        ropeNode.geometry?.materials = [rope]
        model.addChildNode(ropeNode)

        // The arrow at the rope's end: pulled down to your Mac. Thick and round, like the wheel.
        let tip = SIMD3<Double>(centre.x - radius - 2, centre.y - drop, 0)
        // A smooth cone: from the front a triangle pointing down, round from every side.
        let cone = SCNCone(topRadius: 4, bottomRadius: 46, height: 62)
        cone.radialSegmentCount = 96
        cone.materials = [ink]
        let arrow = SCNNode(geometry: cone)
        arrow.eulerAngles = SCNVector3(CGFloat.pi, 0, 0)  // the point downwards
        arrow.position = SCNVector3(tip.x, tip.y - 24, tip.z)
        model.addChildNode(arrow)
        // A rounded rim on the cone's flat top, so its edge catches the light softly.
        let lip = SCNTorus(ringRadius: 42, pipeRadius: 5)
        lip.ringSegmentCount = 96
        lip.materials = [ink]
        let lipNode = SCNNode(geometry: lip)
        lipNode.position = SCNVector3(tip.x, tip.y - 24 + 31 - 5, tip.z)
        model.addChildNode(lipNode)
        return group
    }
}
