import AppKit
import PulliProtocol
import SwiftUI

// MARK: - Copying

struct CopyingView: View {
    var batch: BatchSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var confirmStop = false

    var body: some View {
        let scanning = batch.phase == .scanning
        let suggestion = model.state.devices[batch.deviceID]?.chunkSuggestion
        VStack(spacing: 16) {
            if let suggestion {
                ChunkSuggestionCard(suggestion: suggestion, deviceName: batch.deviceName)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 34) {
                HeroRing(fraction: batch.fractionDone, color: .accent) {
                    PhoneArt(width: 210, palette: .blue, screen: .photos, cable: .plugged, reveal: max(batch.fractionDone, 0.07))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(scanning ? "Looking through \(batch.title)…" : "Copying from \(batch.deviceName)…")
                        .font(.pulli(30, .regular)).tracking(-0.3).lineLimit(1).minimumScaleFactor(0.7)
                    // Two fixed lines of single-line chips: as the numbers grow nothing wraps, so the
                    // title above never jumps.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if batch.bytesPerSecond > 0 { Chip(text: Format.speed(batch.bytesPerSecond)).fixedSize() }
                            if let left = batch.secondsRemaining, !scanning { Chip(text: "\(Format.duration(left)) left").fixedSize() }
                            // Holds the line's height before the first speed and time are known.
                            Chip(text: " ").hidden().frame(width: 0)
                        }
                        Chip(text: scanning ? "\(Format.count(batch.filesTotal, "file")) found"
                             : "\(batch.filesDone.formatted()) of \(Format.count(batch.filesTotal, "file")) · \(Format.bytes(batch.bytesDone)) of \(Format.bytes(batch.bytesTotal))")
                            .fixedSize()
                    }
                    FileList(batch: batch).padding(.top, 4)
                    HStack(spacing: 10) {
                        cableHint
                        Spacer()
                        Button { Task { await model.control(batch.id, .pause) } } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(PillButtonStyle())
                        Button("Stop") { confirmStop = true }.buttonStyle(PillButtonStyle())
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel(radius: 26)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: suggestion)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
        .confirmationDialog("Stop this copy?", isPresented: $confirmStop) {
            Button("Stop Copy", role: .destructive) { Task { await model.control(batch.id, .cancel(discardPartialFiles: false)) } }
        } message: {
            Text("Files copied so far stay on your Mac. You can resume the copy later from History.")
        }
    }

    @ViewBuilder
    private var cableHint: some View {
        if let cable = model.state.devices[batch.deviceID]?.cable, cable.suggestion != .none, UserDefaults.standard.object(forKey: "suggestCable") as? Bool ?? true {
            let remaining = batch.bytesTotal > batch.bytesDone ? batch.bytesTotal - batch.bytesDone : 0
            HStack(spacing: 8) {
                Image(systemName: "cable.connector").foregroundStyle(tone.amber)
                if let faster = cable.duration(ofBytes: remaining).faster, remaining > 0 {
                    Text("\(Format.link(cable.link)) link: \(Format.about(faster)) with a USB 3 cable.")
                } else {
                    Text("\(Format.link(cable.link)) link: a USB 3 cable is faster.")
                }
            }
            .font(.pulli(12.5)).foregroundStyle(tone.t2)
        }
    }
}

/// Recently finished files, then the one being copied.
private struct FileList: View {
    var batch: BatchSnapshot
    @Environment(\.tone) private var tone

    var body: some View {
        VStack(spacing: 0) {
            let recent = Array(batch.recent.prefix(4).reversed())
            ForEach(recent, id: \.jobID) { file in row(file, now: false) }
            if let current = batch.current { row(current, now: true) }
            if recent.isEmpty && batch.current == nil {
                Text(batch.phase == .scanning ? "Finding files…" : "Starting…").font(.pulli(13.5)).foregroundStyle(tone.t2).frame(height: 48)
            }
        }
        // Room for all five rows from the start, so the screen does not shift as files finish.
        .frame(height: 5 * 48, alignment: .top)
        .animation(.easeInOut(duration: 0.3), value: batch.recent.first?.jobID)
    }

