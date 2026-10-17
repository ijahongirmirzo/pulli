import AppKit
import CoreText
import SwiftUI

// Pulli's look (docs/DECISIONS.md, D-020): a full-window colour scene per section, frosted panels,
// glossy artwork and one round action button. Typeface: Plus Jakarta Sans (SIL OFL), bundled.

/// The app's resource bundle (fonts, sounds). Found inside Pulli.app, next to a command-line build,
/// or next to the test bundle; missing resources degrade quietly instead of crashing.
enum Resources {
    private final class Marker {}

    static let bundle: Bundle? = {
        let candidates = [Bundle.main.resourceURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                          Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()]
        for folder in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: folder.appendingPathComponent("Pulli_Pulli.bundle")) { return bundle }
        }
        return nil
    }()
}

enum Typeface {
    static let family = "Plus Jakarta Sans"

    /// Registers the bundled font for this process. Falls back to the system font if missing.
    static func register() {
        guard let url = Resources.bundle?.url(forResource: "PlusJakartaSans", withExtension: "ttf", subdirectory: "Fonts") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}

extension Font {
    static func pulli(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Typeface.family, fixedSize: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    static var accent: Color { AppTheme.current.accent }
    static var accentDeep: Color { AppTheme.current.accentDeep }
    static let pausedAmber = Color(hex: 0xFFB547)
    static let copyBlue = Color(hex: 0x3F8CF0)
}

/// Text and surface colours for the current appearance. Dark scenes carry white text; light
/// scenes are pastel with dark text. Contrast checked at 4.5:1 for body text.
struct Tone: Sendable {
    var dark: Bool
    private var ink: UInt32 { AppTheme.current.ink }
    var t1: Color { dark ? .white : Color(hex: ink) }
    var t2: Color { dark ? .white.opacity(0.78) : Color(hex: ink, opacity: 0.76) }
    var t3: Color { dark ? .white.opacity(0.62) : Color(hex: ink, opacity: 0.64) }
    var panelHi: Color { dark ? .white.opacity(0.17) : .white.opacity(0.78) }
    var panelLo: Color { dark ? .white.opacity(0.05) : .white.opacity(0.40) }
    var panelBorder: Color { dark ? .white.opacity(0.18) : .white.opacity(0.9) }
    var pill: Color { dark ? .white.opacity(0.16) : .white.opacity(0.72) }
    var pillBorder: Color { dark ? .white.opacity(0.24) : Color(hex: ink, opacity: 0.10) }
    var track: Color { dark ? .white.opacity(0.18) : Color(hex: ink, opacity: 0.12) }
    var separator: Color { dark ? .white.opacity(0.12) : Color(hex: ink, opacity: 0.10) }
    var amber: Color { dark ? Color(hex: 0xFFC873) : Color(hex: 0x8A4F00) }
    var amberFill: Color { Color(hex: 0xFFB03C, opacity: dark ? 0.20 : 0.24) }
    var green: Color { dark ? Color(hex: 0x8CF5AE) : Color(hex: 0x0B6E36) }
    var greenFill: Color { dark ? Color(hex: 0x50DC78, opacity: 0.18) : Color(hex: 0x28B45A, opacity: 0.16) }
    var checkFill: Color { AppTheme.current == .classic ? (dark ? .white.opacity(0.92) : Color(hex: 0x0B3B40)) : Color.accent }
    var checkInk: Color { AppTheme.current == .classic ? (dark ? Color(hex: 0x0B3B40) : .white) : .white }
    var strongFill: Color { dark ? .white : Color(hex: ink) }
    var strongInk: Color { dark ? Color(hex: ink) : .white }
    var shadow: Color { .black.opacity(dark ? 0.28 : 0.12) }
}

extension EnvironmentValues {
    @Entry var tone = Tone(dark: true)
}

/// Sets `tone` from the system appearance for everything inside.
struct ToneProvider: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.environment(\.tone, Tone(dark: scheme == .dark)).foregroundStyle(Tone(dark: scheme == .dark).t1)
    }
}

