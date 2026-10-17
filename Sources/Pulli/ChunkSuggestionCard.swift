import PulliProtocol
import SwiftUI

/// Offers a smaller read chunk when a phone struggles with large transfers.
struct ChunkSuggestionCard: View {
    var suggestion: ChunkSuggestion
    var deviceName: String
    @Environment(AppModel.self) private var model
    @Environment(\.tone) private var tone

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Gem(form: .disc, palette: .amber, symbol: "gauge.with.dots.needle.33percent", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(deviceName) keeps failing to read \(suggestion.currentMiB) MB at a time")
                    .font(.pulli(15, .semibold))
                    .foregroundStyle(tone.t1)
                Text("Older phones often copy more steadily in smaller pieces. It is a little slower, and nothing copied so far is lost.")
                    .font(.pulli(13))
                    .foregroundStyle(tone.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 8) {
                Button("Use \(suggestion.suggestedMiB) MB for This Phone") {
                    Task { await model.applyChunkSuggestion(deviceID: suggestion.deviceID, accept: true) }
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
                Button("Not Now") {
                    Task { await model.applyChunkSuggestion(deviceID: suggestion.deviceID, accept: false) }
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .panel(radius: 18)
    }
}
