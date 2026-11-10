import AVFoundation
import UIKit

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

/// Leises Umblättergeräusch. Respektiert den Stummschalter.
@MainActor
final class PageSound {
    static let shared = PageSound()
    private var player: AVAudioPlayer?

    private init() {
        guard let url = Bundle.main.url(forResource: "seite", withExtension: "wav") else { return }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.35
        player?.prepareToPlay()
    }

    func play() {
        guard UserDefaults.standard.bool(forKey: "pageSound"), let player else { return }
        player.currentTime = 0
        player.play()
    }
}
