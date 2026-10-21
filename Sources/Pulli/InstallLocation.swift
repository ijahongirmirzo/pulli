import AppKit
import SwiftUI

/// Pulli opened straight from its disk image (or from Downloads, which macOS runs from a
/// temporary copy) offers to move itself to Applications: copied there, the old copy (if any) to
/// the Trash, then Pulli opens again from Applications and the disk image is ejected.
@MainActor
enum InstallLocation {
    static let destination = URL(fileURLWithPath: "/Applications/Pulli.app")

    /// When the running app is in /Applications as Pulli.app and an old /Applications/Relay.app
    /// exists whose bundle identifier is app.relay.mac, moves that old copy to the Trash once, quietly.
    static func cleanUpOldRelayAppIfNeeded() {
        let runningPath = Bundle.main.bundleURL.standardizedFileURL.path
        guard runningPath == destination.standardizedFileURL.path else { return }
        let oldApp = URL(fileURLWithPath: "/Applications/Relay.app")
        guard FileManager.default.fileExists(atPath: oldApp.path) else { return }
        if let oldBundle = Bundle(url: oldApp), oldBundle.bundleIdentifier == "app.relay.mac" {
            try? FileManager.default.trashItem(at: oldApp, resultingItemURL: nil)
        }
    }

    /// Running from a disk image or a temporary copy, and not told to stop asking.
    static var shouldOffer: Bool {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app"), !UserDefaults.standard.bool(forKey: "neverOfferMove") else { return false }
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    enum MoveError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let reason): reason
            }
        }
    }

    /// Copies Pulli to Applications, then quits; a small shell script opens the new copy and
    /// ejects the disk image once this one has gone.
    static func move() throws {
        let source = Bundle.main.bundleURL
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try manager.copyItem(at: source, to: destination)
        } catch {
            throw MoveError.failed("Pulli could not be copied to Applications (\(error.localizedDescription)). Drag it there in Finder instead.")
        }
        let volume = source.path.hasPrefix("/Volumes/") ? "/Volumes/" + source.path.dropFirst("/Volumes/".count).prefix { $0 != "/" } : ""
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/sh")
        script.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"; [ -n \"$3\" ] && /usr/bin/hdiutil detach \"$3\" -quiet",
                            "pulli-move", "\(ProcessInfo.processInfo.processIdentifier)", destination.path, volume]
        try? script.run()
        NSApp.terminate(nil)
    }
}

/// The offer: Pulli's icon travels into the Applications folder, over and over.
struct MoveToApplicationsView: View {
    var dismiss: () -> Void

    var body: some View {
        // The colours follow the system appearance inside (the content reads them).
        MoveOffer(dismiss: dismiss)
            .padding(28)
            .frame(width: 440)
            .background(SceneBackground(kind: .home, animated: false))
            .modifier(ToneProvider())
    }
}

private struct MoveOffer: View {
    var dismiss: () -> Void
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failure: String?
    @State private var moving = false

    var body: some View {
        VStack(spacing: 18) {
            TravelAnimation(still: reduceMotion)
                .frame(width: 360, height: 150)
            VStack(spacing: 6) {
                Text("Move Pulli to Applications?").font(.pulli(20, .bold))
                Text("Pulli is running from the disk image. In Applications it stays after the disk image is ejected, and you can open it from Launchpad or Spotlight.")
                    .font(.pulli(13)).foregroundStyle(tone.t2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure).font(.pulli(12.5)).foregroundStyle(tone.amber).multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button("Not Now") { dismiss() }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    moving = true
                    do { try InstallLocation.move() } catch {
                        failure = error.localizedDescription
                        moving = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if moving { ProgressView().controlSize(.small) }
                        Text("Move to Applications")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                .keyboardShortcut(.defaultAction)
                .disabled(moving)
            }
            Button("Don't ask again") {
                UserDefaults.standard.set(true, forKey: "neverOfferMove")
                dismiss()
            }
            .buttonStyle(InlineLinkStyle())
            .font(.pulli(12))
        }
    }
}

/// Pulli's icon lifts off, arcs over and drops into the Applications folder, which bulges as it
/// lands; then again.
private struct TravelAnimation: View {
    var still: Bool
    private let folder: NSImage = NSWorkspace.shared.icon(forFile: "/Applications")
    private let icon: NSImage = NSApp?.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    var body: some View {
        TimelineView(.animation(paused: still)) { context in
            let cycle = 2.6
            let t = still ? 0.0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            // 0-0.15 rest, 0.15-0.65 flight, 0.65-0.8 landing, 0.8-1 fade back in at the start.
            let flight = min(max((t - 0.15) / 0.5, 0), 1)
            let eased = flight < 0.5 ? 2 * flight * flight : 1 - pow(-2 * flight + 2, 2) / 2
            let start = CGPoint(x: 70, y: 82), end = CGPoint(x: 290, y: 88)
            let x = start.x + (end.x - start.x) * eased
            let y = start.y + (end.y - start.y) * eased - sin(eased * .pi) * 62
            let landed = t > 0.65
            let shrink = landed ? max(0.0, 1 - (t - 0.65) / 0.12) : 1
            let returning = t > 0.8 ? (t - 0.8) / 0.2 : 0
            let bulge = t > 0.63 && t < 0.8 ? 1 + 0.12 * sin((t - 0.63) / 0.17 * .pi) : 1
            ZStack {
                // The path it takes, faintly.
                Path { path in
                    path.move(to: start)
                    path.addQuadCurve(to: end, control: CGPoint(x: (start.x + end.x) / 2, y: start.y - 124))
                }
                .stroke(Color.accent.opacity(0.35), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [2, 8]))
                Image(nsImage: folder).resizable().frame(width: 96, height: 96)
                    .scaleEffect(bulge)
                    .position(end)
                Image(nsImage: icon).resizable().frame(width: 84, height: 84)
                    .scaleEffect(landed ? shrink * 0.8 + 0.2 : 1 - 0.15 * sin(eased * .pi))
                    .rotationEffect(.degrees(eased * 14 - 7 * sin(eased * .pi)))
                    .opacity(landed ? shrink : 1)
                    .position(x: x, y: y)
                // The next one fading in where it started.
                if returning > 0 {
                    Image(nsImage: icon).resizable().frame(width: 84, height: 84)
                        .opacity(returning)
                        .position(start)
                }
            }
        }
    }
}
