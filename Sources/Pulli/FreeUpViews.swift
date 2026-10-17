import PulliProtocol
import SwiftUI

/// Free up space on the phone (D-022): check every copy against the phone, then a clear
/// confirmation, then a summary. The only place in Pulli that deletes anything.
struct FreeUpView: View {
    var batch: BatchSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        let state = model.freeUp
        ZStack {
            switch state?.stage {
            case .checking?, nil:
                checking(state?.progress)
            case .confirm?:
                if let progress = state?.progress, progress.identical > 0 {
                    checking(progress).opacity(0.35).allowsHitTesting(false)
                    ConfirmFreeUp(batch: batch, progress: progress)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                } else {
                    nothingToFree(state?.progress)
                }
            case .deleting?:
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("Deleting the checked originals from \(batch.deviceName)…").font(.pulli(16, .medium))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panel(radius: 26)
                .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
            case .done(let summary)?:
                FreedSummary(batch: batch, summary: summary, problems: state?.progress?.problems ?? [])
            case .failed(let message)?:
                VStack(spacing: 14) {
                    Gem(form: .disc, palette: .amber, symbol: "exclamationmark", size: 110)
                    Text("Pulli stopped before deleting anything").font(.pulli(24, .medium))
                    Text(message).font(.pulli(14)).foregroundStyle(tone.t2).multilineTextAlignment(.center).frame(maxWidth: 460)
                    Button("Done") { model.closeFreeUp() }.buttonStyle(PillButtonStyle(kind: .strong))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .panel(radius: 26)
                .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: stageKey(state))
    }

    private func stageKey(_ state: FreeUpState?) -> Int {
        switch state?.stage {
        case .checking?, nil: 0
        case .confirm?: 1
        case .deleting?: 2
        case .done?: 3
        case .failed?: 4
        }
    }

    private func checking(_ progress: VerifyProgress?) -> some View {
        let fraction = progress.map { $0.bytesTotal == 0 ? 0 : Double($0.bytesChecked) / Double($0.bytesTotal) } ?? 0
        return HStack(spacing: 34) {
            HeroRing(fraction: fraction, color: Color(hex: 0xB17BFF)) {
                Gem(form: .disc, palette: .violet, symbol: "checkmark.shield.fill", size: 190)
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("Checking copies before freeing space…").font(.pulli(28, .regular)).fixedSize(horizontal: false, vertical: true)
                Text("Pulli reads each file again from the phone and compares it with the copy on your Mac, byte for byte. Nothing is deleted yet.")
                    .font(.pulli(14.5)).foregroundStyle(tone.t2).frame(maxWidth: 480, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if let progress {
                    HStack(spacing: 8) {
                        Chip(text: "\(progress.identical) of \(progress.filesTotal) identical")
                        Chip(text: "\(Format.bytes(progress.bytesChecked)) of \(Format.bytes(progress.bytesTotal))")
                        if !progress.problems.isEmpty { Chip(text: "\(progress.problems.count) not identical", color: tone.amber, fill: tone.amberFill) }
                    }
                    VStack(spacing: 0) {
                        if let current = progress.current {
                            row(current, nil, status: "Checking…", color: tone.t1)
                        }
                        ForEach(Array(progress.recent.prefix(4).enumerated()), id: \.offset) { _, item in
                            row(item.name, item.sizeBytes, status: label(item.result), color: item.result == .identical ? tone.green : tone.amber)
                        }
                    }
                } else {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Starting…").font(.pulli(13.5)) }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { model.closeFreeUp() }.buttonStyle(PillButtonStyle())
                }
            }
            .frame(maxWidth: 540, alignment: .leading)
        }
        .padding(.horizontal, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
    }

    private func row(_ name: String, _ size: UInt64?, status: String, color: Color) -> some View {
        HStack(spacing: 12) {
            FileIcon(name: name, isFolder: false, size: 30)
            Text(name).font(.pulli(14, .medium)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let size { Text(Format.bytes(size)).font(.pulli(13)).foregroundStyle(tone.t2) }
            Text(status).font(.pulli(12.5, .semibold)).foregroundStyle(color).frame(width: 120, alignment: .trailing)
        }
        .monospacedDigit()
        .frame(height: 42)
        .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1) }
    }

    private func label(_ result: VerifyProgress.Item.Result) -> String {
        switch result {
        case .identical: "✓ Identical"
        case .different: "Different"
        case .missingOnPhone: "Gone from phone"
        case .missingOnMac: "Missing on Mac"
        }
    }

    private func nothingToFree(_ progress: VerifyProgress?) -> some View {
        VStack(spacing: 14) {
            Gem(form: .disc, palette: .amber, symbol: "exclamationmark", size: 110)
            Text("Nothing can be freed yet").font(.pulli(26, .medium))
            Text("None of the copies matched the phone byte for byte, so Pulli leaves every original where it is. Copy them again, then try once more.")
                .font(.pulli(14)).foregroundStyle(tone.t2).multilineTextAlignment(.center).frame(maxWidth: 480)
            if let progress, !progress.problems.isEmpty {
                Text(progress.problems.prefix(3).map(\.name).joined(separator: ", ") + (progress.problems.count > 3 ? " and \(progress.problems.count - 3) more" : ""))
                    .font(.pulli(12.5)).foregroundStyle(tone.t3)
            }
            Button("Done") { model.closeFreeUp() }.buttonStyle(PillButtonStyle(kind: .strong))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
    }
}

/// The confirmation: what will be deleted, what stays, and an "I understand" tick before the
/// red button works.
private struct ConfirmFreeUp: View {
    var batch: BatchSnapshot
    var progress: VerifyProgress
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Gem(form: .disc, palette: .amber, symbol: "trash.fill", size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete \(Format.count(progress.identical, "original")) from \(batch.deviceName)?").font(.pulli(22, .bold))
                    Text("This frees \(Format.bytes(progress.identicalBytes)) on the phone.").font(.pulli(13.5)).foregroundStyle(tone.t2)
                }
            }
            VStack(spacing: 0) {
                line("checkmark.shield", tone.green, "Checked and identical on your Mac", "\(Format.count(progress.identical, "file")) · \(Format.bytes(progress.identicalBytes))")
                if !progress.problems.isEmpty {
                    line("exclamationmark.triangle", tone.amber, "Kept on the phone (not identical, or missing)", Format.count(progress.problems.count, "file"))
                }
                line("folder", tone.t2, "Your copies stay in", Format.place(batch.destinationPath))
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tone.separator))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Button { understood.toggle() } label: {
                HStack(alignment: .top, spacing: 10) {
                    CheckBox(state: understood ? .on : .off)
                    Text("I understand the originals are removed from the phone. Pulli cannot undo this.")
                        .font(.pulli(13.5)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(understood ? .isSelected : [])
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { model.closeFreeUp() }.buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Delete \(Format.count(progress.identical, "File")) from Phone") { model.confirmFreeUp() }
                    .buttonStyle(DestructiveButtonStyle())
                    .disabled(!understood)
            }
        }
        .padding(26)
        .frame(width: 580)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(tone.dark ? Color(hex: 0x1E2340) : Color(hex: 0xF7F5FF)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tone.panelBorder))
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
    }

