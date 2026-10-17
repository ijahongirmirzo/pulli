import AppKit
import CoreImage
import SceneKit
import SwiftUI
import Vision

// Pulli's art as real 3D objects (SceneKit): extruded shapes with rounded bevels, physically based
// materials lit by a photographic studio (soft boxes, a rim light, a key light casting a soft
// shadow onto an invisible backdrop). Big pieces are live views that turn toward the pointer;
// small ones, and screen snapshots, are rendered once to images.

/// The shared studio: lighting environment, lights, camera and the shadow catcher.
@MainActor
enum Studio {
    /// What reflective surfaces see: a dim room with a big soft box overhead, strip lights at the
    /// sides and a light desk below. Blurred, as real soft boxes read in reflections.
    static let environment: CGImage = {
        let width = 1024, height = 512
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Flipped so y runs from the top (the sky) down.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // The floor is a light desk, not a dark room: edges seen at a glancing angle mirror the
        // floor, and a dark one drew a grey outline round every object on light backgrounds.
        let colors = [CGColor(gray: 0.36, alpha: 1), CGColor(gray: 0.24, alpha: 1), CGColor(red: 0.42, green: 0.41, blue: 0.39, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        func box(_ rect: CGRect, _ white: CGFloat) {
            context.setFillColor(CGColor(gray: white, alpha: 1))
            context.addPath(CGPath(roundedRect: rect, cornerWidth: min(rect.width, rect.height) * 0.3, cornerHeight: min(rect.width, rect.height) * 0.3, transform: nil))
            context.fillPath()
        }
        // Overhead soft boxes (all around, so every tilt catches one).
        box(CGRect(x: 0, y: 18, width: 1024, height: 70), 1.0)
        box(CGRect(x: 300, y: 70, width: 420, height: 90), 1.0)
        // Strip lights left and right of the camera, and behind.
        box(CGRect(x: 150, y: 150, width: 46, height: 170), 0.85)
        box(CGRect(x: 830, y: 150, width: 46, height: 170), 0.7)
        box(CGRect(x: 480, y: 170, width: 70, height: 110), 0.55)
        let sharp = context.makeImage()!
        let blurred = CIImage(cgImage: sharp).clampedToExtent().applyingGaussianBlur(sigma: 10).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return CIContext().createCGImage(blurred, from: blurred.extent) ?? sharp
    }()

    /// A scene with the studio set up around `subject`, seen by a long lens from the front.
    /// `visible` is the height of the view in scene units.
    static func scene(subject: SCNNode, visible: CGFloat, shadowDepth: Float = 0.35) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = environment
        scene.lightingEnvironment.intensity = 1.35
        scene.rootNode.addChildNode(subject)

        let camera = SCNCamera()
        camera.fieldOfView = 18
        camera.zNear = 0.1
        camera.zFar = 40
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.1
        camera.bloomIntensity = 0.25
        camera.bloomThreshold = 0.92
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, visible / (2 * tan(CGFloat(9) * .pi / 180)))
        scene.rootNode.addChildNode(cameraNode)

        // Key light from the top left, in front: soft shadow down and to the right.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 900
        key.castsShadow = true
        key.shadowMode = .deferred
        key.shadowRadius = 14
        key.shadowSampleCount = 24
        key.shadowColor = NSColor(white: 0, alpha: 0.5)
        key.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.orthographicScale = Double(visible)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.5, -0.45, 0)
        scene.rootNode.addChildNode(keyNode)

        // Cool rim light from behind right: a bright edge on the bevels.
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 450
        rim.color = NSColor(red: 0.8, green: 0.9, blue: 1, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(0.2, 2.5, 0)
        scene.rootNode.addChildNode(rimNode)

        // An invisible backdrop that only shows the shadow.
        let backdrop = SCNPlane(width: visible * 4, height: visible * 4)
        let catcher = SCNMaterial()
        catcher.lightingModel = .shadowOnly
        catcher.writesToDepthBuffer = true
        backdrop.materials = [catcher]
        let backdropNode = SCNNode(geometry: backdrop)
        backdropNode.position = SCNVector3(0, 0, -CGFloat(shadowDepth))
        backdropNode.castsShadow = false
        scene.rootNode.addChildNode(backdropNode)
        return scene
    }

