import AppKit
import SwiftUI

/// The main action button (Copy), hung over the window's bottom-right corner, half out of the
/// window as CleanMyMac's Scan button. Content cannot draw outside its window, so the button lives
/// in a small borderless child window that follows the main window. When there is no room below
/// the window (full screen, or zoomed down to the Dock), it sits inside the corner instead.
///
/// The child window covers both places (hanging and inside) and is re-pinned to the corner on
/// every screen refresh while the window moves or resizes, so it never trails the window; moving
/// between the two places is a spring of the button inside it.
///
/// In screen snapshots (which cannot show a second window) it is drawn inside the corner.
struct CornerAction<Content: View>: View {
    /// The button's own size (the child window adds room for its glow).
    var diameter: CGFloat = 108
    @ViewBuilder var content: Content
    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @Environment(\.colorScheme) private var colorScheme

    static var margin: CGFloat { 44 }
    static var trailingInset: CGFloat { 30 }

    var body: some View {
        if isSnapshot {
            content
                .padding(.trailing, Self.trailingInset + Self.margin).padding(.bottom, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        } else {
            OverhangAnchor(size: CGSize(width: diameter + Self.margin * 2, height: diameter + Self.margin * 2), trailingInset: Self.trailingInset,
                           content: AnyView(content.frame(maxWidth: .infinity, maxHeight: .infinity)
                               .environment(model).environment(\.tone, tone).environment(\.colorScheme, colorScheme)))
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

private struct OverhangAnchor: NSViewRepresentable {
    var size: CGSize
    var trailingInset: CGFloat
    var content: AnyView

    func makeNSView(context: Context) -> OverhangAnchorView { OverhangAnchorView() }

    func updateNSView(_ view: OverhangAnchorView, context: Context) {
        view.update(content: content, size: size, trailingInset: trailingInset)
    }

    static func dismantleNSView(_ view: OverhangAnchorView, coordinator: ()) {
        view.teardown()
    }
}

/// Owns the child window: attaches it to whichever window the anchor is in and keeps it placed.
final class OverhangAnchorView: NSView {
    private let panel: OverhangPanel
    private let host: FirstMouseHostingView
    private var size = CGSize(width: 190, height: 190)
    private var trailingInset: CGFloat = 30
    private var observers: [any NSObjectProtocol] = []
    private weak var attached: NSWindow?
    /// The window is animating into or out of full screen (or the Dock).
    private var transitioning = false
    /// Re-pins the child window on every screen refresh until then (while the window changes).
    private var followUntil = Date.distantPast
    private var link: CADisplayLink?
    /// Tells the button to play its landing (squash, spring, ring of light).
    private let motion = LandingMotion()

    init() {
        host = FirstMouseHostingView(rootView: AnyView(EmptyView()))
        panel = OverhangPanel(contentRect: NSRect(x: 0, y: 0, width: 190, height: 190),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init(frame: .zero)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        host.frame = panel.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(content: AnyView, size: CGSize, trailingInset: CGFloat) {
        host.rootView = AnyView(Travel(motion: motion, button: size) { content.modifier(Landing(motion: motion)) })
        self.trailingInset = trailingInset
        if self.size != size || !panel.isVisible {
            self.size = size
            place()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach(to: window)
    }

    private func attach(to window: NSWindow?) {
        guard window !== attached else { return }
        detach()
        guard let window else { return }
        attached = window
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEnterFullScreenNotification,
                                          NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                                          NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
        }
        // Resizing and zooming: follow frame by frame (notifications alone arrive late).
        for name in [NSWindow.willStartLiveResizeNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            })
        }
        // Full screen: hide while the window animates in or out, then come back in the corner.
        for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification, NSWindow.willMiniaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.transitioning = true
                    self?.panel.alphaValue = 0
                }
            })
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.transitioning = false
                    self?.place()
                }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.detach() }
        })
        window.addChildWindow(panel, ordered: .above)
        // Appears the way it comes back from full screen: rising into place.
        panel.alphaValue = 0
        place()
    }

    /// Keeps re-pinning on each screen refresh for a moment (renewed by every resize step).
    private func follow() {
        followUntil = Date().addingTimeInterval(0.5)
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        place()
        if Date() > followUntil, attached?.inLiveResize != true {
            link?.invalidate()
            link = nil
        }
    }

    private func detach() {
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        attached?.removeChildWindow(panel)
        attached = nil
        panel.orderOut(nil)
    }

    func teardown() {
        guard attached != nil else { return }
        let panel = panel
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.attached?.removeChildWindow(panel)
                self.attached = nil
                panel.orderOut(nil)
            }
        }
    }

    /// Straddles the bottom edge when there is room below the window, else inside the corner.
    /// The child window spans both places and is pinned at once (never animated, so it cannot
    /// trail the window); the button springs between the places inside it.
    private func place() {
        guard let window = attached else { return }
        guard window.isVisible, !window.isMiniaturized else {
            panel.orderOut(nil)
            return
        }
        let frame = window.frame
        let visible = window.screen?.visibleFrame ?? frame
        let fullScreen = window.styleMask.contains(.fullScreen)
        let half = size.height / 2
        let hangs = !fullScreen && frame.minY - visible.minY >= half - CornerAction<EmptyView>.margin + 6
        let target = NSRect(x: frame.maxX - trailingInset - size.width, y: frame.minY - half,
                            width: size.width, height: size.height + Travel<EmptyView>.distance(size))
        if panel.frame != target { panel.setFrame(target, display: true) }
        if !panel.isVisible {
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
        if motion.docked != !hangs {
            // The first placement just takes its place; later changes spring and land.
            if motion.placed { motion.land() }
            motion.docked = !hangs
        }
        motion.placed = true
        if panel.alphaValue < 1, !transitioning, !motion.appearing {
            // Appearing (or back from full screen): fade in and land.
            motion.appearing = true
            motion.land()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.motion.appearing = false }
            }
        }
    }
}

