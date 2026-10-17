import AppKit
import PulliProtocol
import SwiftUI

/// What to do on the phone before Pulli can see its files (locked, or set to charging only), as
/// steps the 3D phone acts out: its screen shows each step in turn, the step is highlighted
/// beside it, and it moves on by itself (clicking a step shows that one). The words follow the
/// phone's maker, as Samsung and Google word the USB notification and options differently.
/// Pulli moves on by itself as soon as the phone is ready.
struct GuideView: View {
    var device: DeviceSnapshot
    @Environment(\.tone) private var tone
    @Environment(\.isSnapshot) private var isSnapshot
    @State private var step = 0
    /// Counts step starts: each one restarts the bar under the current step.
    @State private var run = 0
    /// A click on a step holds it for a while before the tour goes on.
    @State private var heldUntil = Date.distantPast

    static let stepTime: Double = 3.4

    var body: some View {
        let locked = device.state == .locked
        let words = PhoneWords(manufacturer: device.manufacturer, model: device.model)
        let steps = locked ? Self.lockedSteps(words) : Self.chargingSteps(words)
        let current = min(step, steps.count - 1)
        HStack(spacing: 30) {
            PhoneArt(width: 290, palette: .teal, screen: steps[current].screen, cable: .plugged, fades: true)
            VStack(alignment: .leading, spacing: 16) {
#if PULLI_APP_STORE
                let unlockedChipText = "Connected · choose Transferring images"
#else
                let unlockedChipText = "Connected · charging only"
#endif
                let chipText = locked ? "Connected · locked" : unlockedChipText
                Chip(text: chipText, color: tone.amber, fill: tone.amberFill, small: true)
                Text("Let Pulli see your files").font(.pulli(32, .medium))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                        row(index: index, item: item, current: index == current)
                    }
                }
                HStack(spacing: 9) {
                    GlowDot(color: .accent)
                    Text("Pulli continues as soon as the phone is ready.").font(.pulli(13.5)).foregroundStyle(tone.t2)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
        .task(id: "\(locked)") { await tour(count: steps.count) }
        .onChange(of: locked) { step = 0 }
    }

    private func row(index: Int, item: Step, current: Bool) -> some View {
        Button {
            heldUntil = Date().addingTimeInterval(8)
            show(index)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Text("\(index + 1)").font(.pulli(13, .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(LinearGradient(colors: current ? [.accent, .accentDeep] : [tone.t3.opacity(0.6), tone.t3.opacity(0.4)],
                                                             startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Color.accent.opacity(current ? 0.5 : 0), radius: 8, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.pulli(15, .semibold))
                    Text(item.detail).font(.pulli(13.5)).foregroundStyle(tone.t2)
                        .fixedSize(horizontal: false, vertical: true)
                    if current {
                        Group {
                            if isSnapshot {
                                GeometryReader { proxy in
                                    Capsule().fill(tone.track)
                                        .overlay(alignment: .leading) { Capsule().fill(Color.accent).frame(width: proxy.size.width * 0.4) }
                                }
                            } else {
                                StepSweep(run: run, duration: Self.stepTime, track: NSColor(tone.track), fill: NSColor(Color.accent))
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 6)
                        .transition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(current ? Color.accent.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(current ? Color.accent.opacity(0.35) : .clear, lineWidth: 1))
            .opacity(current ? 1 : 0.62)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    /// Goes through the steps, and round again.
    private func tour(count: Int) async {
        guard !isSnapshot else {
            step = 1
            return
        }
        show(0)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.stepTime))
            guard !Task.isCancelled else { return }
            if Date() < heldUntil { continue }
            show((step + 1) % count)
        }
    }

    private func show(_ index: Int) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { step = index }
        run += 1
    }

    // MARK: Steps

    struct Step {
        var title: String
        var detail: String
        var screen: PhoneArt.Screen
    }

    static func lockedSteps(_ words: PhoneWords) -> [Step] {
        [Step(title: "Unlock your phone", detail: "Pulli can only see files while the phone is unlocked.", screen: .unlock),
         Step(title: "Tap \u{201C}Allow\u{201D}", detail: "If the phone asks whether to allow access to phone data, tap Allow.", screen: .allow),
         Step(title: "Keep it unlocked for a moment", detail: "Once Pulli has opened it, the phone can lock again.", screen: .photos)]
    }

    static func chargingSteps(_ words: PhoneWords) -> [Step] {
        var steps = [
            Step(title: "Unlock your phone", detail: "Pulli can only see files while the phone is unlocked.", screen: .unlock),
            Step(title: "Swipe down from the top", detail: "The notifications open. One of them is about USB.", screen: .shade(words.shade(tapping: false))),
            Step(title: "Tap the USB notification", detail: "It says \u{201C}\(words.notification)\u{201D}.", screen: .shade(words.shade(tapping: true)))
        ]
#if PULLI_APP_STORE
        steps.append(Step(title: "Choose \u{201C}Transferring images\u{201D}", detail: "Under \u{201C}\(words.useFor)\u{201D} in \(words.settingsTitle) (also called PTP).", screen: .usb(words.usb)))
#else
        steps.append(Step(title: "Choose \u{201C}\(words.fileTransfer)\u{201D}", detail: "Under \u{201C}\(words.useFor)\u{201D} in \(words.settingsTitle).", screen: .usb(words.usb)))
#endif
        steps.append(Step(title: "Tap \u{201C}Allow\u{201D} if asked", detail: "The phone may ask whether to allow access to phone data.", screen: .allow))
        return steps
    }
}

/// How the phone's maker words the USB notification and options.
struct PhoneWords {
    var notification: String
    var notificationDetail: String
    var settingsTitle: String
    var useFor: String
    var fileTransfer: String
    var options: [String]

    init(manufacturer: String?, model: String?) {
        let maker = "\(manufacturer ?? "") \(model ?? "")".lowercased()
        if maker.contains("samsung") || maker.contains("galaxy") || maker.contains("sm-") {
            notification = "Charging via USB"
            notificationDetail = "Tap for more USB options."
            settingsTitle = "USB settings"
            useFor = "Use USB for"
            fileTransfer = "Transferring files / Android Auto"
            options = [fileTransfer, "Transferring images", "Controlling MIDI device", "Charging phone only"]
        } else {
            // Google's wording, which most other makers keep (Pixel, Xiaomi, Motorola, OnePlus…).
            notification = "Charging this device via USB"
            notificationDetail = "Tap for more options."
            settingsTitle = "USB Preferences"
            useFor = "Use USB for"
            fileTransfer = "File transfer / Android Auto"
            options = [fileTransfer, "USB tethering", "MIDI", "PTP", "No data transfer"]
        }
    }

    func shade(tapping: Bool) -> PhoneArt.ShadeScreen {
        PhoneArt.ShadeScreen(title: notification, detail: notificationDetail, tapping: tapping)
    }

    var usb: PhoneArt.USBScreen {
#if PULLI_APP_STORE
        let selectedIndex = options.firstIndex(where: { $0.contains("Transferring images") || $0 == "PTP" }) ?? 0
        return PhoneArt.USBScreen(title: settingsTitle, heading: useFor, options: options, selected: selectedIndex)
#else
        PhoneArt.USBScreen(title: settingsTitle, heading: useFor, options: options, selected: 0)
#endif
    }
}

/// The bar under the current step, filling over the step's time. Core Animation runs the sweep
/// outside the app: a SwiftUI width animated every frame re-evaluated the whole guide, 3D phone
/// included, 60 times a second (about 8% CPU on a screen that only waits).
private struct StepSweep: NSViewRepresentable {
    /// Changes whenever a step starts: the sweep restarts from empty.
    var run: Int
    var duration: Double
    var track: NSColor
    var fill: NSColor

    func makeNSView(context: Context) -> SweepView { SweepView() }

    func updateNSView(_ view: SweepView, context: Context) {
        view.configure(run: run, duration: duration, track: track, fill: fill)
    }
}

private final class SweepView: NSView {
    private let bar = CALayer()
    private var run: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(bar)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        bar.bounds = bounds
        bar.position = CGPoint(x: 0, y: bounds.midY)
        bar.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    func configure(run: Int, duration: Double, track: NSColor, fill: NSColor) {
        layer?.backgroundColor = track.cgColor
        bar.backgroundColor = fill.cgColor
        guard run != self.run else { return }
        self.run = run
        let sweep = CABasicAnimation(keyPath: "transform.scale.x")
        sweep.fromValue = 0
        sweep.toValue = 1
        sweep.duration = duration
        sweep.fillMode = .forwards
        sweep.isRemovedOnCompletion = false
        bar.removeAllAnimations()
        bar.add(sweep, forKey: "sweep")
    }
}
