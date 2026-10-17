import SwiftUI

/// The first-launch introduction (owner request, 2026-09-27): about four seconds, with its own
/// sound, played once. Light gathers into Pulli's mark, the name writes itself, three promises
/// rise in, and a round "Get Started" button closes it. Skippable at any moment; Reduce Motion
/// gets a gentle fade instead.
struct IntroView: View {
    var finish: () -> Void
    /// Show the final frame without animating (screen snapshots).
    var still = false

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var leaving = false
    @State private var start = Date()

    init(still: Bool = false, finish: @escaping () -> Void) {
        self.finish = finish
        self.still = still
        _step = State(initialValue: still ? 5 : 0)
    }

    private let promises: [(ArtPalette, String, String, String)] = [
        (.teal, "cable.connector", "Plug in and go", "No app on the phone. Pulli finds it."),
        (.amber, "arrow.clockwise", "Never starts over", "Unplugged? It resumes from the exact byte."),
        (.violet, "menubar.rectangle", "Every copy at a glance", "Progress for every phone in the menu bar."),
    ]

    var body: some View {
        ZStack {
            SceneBackground(kind: .home)
            if !reduceMotion && !still { Particles(start: start) }
            VStack(spacing: 0) {
                Spacer()
                mark
                wordmark.padding(.top, 26)
                Text("Copy from your Android phone. Never lose progress.")
                    .font(.pulli(18, .medium)).foregroundStyle(.white.opacity(0.8))
                    .opacity(step >= 3 ? 1 : 0).offset(y: step >= 3 ? 0 : 12)
                    .padding(.top, 10)
                HStack(spacing: 16) {
                    ForEach(Array(promises.enumerated()), id: \.offset) { index, promise in
                        promiseCard(promise)
                            .opacity(step >= 4 ? 1 : 0)
                            .offset(y: step >= 4 ? 0 : 30)
                            .animation(.spring(response: 0.7, dampingFraction: 0.8).delay(Double(index) * 0.14), value: step)
                    }
                }
                .padding(.top, 44)
                Spacer()
                Button("Get Started") {
                    if SoundPlayer.soundsEnabled { model.sounds.play(.begin, force: true) }
                    close()
                }
                    .buttonStyle(RoundActionButtonStyle(diameter: 116, fontSize: 16.5))
                    .keyboardShortcut(.defaultAction)
                    .scaleEffect(step >= 5 ? 1 : 0.5)
                    .opacity(step >= 5 ? 1 : 0)
                    .padding(.bottom, 40)
            }
            .foregroundStyle(.white)
        }
        .overlay(alignment: .topTrailing) {
            Button("Skip") { close() }
                .buttonStyle(PillButtonStyle(small: true))
                .padding(.top, 14).padding(.trailing, 16)
                .opacity(step >= 5 ? 0 : 1)
        }
        .environment(\.colorScheme, .dark)
        .modifier(ToneProvider())
        // Always the dark, cinematic version: its white type is designed for it.
        .environment(\.colorScheme, .dark)
        .scaleEffect(leaving ? 1.06 : 1)
        .opacity(leaving ? 0 : 1)
        .task { await run() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Pulli")
    }

    // MARK: Pieces

    private var mark: some View {
        ZStack {
            // A ring of light that spreads out as the mark lands.
            Circle().stroke(Color.accent.opacity(step >= 2 ? 0 : 0.8), lineWidth: 3)
                .frame(width: 150, height: 150)
                .scaleEffect(step >= 2 ? 2.6 : 0.7)
                .animation(.easeOut(duration: 1.1), value: step)
            Circle().fill(Color.accent.opacity(0.45)).frame(width: 190).blur(radius: 50)
                .opacity(step >= 1 ? 1 : 0)
            // Pulli's mark in 3D (the pulley "p" from the app icon), without its tile.
            Image(nsImage: PulliIcon.image(side: 210))
                .resizable()
                .interpolation(.high)
                .frame(width: 210, height: 210)
                .rotationEffect(.degrees(step >= 1 ? 0 : -18))
                .scaleEffect(step >= 1 ? 1 : 0.4)
                .blur(radius: step >= 1 ? 0 : 16)
                .opacity(step >= 1 ? 1 : 0)
                .animation(.spring(response: 0.7, dampingFraction: 0.62), value: step)
        }
        .frame(height: 200)
    }

    private var wordmark: some View {
        HStack(spacing: 0) {
            ForEach(Array("Pulli".enumerated()), id: \.offset) { index, letter in
                Text(String(letter))
                    .font(.pulli(64, .bold)).tracking(-1.5)
                    .opacity(step >= 2 ? 1 : 0)
                    .offset(y: step >= 2 ? 0 : 22)
                    .blur(radius: step >= 2 ? 0 : 8)
                    .animation(.spring(response: 0.55, dampingFraction: 0.75).delay(Double(index) * 0.06), value: step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pulli")
    }

    private func promiseCard(_ promise: (ArtPalette, String, String, String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Gem(form: .disc, palette: promise.0, symbol: promise.1, size: 54)
            Text(promise.2).font(.pulli(15.5, .semibold))
            Text(promise.3).font(.pulli(13)).foregroundStyle(.white.opacity(0.75)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 220, height: 170, alignment: .topLeading)
        .panel(radius: 20)
    }

    // MARK: Timing

    private func run() async {
        if still || reduceMotion {
            withAnimation(.easeInOut(duration: still ? 0 : 0.8)) { step = 5 }
            if !still, SoundPlayer.soundsEnabled { model.sounds.play(.intro, force: true) }
            return
        }
        start = Date()
        if SoundPlayer.soundsEnabled { model.sounds.play(.intro, force: true) }
        // The beats line up with the intro sound: airy rise, landing, arpeggio, sparkle.
        let beats: [(Double, Int)] = [(1.0, 1), (1.4, 2), (1.95, 3), (2.55, 4), (3.35, 5)]
        var elapsed = 0.0
        for (at, next) in beats {
            try? await Task.sleep(for: .seconds(at - elapsed))
            elapsed = at
            guard !leaving else { return }
            withAnimation(.easeOut(duration: 0.6)) { step = next }
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.45)) { leaving = true }
        Task {
            try? await Task.sleep(for: .seconds(0.45))
            finish()
        }
    }
}

/// Points of light that stream into the middle while the mark forms, then drift like dust.
private struct Particles: View {
    var start: Date

    private struct Mote {
        var angle: Double
        var distance: Double
        var size: Double
        var speed: Double
        var hue: Int
    }

    private let motes: [Mote] = {
        var generator = SeededGenerator(seed: 7)
        return (0..<46).map { _ in
            Mote(angle: .random(in: 0...(2 * .pi), using: &generator), distance: .random(in: 0.35...0.75, using: &generator),
                 size: .random(in: 2...5.5, using: &generator), speed: .random(in: 0.6...1.4, using: &generator),
                 hue: .random(in: 0...2, using: &generator))
        }
    }()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                let center = CGPoint(x: size.width / 2, y: size.height * 0.36)
                let reach = max(size.width, size.height)
                canvas.addFilter(.blur(radius: 1.2))
                for mote in motes {
                    // 0…1.1 s: fall inwards; afterwards drift slowly outwards and twinkle.
                    let gather = min(t / 1.1, 1)
                    let eased = 1 - pow(1 - gather, 3)
                    let drift = max(t - 1.1, 0) * 0.018 * mote.speed
                    let distance = mote.distance * (1 - 0.85 * eased) + drift
                    let angle = mote.angle + t * 0.05 * mote.speed
                    let point = CGPoint(x: center.x + cos(angle) * distance * reach, y: center.y + sin(angle) * distance * reach * 0.62)
                    let twinkle = 0.55 + 0.45 * sin(t * 2.2 * mote.speed + mote.angle * 3)
                    let alpha = (t < 1.1 ? 0.25 + 0.75 * eased : 0.5 * twinkle) * min(t / 0.3, 1)
                    let color: Color = [Color.accent, Color(hex: 0x8FC7FF), .white][mote.hue]
                    canvas.fill(Path(ellipseIn: CGRect(x: point.x - mote.size / 2, y: point.y - mote.size / 2, width: mote.size, height: mote.size)),
                                with: .color(color.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Deterministic randomness, so the intro looks the same every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
