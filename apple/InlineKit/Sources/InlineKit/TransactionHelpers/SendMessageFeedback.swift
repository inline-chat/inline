import Foundation

#if os(iOS)
import UIKit
#endif

@MainActor
class SendMessageFeedback {
  static let shared = SendMessageFeedback()

  private init() {}

  private var feedbackPlaying = false

  func playHapticFeedback() {
    guard !feedbackPlaying else {
      return
    }

    feedbackPlaying = true

    #if os(iOS)
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    generator.impactOccurred(intensity: 1.0)
    #endif

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
      self.feedbackPlaying = false
    }
  }

  // and play sound
  // let sound = try! AVAudioPlayer(contentsOf: Bundle.main.url(forResource: "send", withExtension: "mp3")!)
  // sound.play()
}