// MARK: - Scenes

enum SceneKind: Hashable, Sendable {
    case home, copying, paused, done, history, slate

    struct Recipe {
        var base: [Color]
        var glowA: Color
        var glowB: Color
        var centerA: UnitPoint
        var centerB: UnitPoint
    }

    func recipe(dark: Bool) -> Recipe {
        if let themed = AppTheme.current.scene(dark: dark) { return themed }
        return switch (self, dark) {
        case (.home, true):
            Recipe(base: [Color(hex: 0x05283A), Color(hex: 0x0A4A5C), Color(hex: 0x0C2C62)], glowA: Color(hex: 0x3CCFBE, opacity: 0.62),
                   glowB: Color(hex: 0x2E62DC, opacity: 0.62), centerA: UnitPoint(x: 0.78, y: 0.12), centerB: UnitPoint(x: 0.08, y: 0.96))
        case (.home, false):
            Recipe(base: [Color(hex: 0xE6FBF7), Color(hex: 0xC4EEE8), Color(hex: 0xCBDDF8)], glowA: Color(hex: 0x3CCFBE, opacity: 0.45),
                   glowB: Color(hex: 0x78A0FF, opacity: 0.40), centerA: UnitPoint(x: 0.78, y: 0.10), centerB: UnitPoint(x: 0.06, y: 0.96))
        case (.copying, true):
            Recipe(base: [Color(hex: 0x071A4C), Color(hex: 0x10398C), Color(hex: 0x1A2A78)], glowA: Color(hex: 0x5AAAFF, opacity: 0.58),
                   glowB: Color(hex: 0x3CCFBE, opacity: 0.45), centerA: UnitPoint(x: 0.75, y: 0.10), centerB: UnitPoint(x: 0.10, y: 0.95))
        case (.copying, false):
            Recipe(base: [Color(hex: 0xE8F0FF), Color(hex: 0xC6D9FF), Color(hex: 0xD3E6F8)], glowA: Color(hex: 0x5AAAFF, opacity: 0.40),
                   glowB: Color(hex: 0x3CCFBE, opacity: 0.32), centerA: UnitPoint(x: 0.75, y: 0.10), centerB: UnitPoint(x: 0.10, y: 0.95))
        case (.paused, true):
            Recipe(base: [Color(hex: 0x2A1305), Color(hex: 0x5E2F0A), Color(hex: 0x3A1808)], glowA: Color(hex: 0xFFAA3C, opacity: 0.55),
                   glowB: Color(hex: 0xD25032, opacity: 0.45), centerA: UnitPoint(x: 0.75, y: 0.10), centerB: UnitPoint(x: 0.08, y: 0.96))
        case (.paused, false):
            Recipe(base: [Color(hex: 0xFFF3E2), Color(hex: 0xFFDDB0), Color(hex: 0xFBE5CF)], glowA: Color(hex: 0xFFAA3C, opacity: 0.40),
                   glowB: Color(hex: 0xFF7850, opacity: 0.28), centerA: UnitPoint(x: 0.75, y: 0.10), centerB: UnitPoint(x: 0.08, y: 0.96))
        case (.done, true):
            Recipe(base: [Color(hex: 0x03240F), Color(hex: 0x0A4B23), Color(hex: 0x2E6A1C)], glowA: Color(hex: 0x96F08C, opacity: 0.40),
                   glowB: Color(hex: 0x1EAA64, opacity: 0.50), centerA: UnitPoint(x: 0.30, y: 0.20), centerB: UnitPoint(x: 0.90, y: 0.95))
        case (.done, false):
            Recipe(base: [Color(hex: 0xEAFAE6), Color(hex: 0xC7EEC4), Color(hex: 0xE2F4CD)], glowA: Color(hex: 0x96F08C, opacity: 0.40),
                   glowB: Color(hex: 0x3CC878, opacity: 0.30), centerA: UnitPoint(x: 0.30, y: 0.20), centerB: UnitPoint(x: 0.90, y: 0.95))
        case (.history, true):
            Recipe(base: [Color(hex: 0x130A38), Color(hex: 0x2A1674), Color(hex: 0x18164E)], glowA: Color(hex: 0xA06EFF, opacity: 0.55),
                   glowB: Color(hex: 0x3C64E6, opacity: 0.50), centerA: UnitPoint(x: 0.75, y: 0.10), centerB: UnitPoint(x: 0.08, y: 0.96))
        case (.history, false):
            Recipe(base: [Color(hex: 0xF0EBFF), Color(hex: 0xDAD0FF), Color(hex: 0xD9E2FB)], glowA: Color(hex: 0xA06EFF, opacity: 0.36),
                   glowB: Color(hex: 0x648CFF, opacity: 0.30), centerA: UnitPoint(x: 0.75, y: 0.10), centerB: UnitPoint(x: 0.08, y: 0.96))
        case (.slate, true):
            Recipe(base: [Color(hex: 0x0F1722), Color(hex: 0x172233)], glowA: Color(hex: 0x3CCFBE, opacity: 0.26),
                   glowB: Color(hex: 0x465AC8, opacity: 0.26), centerA: UnitPoint(x: 0.85, y: 0.0), centerB: UnitPoint(x: 0.0, y: 1.0))
        case (.slate, false):
            Recipe(base: [Color(hex: 0xF5F8FA), Color(hex: 0xE5ECF2)], glowA: Color(hex: 0x3CCFBE, opacity: 0.20),
                   glowB: Color(hex: 0x7896FF, opacity: 0.18), centerA: UnitPoint(x: 0.85, y: 0.0), centerB: UnitPoint(x: 0.0, y: 1.0))
        }
    }
}