    /// A shape extruded with rounded bevels on both faces. Paths are in points (100 = 1 unit).
    /// Elements, as SCNShape's: front, back, side, front bevel, back bevel.
    static func slab(_ path: NSBezierPath, depth: CGFloat, bevel: CGFloat) -> SCNGeometry {
        if let outline = convexOutline(path), let mesh = roundedSlab(outline, depth: Double(depth), bevel: Double(bevel)) { return mesh }
        // Symbols (holes, inward curves): SceneKit's own extrusion.
        path.flatness = 0.03
        let shape = SCNShape(path: path, extrusionDepth: depth)
        shape.chamferRadius = bevel
        shape.chamferMode = .both
        shape.chamferProfile = roundedProfile
        return shape
    }

    /// One closed convex outline, evenly resampled and counter-clockwise; nil for anything else.
    private static func convexOutline(_ path: NSBezierPath) -> [SIMD2<Double>]? {
        // Curves sampled finely here (NSBezierPath's own flattening is coarse at this size).
        var points: [SIMD2<Double>] = [], subpaths = 0
        var element = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            switch path.element(at: index, associatedPoints: &element) {
            case .moveTo: subpaths += 1; points.append(SIMD2(element[0].x, element[0].y))
            case .lineTo: points.append(SIMD2(element[0].x, element[0].y))
            case .cubicCurveTo, .curveTo:
                guard let start = points.last else { break }
                let c1 = SIMD2<Double>(element[0].x, element[0].y), c2 = SIMD2<Double>(element[1].x, element[1].y), end = SIMD2<Double>(element[2].x, element[2].y)
                for step in 1...48 {
                    let t = Double(step) / 48, u = 1 - t
                    points.append(u * u * u * start + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * end)
                }
            case .quadraticCurveTo:
                guard let start = points.last else { break }
                let control = SIMD2<Double>(element[0].x, element[0].y), end = SIMD2<Double>(element[1].x, element[1].y)
                for step in 1...32 {
                    let t = Double(step) / 32, u = 1 - t
                    points.append(u * u * start + 2 * u * t * control + t * t * end)
                }
            default: break
            }
        }
        guard subpaths == 1, points.count > 2 else { return nil }
        if let last = points.last, simd_distance(last, points[0]) < 1e-6 { points.removeLast() }
        var area = 0.0
        for i in points.indices { let a = points[i], b = points[(i + 1) % points.count]; area += a.x * b.y - b.x * a.y }
        if area < 0 { points.reverse() }
        // Resample evenly, about every half point (and at least 160 around).
        var perimeter = 0.0
        for i in points.indices { perimeter += simd_distance(points[i], points[(i + 1) % points.count]) }
        let count = max(160, min(900, Int(perimeter / 0.5)))
        let step = perimeter / Double(count)
        var result: [SIMD2<Double>] = [], walked = 0.0, next = 0.0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], length = simd_distance(a, b)
            while next <= walked + length, result.count < count, length > 0 {
                result.append(a + (b - a) * ((next - walked) / length))
                next += step
            }
            walked += length
        }
        // Convex: every turn the same way (tiny wobbles along straight edges allowed).
        for i in result.indices {
            let a = result[i], b = result[(i + 1) % result.count], c = result[(i + 2) % result.count]
            let turn = (b - a).x * (c - b).y - (b - a).y * (c - b).x
            if turn < -1e-3 * step * step { return nil }
        }
        return result
    }

    /// A slab with round edges as one smooth surface: the face curves over into the bevel and
    /// down the side with no seam, since every ring shares its normals with its neighbours.
    /// (SCNShape builds its bevels as separate pieces, and the joins show as creases.)
    private static func roundedSlab(_ outline: [SIMD2<Double>], depth: Double, bevel: Double) -> SCNGeometry? {
        let n = outline.count
        let bevel = min(bevel, depth / 2)
        // Outward normals, from the neighbours on either side.
        let normals: [SIMD2<Double>] = (0..<n).map { i in
            let t = outline[(i + 1) % n] - outline[(i - 1 + n) % n]
            return simd_normalize(SIMD2(t.y, -t.x))
        }
        let minimum = outline.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, $1) }
        let maximum = outline.reduce(SIMD2(-Double.infinity, -.infinity)) { simd_max($0, $1) }
        let span = simd_max(maximum - minimum, SIMD2(1e-6, 1e-6))
        var vertices: [SCNVector3] = [], vertexNormals: [SCNVector3] = [], uvs: [CGPoint] = []
        func add(_ p: SIMD3<Double>, _ normal: SIMD3<Double>) {
            vertices.append(SCNVector3(p.x, p.y, p.z))
            vertexNormals.append(SCNVector3(normal.x, normal.y, normal.z))
            uvs.append(CGPoint(x: (p.x - minimum.x) / span.x, y: 1 - (p.y - minimum.y) / span.y))
        }
        /// A ring around the outline: pulled in by `inset`, at height `z`, facing `normal`
        /// (its outward part along the outline's normal).
        func ring(inset: Double, z: Double, outward: Double, up: Double) -> Int32 {
            let start = Int32(vertices.count)
            for i in 0..<n {
                let p = outline[i] - inset * normals[i]
                add(SIMD3(p.x, p.y, z), simd_normalize(SIMD3(normals[i].x * outward, normals[i].y * outward, up)))
            }
            return start
        }
        func band(_ a: Int32, _ b: Int32, into indices: inout [Int32]) {
            for i in 0..<Int32(n) {
                let j = (i + 1) % Int32(n)
                indices += [a + i, b + i, a + j, a + j, b + i, b + j]
            }
        }
        let half = depth / 2, steps = 14
        // The bevels: a quarter circle from the face (facing out of it) to the side (facing out).
        var front: [Int32] = [], back: [Int32] = []
        for step in 0...steps {
            let angle = Double(step) / Double(steps) * .pi / 2
            front.append(ring(inset: bevel * (1 - sin(angle)), z: half - bevel * (1 - cos(angle)), outward: sin(angle), up: cos(angle)))
            back.append(ring(inset: bevel * (1 - sin(angle)), z: -half + bevel * (1 - cos(angle)), outward: sin(angle), up: -cos(angle)))
        }
        var frontBevel: [Int32] = [], backBevel: [Int32] = [], side: [Int32] = [], frontFace: [Int32] = [], backFace: [Int32] = []
        for step in 0..<steps {
            band(front[step], front[step + 1], into: &frontBevel)
            band(back[step + 1], back[step], into: &backBevel)
        }
        band(front[steps], back[steps], into: &side)
        // The flat faces: fans from the middle (the outline is convex).
        let middle = outline.reduce(SIMD2<Double>.zero, +) / Double(n)
        let frontMiddle = Int32(vertices.count); add(SIMD3(middle.x, middle.y, half), SIMD3(0, 0, 1))
        let backMiddle = Int32(vertices.count); add(SIMD3(middle.x, middle.y, -half), SIMD3(0, 0, -1))
        for i in 0..<Int32(n) {
            let j = (i + 1) % Int32(n)
            frontFace += [frontMiddle, front[0] + i, front[0] + j]
            backFace += [backMiddle, back[0] + j, back[0] + i]
        }
        // Each triangle faces the way its corners' normals do (outward).
        func outward(_ indices: [Int32]) -> [Int32] {
            var result = indices
            for t in stride(from: 0, to: result.count, by: 3) {
                let a = vertices[Int(result[t])], b = vertices[Int(result[t + 1])], c = vertices[Int(result[t + 2])]
                let ab = SIMD3(Double(b.x - a.x), Double(b.y - a.y), Double(b.z - a.z))
                let ac = SIMD3(Double(c.x - a.x), Double(c.y - a.y), Double(c.z - a.z))
                let na = vertexNormals[Int(result[t])], nb = vertexNormals[Int(result[t + 1])], nc = vertexNormals[Int(result[t + 2])]
                let normal = SIMD3(Double(na.x + nb.x + nc.x), Double(na.y + nb.y + nc.y), Double(na.z + nb.z + nc.z))
                if simd_dot(simd_cross(ab, ac), normal) < 0 { result.swapAt(t + 1, t + 2) }
            }
            return result
        }
        let elements = [frontFace, backFace, side, frontBevel, backBevel].map {
            SCNGeometryElement(indices: outward($0), primitiveType: .triangles)
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: vertexNormals),
                                     SCNGeometrySource(textureCoordinates: uvs)], elements: elements)
    }

    /// A quarter circle: bevels that are round, like moulded glass, not cut flat.
    static let roundedProfile: NSBezierPath = {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 1))
        path.curve(to: NSPoint(x: 1, y: 0), controlPoint1: NSPoint(x: 0.56, y: 1), controlPoint2: NSPoint(x: 1, y: 0.56))
        path.flatness = 0.002
        return path
    }()

    /// Glossy coloured "candy glass": a lacquer coat over colour that runs light to dark.
    static func candy(_ palette: ArtPalette, dark: Bool = false) -> SCNMaterial {
        let colors = palette.colors
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = gradientImage(dark ? [colors[1], colors[2], colors[2].mix(with: .black, by: 0.35)] : [colors[0], colors[1], colors[2]])
        material.metalness.contents = 0.0
        material.roughness.contents = 0.22
        material.clearCoat.contents = 1.0
        material.clearCoatRoughness.contents = 0.04
        material.emission.contents = NSColor(colors[1]).withAlphaComponent(1).blended(withFraction: 0.82, of: .black)
        return material
    }

    /// Milky white, as frosted acrylic.
    static func milk(tint: Color? = nil) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = tint.map { NSColor($0) } ?? NSColor(white: 0.97, alpha: 1)
        material.metalness.contents = 0.0
        material.roughness.contents = 0.3
        material.clearCoat.contents = 0.6
        material.clearCoatRoughness.contents = 0.1
        material.emission.contents = tint == nil ? NSColor(white: 0.16, alpha: 1) : NSColor.black
        return material
    }

    static func metal(_ white: CGFloat = 0.85, roughness: CGFloat = 0.25) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(white: white, alpha: 1)
        material.metalness.contents = 1.0
        material.roughness.contents = roughness
        return material
    }

    static func plastic(_ color: NSColor, roughness: CGFloat = 0.4) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = color
        material.metalness.contents = 0.0
        material.roughness.contents = roughness
        return material
    }

    /// A diagonal gradient texture (the front face of a shape spans the whole image).
    static func gradientImage(_ colors: [Color]) -> CGImage {
        let size = 256
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgColors = colors.map { NSColor($0).usingColorSpace(.sRGB)?.cgColor ?? .black } as CFArray
        let gradient = CGGradient(colorsSpace: space, colors: cgColors, locations: nil)!
        // Texture v runs down the face: light at the top left.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return context.makeImage()!
    }

    /// A round tube along `points`, as one mesh with smooth normals: a cable with no joints or
    /// facets showing (cylinders and spheres strung together show a seam at every joint). The ends
    /// are open; they sit inside the plugs.
    static func tube(_ points: [SIMD3<Double>], radius: Double, sides: Int = 32) -> SCNGeometry {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = [], indices: [Int32] = []
        // Frames carried along the curve without twisting (parallel transport).
        var normal: SIMD3<Double> = {
            let first = simd_normalize(points[1] - points[0])
            let seed: SIMD3<Double> = abs(first.z) < 0.9 ? [0, 0, 1] : [1, 0, 0]
            return simd_normalize(simd_cross(first, seed))
        }()
        var previous: SIMD3<Double>?
        for (index, point) in points.enumerated() {
            let ahead = points[min(index + 1, points.count - 1)], behind = points[max(index - 1, 0)]
            let tangent = simd_normalize(ahead - behind)
            if let previous {
                let axis = simd_cross(previous, tangent)
                if simd_length(axis) > 1e-9 {
                    let angle = acos(max(-1, min(1, simd_dot(previous, tangent))))
                    normal = simd_act(simd_quatd(angle: angle, axis: simd_normalize(axis)), normal)
                }
            }
            previous = tangent
            let binormal = simd_cross(tangent, normal)
            for side in 0..<sides {
                let angle = Double(side) / Double(sides) * 2 * .pi
                let direction = cos(angle) * normal + sin(angle) * binormal
                let vertex = point + radius * direction
                vertices.append(SCNVector3(vertex.x, vertex.y, vertex.z))
                normals.append(SCNVector3(direction.x, direction.y, direction.z))
            }
        }
        for ring in 0..<(points.count - 1) {
            for side in 0..<sides {
                let a = Int32(ring * sides + side), b = Int32(ring * sides + (side + 1) % sides)
                let c = a + Int32(sides), d = b + Int32(sides)
                indices += [a, b, c, b, d, c]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
    }

    /// A stadium (a rectangle with fully round ends), centred on the origin: the outline of a
    /// USB-C plug.
    static func stadium(width: CGFloat, height: CGFloat) -> NSBezierPath {
        let path = NSBezierPath(roundedRect: NSRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                xRadius: height / 2, yRadius: height / 2)
        path.flatness = 0.02
        return path
    }
}

/// SF Symbols as vector outlines (traced from a large rendering with Vision), so they can be
/// extruded into solid 3D shapes.
@MainActor
enum SymbolOutline {
    private static var cache: [String: NSBezierPath] = [:]

    /// The symbol's outline, fitted in a square of `side` points centred on the origin.
    static func path(_ name: String, side: CGFloat) -> NSBezierPath? {
        guard let unit = unitPath(name) else { return nil }
        let path = unit.copy() as! NSBezierPath
        path.transform(using: AffineTransform(scale: side))
        return path
    }

    /// Outline in a unit square centred on the origin (longest side 1).
    private static func unitPath(_ name: String) -> NSBezierPath? {
        if let cached = cache[name] { return cached }
        let pixels = 1536
        // Monochrome: one layer (a palette would also fill layers such as a phone's screen).
        let configuration = NSImage.SymbolConfiguration(pointSize: 1200, weight: .bold).applying(.preferringMonochrome())
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        // White on black, in colour (Vision finds no contours in grey images).
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let fit = min(CGFloat(pixels) * 0.8 / symbol.size.width, CGFloat(pixels) * 0.8 / symbol.size.height)
        let drawn = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: CGRect(x: (CGFloat(pixels) - drawn.width) / 2, y: (CGFloat(pixels) - drawn.height) / 2, width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        let all = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        context.setBlendMode(.sourceIn)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(all)
        context.setBlendMode(.destinationOver)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(all)
        guard let image = context.makeImage() else { return nil }

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 1
        request.detectsDarkOnLight = false
        request.maximumImageDimension = pixels
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { return nil }

        let path = NSBezierPath()
        path.windingRule = .nonZero
        // SceneKit fills by direction, not even-odd: outlines run one way and holes the other.
        // Vision does not always nest a hole under its outline, so nesting is worked out from the
        // shapes: a contour inside an odd number of others is a hole.
        var polygons: [[SIMD2<Float>]] = []
        func collect(_ contour: VNContour) {
            let points = evened(contour.normalizedPoints)
            if points.count > 2 { polygons.append(points) }
            for child in contour.childContours { collect(child) }
        }
        for contour in observation.topLevelContours { collect(contour) }
        let shapes = polygons.map { points -> CGPath in
            let shape = CGMutablePath()
            shape.addLines(between: points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            shape.closeSubpath()
            return shape
        }
        for (index, var points) in polygons.enumerated() {
            let probe = CGPoint(x: CGFloat(points[0].x), y: CGFloat(points[0].y))
            let depth = shapes.indices.filter { $0 != index && shapes[$0].contains(probe) }.count
            var area: Float = 0
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                area += a.x * b.y - b.x * a.y
            }
            if (area > 0) != (depth % 2 == 0) { points.reverse() }
            addSmooth(points, to: path)
        }
        guard !path.isEmpty else { return nil }
        // Centre on the origin, longest side 1.
        let bounds = path.bounds
        var transform = AffineTransform(translationByX: -bounds.midX, byY: -bounds.midY)
        transform.append(AffineTransform(scale: 1 / max(bounds.width, bounds.height)))
        path.transform(using: transform)
        cache[name] = path
        return path
    }
}

/// A traced outline without its pixel steps: averaged along its length, then resampled
/// at even spacing. Uneven, wobbly points are what made the extruded sides shade in streaks.
private func evened(_ raw: [SIMD2<Float>]) -> [SIMD2<Float>] {
    guard raw.count > 8 else { return raw }
    var points = raw
    // Three passes of a box average make a near-Gaussian blur along the outline: it takes out
    // the sub-pixel jitter that otherwise tilts every little bevel facet a few degrees (a
    // stitched seam in the highlights), and rounds corners by only a few pixels of 1,536.
    for _ in 0..<3 {
        let n = points.count
        points = (0..<n).map { i in
            var sum = SIMD2<Float>.zero
            for k in -4...4 { sum += points[(i + k + n) % n] }
            return sum / 9
        }
    }
    // Resample: one point every `step` along the outline. Longer steps: what wobble is left
    // tilts each step less.
    let step: Float = 0.01
    var result: [SIMD2<Float>] = [points[0]]
    var carried: Float = 0
    for i in 0..<points.count {
        let a = points[i], b = points[(i + 1) % points.count]
        let length = simd_length(b - a)
        guard length > 0 else { continue }
        var along = step - carried
        while along <= length {
            result.append(a + (b - a) * (along / length))
            along += step
        }
        carried = length - (along - step)
    }
    if let last = result.last, simd_length(last - result[0]) < step / 2 { result.removeLast() }
    return result
}

/// A closed outline through `points` as smooth curves (Catmull-Rom). Traced outlines are otherwise
/// many short straight steps, and every kink fans the bevel out into visible triangles; here even
/// corners are rounded (by about a segment's length, a hair at this size).
@MainActor
private func addSmooth(_ points: [SIMD2<Float>], to path: NSBezierPath) {
    let p = points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
    let n = p.count
    func at(_ i: Int) -> SIMD2<Double> { p[(i % n + n) % n] }
    let tangents: [SIMD2<Double>] = (0..<n).map { i in
        // The average of the two directions, each normalised, so a short step next to a long
        // one does not tip it.
        let incoming = at(i) - at(i - 1), outgoing = at(i + 1) - at(i)
        guard simd_length(incoming) > 0, simd_length(outgoing) > 0 else { return .zero }
        return simd_normalize(incoming) + simd_normalize(outgoing)
    }
    path.move(to: NSPoint(x: p[0].x, y: p[0].y))
    for i in 0..<n {
        let a = at(i), b = at(i + 1)
        // Handles a third of this segment long, along the tangents: never overshoots into a loop.
        let third = simd_length(b - a) / 3
        func direction(_ t: SIMD2<Double>) -> SIMD2<Double> { simd_length(t) > 0 ? simd_normalize(t) : .zero }
        let c1 = a + direction(tangents[i]) * third, c2 = b - direction(tangents[(i + 1) % n]) * third
        path.curve(to: NSPoint(x: b.x, y: b.y), controlPoint1: NSPoint(x: c1.x, y: c1.y), controlPoint2: NSPoint(x: c2.x, y: c2.y))
    }
    path.close()
}

/// Renders scenes to images once (small art, and screen snapshots, which cannot show live views).
@MainActor
enum SceneBaker {
    private static let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
    private static let cache = NSCache<NSString, NSImage>()

    /// Where the pointer is for baked art: the middle, or for checks (PULLI_ART_POINTER="1,-1")
    /// an extreme, so snapshots show whether anything around the art cuts it off.
    static let checkPointer: CGPoint = {
        let parts = (ProcessInfo.processInfo.environment["PULLI_ART_POINTER"] ?? "").split(separator: ",").compactMap { Double($0) }
        return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : .zero
    }()

    /// Rendered at `scale` (small art at 4×, which the view scales down: smooth edges).
    /// Frees the rendered images and the last scene (the window is closed).
    static func purge() {
        cache.removeAllObjects()
        renderer.scene = nil
    }

    static func image(key: String, points: CGSize, scale: CGFloat = 3, scene: () -> SCNScene) -> NSImage {
        let fullKey = "\(key)@\(Int(points.width))x\(Int(points.height))@\(scale)" as NSString
        if let cached = cache.object(forKey: fullKey) { return cached }
        let built = scene()
        renderer.scene = built
        renderer.pointOfView = built.rootNode.childNode(withName: "camera", recursively: false)
        let rendered = renderer.snapshot(atTime: 0, with: CGSize(width: points.width * scale, height: points.height * scale), antialiasingMode: .multisampling4X)
        let image = NSImage(size: points)
        if let cg = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            image.addRepresentation(NSBitmapImageRep(cgImage: cg))
        }
        cache.setObject(image, forKey: fullKey)
        return image
    }
}

/// A live 3D view: transparent, never takes clicks (the SwiftUI view around it does), and turns
/// its subject to `pose` smoothly.
struct SceneView3D: NSViewRepresentable {
    var scene: SCNScene
    /// Rotation of the node named "subject" (x: pitch, y: yaw, z: roll), in radians.
    var pose: SIMD3<Float>
    /// Keep rendering (for idle motion).
    var playing = false

    func makeNSView(context: Context) -> PassThroughSceneView {
        let view = PassThroughSceneView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        view.backgroundColor = .clear
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.antialiasingMode = .multisampling8X
        view.allowsCameraControl = false
        view.preferredFramesPerSecond = 60
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        view.rendersContinuously = playing
        view.isPlaying = playing
        return view
    }

    func updateNSView(_ view: PassThroughSceneView, context: Context) {
        if view.scene !== scene {
            view.scene = scene
            view.pointOfView = scene.rootNode.childNode(withName: "camera", recursively: false)
        }
        view.rendersContinuously = playing
        view.isPlaying = playing
        guard let subject = scene.rootNode.childNode(withName: "subject", recursively: true) else { return }
        let target = SCNVector3(CGFloat(pose.x), CGFloat(pose.y), CGFloat(pose.z))
        guard subject.eulerAngles.x != target.x || subject.eulerAngles.y != target.y || subject.eulerAngles.z != target.z else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.45
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        subject.eulerAngles = target
        SCNTransaction.commit()
    }
}

final class PassThroughSceneView: SCNView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
