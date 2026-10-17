import AVFoundation
import Foundation

/// Pulli's sound cues (docs/DECISIONS.md, D-018). Short, soft, never one per file:
/// at most one cue per second, silent when the Mac's interface sounds are off.
@MainActor
final class SoundPlayer {
    enum Cue: String, CaseIterable, Sendable {
        case connect, start, pause, resume, done, attention, intro, begin

        var title: String {
            switch self {
            case .connect: "Phone plugged in"
            case .start: "Copy started"
            case .pause: "Paused"
            case .resume: "Resumed"
            case .done: "Copy finished"
            case .attention: "Needs attention"
            case .intro: "Introduction"
            case .begin: "Get Started"
            }
        }

        /// The Settings switch that silences just this cue.
        var settingKey: String { "sound.\(rawValue)" }
    }

    private var players: [Cue: AVAudioPlayer] = [:]
    private var lastPlayed = Date.distantPast

    init() {
        for cue in Cue.allCases {
            guard let url = Resources.bundle?.url(forResource: cue.rawValue, withExtension: "wav", subdirectory: "Sounds"),
                  let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[cue] = player
        }
    }

    static var soundsEnabled: Bool { UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true }
    static var volume: Float { Float(UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 0.7) }

    /// The Mac's "Play user interface sound effects" setting.
    static var systemInterfaceSoundsOn: Bool {
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        return (global?["com.apple.sound.uiaudio.enabled"] as? Int ?? 1) != 0
    }

    func play(_ cue: Cue, force: Bool = false) {
        guard force || Self.soundsEnabled else { return }
        if !force {
            guard Self.systemInterfaceSoundsOn,
                  UserDefaults.standard.object(forKey: cue.settingKey) as? Bool ?? (cue != .start) else { return }
            // A phone plugged in is rare and the one cue people wait for: never swallowed.
            guard cue == .connect || Date().timeIntervalSince(lastPlayed) >= 1 else { return }
        }
        guard let player = players[cue] else { return }
        lastPlayed = Date()
        // The connect chime a little louder than the rest: it is heard from across the desk.
        player.volume = min(1, Self.volume * (cue == .connect ? 1.3 : 1))
        player.currentTime = 0
        player.play()
    }
}