/// The full-window colour scene. Its two glows drift slowly (not with Reduce Motion); changing
/// `kind` cross-fades to the new scene.
///
/// The drift moves whole layers with a repeating animation, which the system renders on its own.
/// Redrawing the gradients in a timeline, 20 times a second, made every panel above them
/// recomposite constantly, and taps felt laggy.
struct SceneBackground: View {
    var kind: SceneKind
    var animated = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        ZStack {
            layer(kind).id(kind).transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.8), value: kind)
        .ignoresSafeArea()
        .onAppear {
            // Only the classic colour scenes drift: the themed backgrounds are calm and still, and a
            // drift SwiftUI animates frame by frame costs CPU the whole time a window is open.
            guard animated, !reduceMotion, AppTheme.current == .classic else { return }
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) { drift = true }
        }
    }

    private func layer(_ kind: SceneKind) -> some View {
        let recipe = kind.recipe(dark: scheme == .dark)
        return GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(colors: recipe.base, startPoint: .topLeading, endPoint: .bottomTrailing)
                EllipticalGradient(colors: [recipe.glowA, recipe.glowA.opacity(0)], center: recipe.centerA, startRadiusFraction: 0, endRadiusFraction: 0.62)
                    .frame(width: size.width * 1.3, height: size.height * 1.3)
                    .offset(x: drift ? size.width * 0.04 : -size.width * 0.03, y: drift ? size.height * 0.05 : -size.height * 0.02)
                EllipticalGradient(colors: [recipe.glowB, recipe.glowB.opacity(0)], center: recipe.centerB, startRadiusFraction: 0, endRadiusFraction: 0.62)
                    .frame(width: size.width * 1.3, height: size.height * 1.3)
                    .offset(x: drift ? -size.width * 0.05 : size.width * 0.02, y: drift ? -size.height * 0.03 : size.height * 0.04)
            }
            .frame(width: size.width, height: size.height)
            .drawingGroup()
        }
    }
}

// MARK: - Surfaces