    private func line(_ symbol: String, _ color: Color, _ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(label)
            Spacer(minLength: 12)
            Text(value).fontWeight(.semibold).lineLimit(1)
        }
        .font(.pulli(13.5)).monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(tone.separator).frame(height: 1).opacity(label.hasPrefix("Checked") ? 0 : 1) }
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pulli(13, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hex: 0xE5484D)))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

private struct FreedSummary: View {
    var batch: BatchSnapshot
    var summary: DeleteSummary
    var problems: [VerifyProgress.Item]
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Gem(form: .disc, palette: .violet, symbol: "checkmark", size: 300, face: true)
                .scaleEffect(appeared ? 1 : 0.7).opacity(appeared ? 1 : 0)
                .offset(x: 30, y: 70)
            VStack(alignment: .leading, spacing: 22) {
                Text("\(Format.bytes(summary.bytesFreed)) freed on \(batch.deviceName)").font(.pulli(34, .medium))
                VStack(alignment: .leading, spacing: 16) {
                    item(.violet, "trash.fill", "\(Format.count(summary.deleted, "original")) deleted", "each one checked against its copy on your Mac first")
                    item(.green, "folder.fill", "Your copies are safe", "in \(Format.place(batch.destinationPath))")
                    let kept = summary.kept.count + problems.count
                    if kept > 0 {
                        item(.amber, "exclamationmark", "\(Format.count(kept, "file")) kept on the phone", "not identical, changed, or missing on one side")
                    }
                }
            }
            .padding(.leading, 380).padding(.trailing, 40).padding(.top, 96)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 10) {
                Button { model.showInFinder(batch.destinationPath) } label: { Label("Show in Finder", systemImage: "folder") }.buttonStyle(PillButtonStyle())
                Button("Done") { model.closeFreeUp() }.buttonStyle(PillButtonStyle(kind: .strong)).keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .panel(radius: 26)
        .padding(.horizontal, 40).padding(.top, 24).padding(.bottom, 40)
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.62).delay(0.1)) { appeared = true } }
    }

    private func item(_ palette: ArtPalette, _ symbol: String, _ big: String, _ small: String) -> some View {
        HStack(spacing: 14) {
            Gem(form: .disc, palette: palette, symbol: symbol, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(big).font(.pulli(18, .semibold)).monospacedDigit()
                Text(small).font(.pulli(13.5)).foregroundStyle(tone.t2)
            }
        }
    }
}