/// Never takes the keyboard from the main window.
private final class OverhangPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The first click presses the button even though the main window, not this one, is key.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Where the button is (hanging or inside the corner) and its landings, for the SwiftUI side.
@Observable
final class LandingMotion {
    var landings = 0
    var docked = false
    @ObservationIgnored var placed = false
    @ObservationIgnored var appearing = false
    func land() { landings += 1 }
}

/// The button inside the child window: at the bottom when hanging over the edge, `distance`
/// higher when inside the corner, springing between the two.
private struct Travel<Content: View>: View {
    var motion: LandingMotion
    var button: CGSize
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// From hanging (centred on the window's edge) to inside the corner.
    static func distance(_ button: CGSize) -> CGFloat { button.height / 2 + 4 }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            content.frame(width: button.width, height: button.height)
        }
        .offset(y: motion.docked ? -Self.distance(button) : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.68), value: motion.docked)
    }
}

private struct LandingPhase {
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var blur: CGFloat = 0
    var ring: CGFloat = 0
    var ringOpacity: Double = 0
}

/// The landing: blurred a little while it travels, then squashes as it arrives, springs back,
/// and sends out a ring of light.
private struct Landing: ViewModifier {
    var motion: LandingMotion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .keyframeAnimator(initialValue: LandingPhase(), trigger: motion.landings) { view, phase in
                    view
                        .background {
                            Circle().strokeBorder(Color.accent.opacity(phase.ringOpacity), lineWidth: 3)
                                .frame(width: 112, height: 112)
                                .scaleEffect(phase.ring)
                                .blur(radius: 1.5)
                        }
                        .scaleEffect(x: phase.scaleX, y: phase.scaleY, anchor: .bottom)
                        .blur(radius: phase.blur)
                } keyframes: { _ in
                    KeyframeTrack(\.blur) {
                        CubicKeyframe(2.5, duration: 0.15)
                        CubicKeyframe(2.5, duration: 0.25)
                        CubicKeyframe(0, duration: 0.2)
                    }
                    KeyframeTrack(\.scaleY) {
                        CubicKeyframe(1.08, duration: 0.25)
                        CubicKeyframe(1.02, duration: 0.2)
                        SpringKeyframe(0.84, duration: 0.12, spring: .snappy)
                        SpringKeyframe(1.06, duration: 0.18, spring: .bouncy)
                        SpringKeyframe(1, duration: 0.3, spring: .smooth)
                    }
                    KeyframeTrack(\.scaleX) {
                        CubicKeyframe(0.94, duration: 0.25)
                        CubicKeyframe(0.98, duration: 0.2)
                        SpringKeyframe(1.12, duration: 0.12, spring: .snappy)
                        SpringKeyframe(0.97, duration: 0.18, spring: .bouncy)
                        SpringKeyframe(1, duration: 0.3, spring: .smooth)
                    }
                    KeyframeTrack(\.ring) {
                        LinearKeyframe(0.9, duration: 0.45)
                        CubicKeyframe(1.55, duration: 0.5)
                    }
                    KeyframeTrack(\.ringOpacity) {
                        LinearKeyframe(0, duration: 0.45)
                        LinearKeyframe(0.9, duration: 0.05)
                        CubicKeyframe(0, duration: 0.5)
                    }
                }
        }
    }
}