struct PanelBackground: ViewModifier {
    var radius: CGFloat = 22
    var tint: Color?
    /// Solid underneath, for notes that float over the page and stay up (text must not show through).
    var opaque = false
    @Environment(\.tone) private var tone

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The shadow is its own blurred shape behind the panel. A `.shadow` on the panel itself
        // re-renders everything inside it off screen on every change (every tick in a list).
        content
            .background(shape.fill(LinearGradient(colors: [tint ?? tone.panelHi, tone.panelLo], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .background(shape.fill(opaque ? Color(nsColor: .windowBackgroundColor) : .clear))
            .overlay(shape.strokeBorder(LinearGradient(colors: [tone.panelBorder, tone.panelBorder.opacity(0.35)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .clipShape(shape)
            .background {
                shape.fill(tone.shadow).blur(radius: 18).offset(y: 14).allowsHitTesting(false)
            }
    }
}

extension View {
    func panel(radius: CGFloat = 22, tint: Color? = nil, opaque: Bool = false) -> some View {
        modifier(PanelBackground(radius: radius, tint: tint, opaque: opaque))
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    enum Kind { case glass, strong, accent }
    var kind: Kind = .glass
    var small = false
    @Environment(\.tone) private var tone
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .font(.pulli(small ? 12.5 : 13, .semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: small ? 28 : 32)
            .foregroundStyle(foreground)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: kind == .accent ? Color.accent.opacity(0.35) : .clear, radius: 9, y: 4)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }

    private var foreground: Color {
        switch kind {
        case .glass: tone.t1
        case .strong: tone.strongInk
        case .accent: .white
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .glass: AnyShapeStyle(tone.pill)
        case .strong: AnyShapeStyle(tone.strongFill)
        case .accent: AnyShapeStyle(LinearGradient(colors: [.accent, .accentDeep], startPoint: .top, endPoint: .bottom))
        }
    }

    private var border: Color {
        switch kind {
        case .glass: tone.pillBorder
        case .strong: .clear
        case .accent: .white.opacity(0.35)
        }
    }
}

/// The one round, glowing action per screen (Copy, Get Started).
struct RoundActionButtonStyle: ButtonStyle {
    var diameter: CGFloat = 108
    var fontSize: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        RoundActionBody(label: configuration.label, pressed: configuration.isPressed, diameter: diameter, fontSize: fontSize)
    }
}

private struct RoundActionBody<Label: View>: View {
    var label: Label
    var pressed: Bool
    var diameter: CGFloat
    var fontSize: CGFloat
    @State private var hovering = false
    /// The pointer over the button, -1…1: the button tilts toward it.
    @State private var tilt = CGPoint.zero
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A thick glossy disc: its edge shows below the face, and pressing pushes the face down
        // into it like a real key.
        let depth = diameter * 0.075
        let sink = pressed ? depth * 0.75 : 0
        let p = isSnapshot ? .zero : tilt
        ZStack {
            // Glow on what is under the button.
            Circle().fill(Color.accent.opacity(hovering ? 0.55 : 0.4)).blur(radius: diameter * 0.2)
                .frame(width: diameter * 0.95).offset(y: depth + diameter * 0.1)
            Circle().fill(.black.opacity(0.45)).blur(radius: diameter * 0.06)
                .frame(width: diameter * 0.92).offset(x: -p.x * 2.5, y: depth + diameter * 0.05 - sink * 0.5)
            Circle().fill(Color.accent.opacity(0.2)).frame(width: diameter + 14)
            // The edge (the disc's side).
            Circle().fill(LinearGradient(colors: [.accentDeep, Color.accentDeep.mix(with: .black, by: 0.45)], startPoint: .top, endPoint: .bottom))
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .frame(width: diameter, height: diameter)
                .offset(y: depth)
            // The face.
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.accent.mix(with: .white, by: 0.12), .accentDeep], startPoint: .top, endPoint: .bottom))
                Circle().fill(RadialGradient(colors: [.white.opacity(0.6), .white.opacity(0)],
                                             center: UnitPoint(x: 0.5 + p.x * 0.09, y: 0.2 + p.y * 0.07), startRadius: 0, endRadius: diameter * 0.48))
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                label
                    .font(.pulli(fontSize, .bold))
                    .foregroundStyle(.white)
                    .shadow(color: Color.accentDeep.mix(with: .black, by: 0.6).opacity(0.55), radius: 1.5, y: 1.5)
                    .offset(x: p.x * diameter * 0.02, y: p.y * diameter * 0.02)
            }
            .frame(width: diameter, height: diameter)
            .offset(y: sink)
        }
        .frame(width: diameter, height: diameter + depth)
        .rotation3DEffect(.degrees(Double(p.x) * 7), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(Double(-p.y) * 7), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .scaleEffect(hovering && !pressed ? 1.04 : 1)
        .saturation(enabled ? 1 : 0.35)
        .opacity(enabled ? 1 : 0.6)
        .animation(.spring(response: 0.25, dampingFraction: 0.55), value: pressed)
        .animation(.easeOut(duration: 0.2), value: hovering)
        .contentShape(Circle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hovering = true
                guard !reduceMotion else { return }
                let target = CGPoint(x: max(-1, min(1, location.x / diameter * 2 - 1)), y: max(-1, min(1, location.y / diameter * 2 - 1)))
                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.8)) { tilt = target }
            case .ended:
                hovering = false
                withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { tilt = .zero }
            }
        }
    }
}