    private func row(_ file: FileSnapshot, now: Bool) -> some View {
        HStack(spacing: 14) {
            FileIcon(name: file.name, isFolder: false, size: 34)
            Text(file.name).font(.pulli(14.5, .medium)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(Format.bytes(file.sizeBytes)).font(.pulli(13.5)).foregroundStyle(tone.t2)
            Group {
                if now {
                    PieBadge(fraction: file.sizeBytes == 0 ? 0 : Double(file.bytesDone) / Double(file.sizeBytes), color: .copyBlue, size: 20)
                } else {
                    switch file.state {
                    case .done: Image(systemName: "checkmark").font(.system(size: 15, weight: .bold))
                    case .skipped: Image(systemName: "equal.circle").foregroundStyle(tone.t2).help("Already on your Mac")
                    case .needsAttention: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(tone.amber)
                    default: Circle().fill(tone.t3).frame(width: 9, height: 9)
                    }
                }
            }
            .frame(width: 22)
        }
        .monospacedDigit()
        .frame(height: 48)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Paused

struct PausedView: View {
    var batch: BatchSnapshot
    var reason: PauseReason
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var confirmStop = false

    var body: some View {
        let queued = reason == .queued
        let suggestion = model.state.devices[batch.deviceID]?.chunkSuggestion
        VStack(spacing: 16) {
            if let suggestion {
                ChunkSuggestionCard(suggestion: suggestion, deviceName: batch.deviceName)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack(spacing: 34) {
                HeroRing(fraction: batch.fractionDone, color: queued ? .accent : .pausedAmber, glow: false) {
                    PhoneArt(width: 210, palette: queued ? .blue : .amber, screen: queued ? .photos : .pause,
                             cable: reason == .phoneDisconnected ? .unplugged : .plugged)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text(headline).font(.pulli(30, .regular)).tracking(-0.3).fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(.pulli(15)).foregroundStyle(tone.t2).frame(maxWidth: 470, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: 0) {
                        fact("Finished", Format.count(batch.filesDone, "file"))
                        if let current = batch.current, current.bytesDone > 0 {
                            fact("Resumes from", "\(current.name) at \(Format.bytes(current.bytesDone))")
                        }
                        fact("Still to copy", "\(Format.count(max(batch.filesTotal - batch.filesDone - batch.filesSkipped, 0), "file")) · \(Format.bytes(batch.bytesTotal > batch.bytesDone ? batch.bytesTotal - batch.bytesDone : 0))")
                    }
                    .frame(maxWidth: 470)
                    HStack(spacing: 12) {
                        HStack(spacing: 9) {
                            GlowDot(color: queued ? .accent : .pausedAmber)
                            Text(status).font(.pulli(13)).foregroundStyle(tone.t2)
                        }
                        Spacer()
                        if reason == .byUser {
                            Button { Task { await model.control(batch.id, .resume) } } label: { Label("Resume", systemImage: "play.fill") }
                                .buttonStyle(PillButtonStyle(kind: .strong)).keyboardShortcut(.defaultAction)
                        }
                        if case .destinationFull = reason {
                            Button("Show Destination") { model.showInFinder(batch.destinationPath) }.buttonStyle(PillButtonStyle())
                        }
                        Button("Stop") { confirmStop = true }.buttonStyle(PillButtonStyle())
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(.horizontal, 36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .panel(radius: 26)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: suggestion)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
        .confirmationDialog("Stop this copy?", isPresented: $confirmStop) {
            Button("Stop Copy", role: .destructive) { Task { await model.control(batch.id, .cancel(discardPartialFiles: false)) } }
        } message: {
            Text("Files copied so far stay on your Mac.")
        }
    }

    private var headline: String {
        let phone = batch.deviceName
        return switch reason {
        case .byUser: "Paused"
        case .phoneDisconnected: "Reconnect \(phone) to continue"
        case .phoneLocked: "Unlock \(phone) to continue"
#if PULLI_APP_STORE
        case .notInFileTransferMode: "Choose \u{201C}Transferring images\u{201D} on \(phone)"
#else
        case .notInFileTransferMode: "Choose \u{201C}File transfer\u{201D} on \(phone)"
#endif
        case .heldBy(let app): "\(app) is using \(phone)"
        case .destinationFull: "Your Mac needs more space"
        case .destinationUnavailable: "The destination is not available"
        case .retrying(let seconds, _): "Trying again in \(Format.duration(Double(seconds)))"
        case .queued: "Waiting for the copy before it"
        case .unknown: "Paused"
        }
    }

    private var detail: String {
        switch reason {
        case .byUser: "Nothing is lost. Resume whenever you like; Pulli carries on from where it stopped."
        case .phoneDisconnected: "The phone was unplugged. Everything copied so far is safe on your Mac. Plug it back in, into any port, and Pulli carries on by itself."
        case .phoneLocked: "The phone locked before Pulli could open it. Unlock it and the copy continues."
#if PULLI_APP_STORE
        case .notInFileTransferMode: "The phone switched to charging only. Swipe down, tap the USB notification and choose Transferring images (also called PTP)."
#else
        case .notInFileTransferMode: "The phone switched to charging only. Swipe down, tap the USB notification and choose File transfer."
#endif
        case .heldBy(let app): "Quit \(app) and the copy continues straight away."
        case .destinationFull: "The destination disk is full. Free up some space and Pulli continues by itself."
        case .destinationUnavailable(let detail): "Pulli cannot write to \(Format.place(batch.destinationPath)): \(detail). Reconnect the disk or choose another place."
        case .retrying(_, let detail): "The phone did not answer (\(detail)). Pulli tries again by itself."
        case .queued: "One phone copies one thing at a time. This copy starts as soon as the one before it finishes."
        case .unknown: "Pulli continues by itself when it can."
        }
    }

    private var status: String {
        switch reason {
        case .byUser: "Paused by you"
        case .phoneDisconnected: "Waiting for \(batch.deviceName) · the Mac stays awake"
        case .queued: "In line"
        default: "Waiting"
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(tone.t2)
            Spacer(minLength: 16)
            Text(value).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
        }
        .font(.pulli(14)).monospacedDigit()
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1) }
    }
}

// MARK: - Done

struct DoneView: View {
    var batch: BatchSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @Environment(\.openWindow) private var openWindow
    @State private var appeared = false

    var body: some View {
        let completed = batch.phase == .completed
        ZStack(alignment: .topLeading) {
            Gem(form: .disc, palette: completed ? .green : .slate, symbol: completed ? "checkmark" : "stop.fill", size: 300, face: true)
                .scaleEffect(appeared ? 1 : 0.7)
                .opacity(appeared ? 1 : 0)
                .offset(x: 30, y: 70)
            VStack(alignment: .leading, spacing: 22) {
                Text(completed ? "Copy complete!" : "Copy stopped").font(.pulli(36, .medium))
                VStack(alignment: .leading, spacing: 16) {
                    result(Gem(form: .disc, palette: .green, symbol: "arrow.down.to.line", size: 46),
                           "\(Format.count(batch.filesDone, "file")) · \(Format.bytes(batch.bytesDone))",
                           completed ? "safely copied to \(Format.place(batch.destinationPath))" : "copied to \(Format.place(batch.destinationPath)) before you stopped")
                    if batch.filesSkipped > 0 {
                        result(Gem(form: .disc, palette: .sky, symbol: "equal", size: 46), "\(Format.count(batch.filesSkipped, "file")) already there",
                               "identical copies were on your Mac, so Pulli left them")
                    }
                    if batch.filesNeedingAttention > 0 {
                        result(Gem(form: .disc, palette: .amber, symbol: "exclamationmark", size: 46),
                               "\(Format.count(batch.filesNeedingAttention, "file")) need\(batch.filesNeedingAttention == 1 ? "s" : "") attention",
                               "Pulli could not copy \(batch.filesNeedingAttention == 1 ? "it" : "them")", link: ("Review", { model.show(.attention) }))
                    }
                }
                Text(stats).font(.pulli(13)).foregroundStyle(tone.t3).monospacedDigit()
#if !PULLI_APP_STORE
                if completed, batch.filesDone > 0, model.state.devices[batch.deviceID] != nil {
                    // Free up space: offered only after a finished copy, with the phone connected.
                    HStack(spacing: 14) {
                        Gem(form: .disc, palette: .violet, symbol: "checkmark.shield.fill", size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Free up \(Format.bytes(batch.bytesDone)) on \(batch.deviceName)").font(.pulli(15, .semibold))
                            Text("Pulli checks every copy against the phone first, then asks before deleting.").font(.pulli(12.5)).foregroundStyle(tone.t2)
                        }
                        Spacer(minLength: 8)
                        Button("Free Up Space…") { model.startFreeUp(batch) }.buttonStyle(PillButtonStyle(small: true))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .panel(radius: 16, tint: Color(hex: 0xB17BFF, opacity: 0.18))
                }
#endif
            }
            .padding(.leading, 380).padding(.trailing, 40).padding(.top, 92)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) {
            Button("View Log") { openWindow(id: "activity") }.buttonStyle(.plain).font(.pulli(13.5, .semibold)).padding(30)
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 10) {
                if !completed {
                    Button("Resume Copy") { Task { await model.control(batch.id, .resume) } }.buttonStyle(PillButtonStyle())
                }
                Button { model.showInFinder(batch.destinationPath) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(PillButtonStyle())
                Button("Done") {
                    model.focusedBatchID = nil
                    model.show(.phone)
                }
                .buttonStyle(PillButtonStyle(kind: .strong)).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.62).delay(0.1)) { appeared = true } }
    }

    private var stats: String {
        var parts: [String] = []
        if let finished = batch.finishedAt { parts.append(Format.duration(finished.timeIntervalSince(batch.createdAt))) }
        if let finished = batch.finishedAt, batch.bytesDone > 0 {
            let seconds = max(finished.timeIntervalSince(batch.createdAt), 1)
            parts.append("average \(Format.speed(Double(batch.bytesDone) / seconds))")
        }
        parts.append("from \(batch.deviceName)")
        return parts.joined(separator: " · ")
    }

    private func result(_ gem: Gem, _ big: String, _ small: String, link: (String, () -> Void)? = nil) -> some View {
        HStack(spacing: 14) {
            gem
            VStack(alignment: .leading, spacing: 2) {
                Text(big).font(.pulli(18, .semibold)).monospacedDigit()
                HStack(spacing: 0) {
                    Text(small).foregroundStyle(tone.t2)
                    if let link {
                        Text(" · ").foregroundStyle(tone.t2)
                        Button(link.0, action: link.1).buttonStyle(InlineLinkStyle())
                    }
                }
                .font(.pulli(13.5))
            }
        }
    }
}

struct NoCopiesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        VStack(spacing: 18) {
            Gem(form: .squircle, palette: .blue, symbol: "arrow.down.to.line", size: 140, tilt: -6)
            Text("No copies yet").font(.pulli(28, .medium))
            Text("Pick what to copy on the phone screen. Copies you start appear here.").font(.pulli(14.5)).foregroundStyle(tone.t2)
            Button("Go to Phone") { model.show(.phone) }.buttonStyle(PillButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
