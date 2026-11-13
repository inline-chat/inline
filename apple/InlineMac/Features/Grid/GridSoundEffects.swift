import AVFoundation
import Logger

@MainActor
final class GridSoundEffects {
  static let shared = GridSoundEffects()

  enum Effect: String {
    case join = "maybe-join"
    case leave = "unlock"
    case connected = "connected2"
    case microphoneOn = "grid-mic-on"
    case microphoneOff = "grid-mic-off"

    var volume: Float {
      switch self {
      case .join, .leave: 0.12
      case .connected: 0.7
      // The files carry their own quiet level, shared with iOS.
      case .microphoneOn, .microphoneOff: 1
      }
    }

    var fileExtension: String {
      switch self {
      case .join, .leave, .connected: "mp3"
      case .microphoneOn, .microphoneOff: "caf"
      }
    }
  }

  private let playback = GridSoundPlaybackEngine()

  private init() {
    Task { [playback] in await playback.preload(Effect.allCases) }
  }

  func play(_ effect: Effect) {
    Task { [playback] in await playback.play(effect) }
  }
}

extension GridSoundEffects.Effect: CaseIterable, Sendable {}

private actor GridSoundPlaybackEngine {
  private var players: [GridSoundEffects.Effect: AVAudioPlayer] = [:]
  private let log = Log.scoped("GridSoundEffects")

  func preload(_ effects: [GridSoundEffects.Effect]) {
    for effect in effects {
      do {
        guard players[effect] == nil, let url = soundURL(effect) else { continue }
        let player = try AVAudioPlayer(contentsOf: url)
        player.volume = effect.volume
        player.prepareToPlay()
        players[effect] = player
      } catch {
        log.error("Failed to preload Grid sound: \(effect.rawValue)", error: error)
      }
    }
  }

  func play(_ effect: GridSoundEffects.Effect) {
    do {
      let player: AVAudioPlayer
      if let prepared = players[effect] {
        player = prepared
      } else {
        guard let url = soundURL(effect) else {
          log.warning("Grid sound resource missing: \(effect.rawValue)")
          return
        }
        player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        players[effect] = player
      }
      player.currentTime = 0
      player.volume = effect.volume
      player.play()
    } catch {
      log.error("Failed to play Grid sound: \(effect.rawValue)", error: error)
    }
  }

  private func soundURL(_ effect: GridSoundEffects.Effect) -> URL? {
    let ext = effect.fileExtension
    return Bundle.main.url(forResource: effect.rawValue, withExtension: ext, subdirectory: "GridSounds")
      ?? Bundle.main.url(forResource: effect.rawValue, withExtension: ext, subdirectory: "Resources/GridSounds")
      ?? Bundle.main.url(forResource: effect.rawValue, withExtension: ext)
  }
}