/// A small rounded status capsule ("31.4 MB/s", "Paused").
struct Chip: View {
    var text: String
    var color: Color?
    var fill: Color?
    var small = false
    @Environment(\.tone) private var tone

    var body: some View {
        Text(text)
            .font(.pulli(small ? 11.5 : 13, .semibold))
            .monospacedDigit()
            .foregroundStyle(color ?? tone.t1)
            .padding(.horizontal, small ? 8 : 12)
            .padding(.vertical, small ? 2 : 5)
            .background(Capsule().fill(fill ?? tone.pill))
    }
}

/// A glowing status dot.
/// A softly pulsing dot ("waiting for a phone"). The pulse is a Core Animation animation, run by
/// the system on its own: as a SwiftUI animation it was recomputed in the app every frame.
struct GlowDot: View {
    var color: Color
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            Circle().fill(color).frame(width: size, height: size)
                .background(Circle().fill(color.opacity(0.28)).padding(-3))
        } else {
            PulsingDot(color: NSColor(color), size: size, pulsing: !reduceMotion)
                .frame(width: size + 16, height: size + 16)
                .padding(-8)
        }
    }
}

private struct PulsingDot: NSViewRepresentable {
    var color: NSColor
    var size: CGFloat
    var pulsing: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let halo = CALayer(), dot = CALayer()
        halo.name = "halo"
        dot.name = "dot"
        for layer in [halo, dot] { view.layer?.addSublayer(layer) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let layers = view.layer?.sublayers, layers.count == 2 else { return }
        let (halo, dot) = (layers[0], layers[1])
        let box = CGRect(x: 0, y: 0, width: size + 16, height: size + 16)
        let center = CGPoint(x: box.midX, y: box.midY)
        dot.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        dot.position = center
        dot.cornerRadius = size / 2
        dot.backgroundColor = color.cgColor
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 5
        dot.shadowOffset = .zero
        halo.bounds = CGRect(x: 0, y: 0, width: size + 8, height: size + 8)
        halo.position = center
        halo.cornerRadius = (size + 8) / 2
        halo.backgroundColor = color.withAlphaComponent(0.28).cgColor
        guard pulsing, halo.animation(forKey: "pulse") == nil else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.8
        grow.toValue = 1.45
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.3
        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        halo.add(pulse, forKey: "pulse")
    }
}

/// Tick box drawn to match the scenes (a real Toggle underneath for accessibility).
struct CheckBox: View {
    enum State { case on, off, mixed }
    var state: State
    @Environment(\.tone) private var tone

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            switch state {
            case .on:
                shape.fill(tone.checkFill)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(tone.checkInk)
            case .mixed:
                shape.fill(tone.checkFill)
                Capsule().fill(tone.checkInk).frame(width: 8, height: 2)
            case .off:
                shape.strokeBorder(tone.t3, lineWidth: 1.5)
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(shape)
    }
}

/// An inline text link ("Change", "Review") in the accent ink.
struct InlineLinkStyle: ButtonStyle {
    @Environment(\.tone) private var tone
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(AppTheme.current.link(dark: tone.dark))
            .underline(configuration.isPressed)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}

extension EnvironmentValues {
    /// True while rendering screen snapshots, where scroll views cannot be drawn.
    @Entry var isSnapshot = false
}

/// A vertical scroll view, or a plain stack in snapshots.
struct Scrolling<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        if isSnapshot {
            // Takes only the space offered (like a scroll view) and shows the top of the content.
            Color.clear.overlay(alignment: .top) { VStack(spacing: 0) { content } }.clipped()
        } else {
            ScrollView { content }
        }
    }
}

// MARK: - Navigation motion

extension Animation {
    /// Screen changes the user asked for: quick, with a soft landing.
    static let pulliNavigation = Animation.spring(response: 0.42, dampingFraction: 0.88)
}

/// Motion blur, approximated: while a screen travels it is blurred and stretched a little along
/// the direction of travel, and fades. (SwiftUI has no directional blur; this reads as one at
/// this speed.)
struct MotionBlurred: ViewModifier {
    var offset: CGSize
    var blur: CGFloat
    var stretch: CGSize
    var opacity: Double

    static let still = MotionBlurred(offset: .zero, blur: 0, stretch: CGSize(width: 1, height: 1), opacity: 1)

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: stretch.width, y: stretch.height)
            .blur(radius: blur)
            .offset(offset)
            .opacity(opacity)
    }
}

extension AppModel.NavTransition {
    var transition: AnyTransition {
        let travel: CGFloat = 140
        func moving(_ dx: CGFloat, _ dy: CGFloat, opacity: Double = 0) -> AnyTransition {
            .modifier(active: MotionBlurred(offset: CGSize(width: dx, height: dy), blur: 16,
                                            stretch: CGSize(width: dx == 0 ? 1 : 1.05, height: dy == 0 ? 1 : 1.06), opacity: opacity),
                      identity: .still)
        }
        switch self {
        case .fade:
            return .modifier(active: MotionBlurred(offset: .zero, blur: 8, stretch: CGSize(width: 1, height: 1), opacity: 0), identity: .still)
        case .up:
            return .asymmetric(insertion: moving(0, travel), removal: moving(0, -travel))
        case .down:
            return .asymmetric(insertion: moving(0, -travel), removal: moving(0, travel))
        case .forward:
            return .asymmetric(insertion: moving(travel * 1.6, 0), removal: moving(-travel, 0, opacity: 0))
        case .back:
            return .asymmetric(insertion: moving(-travel, 0), removal: moving(travel * 1.6, 0, opacity: 0))
        }
    }
}

// MARK: - Glass

/// macOS's own glass for windows that float over everything (menus, the menu bar item's
/// window): whatever is behind the window shows through, blurred, as in a menu.
///
/// macOS has no setting for how strong the blur is, so `clarity` lets part of the sharp
/// background through instead: the glass is drawn partly transparent over a clear window (the
/// window's own frosted backdrop is switched off).
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .menu
    /// 0: fully frosted, as a menu; 1: no frost at all.
    var clarity: CGFloat = 0

    func makeNSView(context: Context) -> ClearingEffectView {
        let view = ClearingEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        view.alphaValue = 1 - clarity
        return view
    }

    func updateNSView(_ view: ClearingEffectView, context: Context) {
        view.material = material
        view.alphaValue = 1 - clarity
    }
}

/// Makes its window see-through and turns off any other frosted backdrop in it, so only this
/// view's (partly transparent) glass is between the content and the desktop.
final class ClearingEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        func clear(_ view: NSView) {
            for subview in view.subviews {
                if let effect = subview as? NSVisualEffectView, effect !== self, !isDescendant(of: effect) {
                    effect.state = .inactive
                    effect.material = .fullScreenUI
                    effect.alphaValue = 0
                }
                clear(subview)
            }
        }
        if let frame = window.contentView?.superview { clear(frame) }
    }
}
