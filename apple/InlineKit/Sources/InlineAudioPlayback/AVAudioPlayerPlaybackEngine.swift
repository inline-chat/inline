import AVFoundation
import Foundation

/// Local-file playback engine backed by `AVAudioPlayer`.
@MainActor
public final class AVAudioPlayerPlaybackEngine: NSObject, AudioPlaybackEngine, AVAudioPlayerDelegate {
  public var onFinish: ((TimeInterval) -> Void)?

  public var currentTime: TimeInterval {
    get { player?.currentTime ?? 0 }
    set { player?.currentTime = newValue }
  }

  public var duration: TimeInterval {
    player?.duration ?? 0
  }

  public var isPlaying: Bool {
    player?.isPlaying ?? false
  }

  public var playbackRate: Float = 1 {
    didSet {
      player?.enableRate = true
      player?.rate = playbackRate
    }
  }

  public var volume: Float = 1 {
    didSet {
      player?.volume = volume
    }
  }

  private var player: AVAudioPlayer?

  override public init() {
    super.init()
  }

  public func load(contentsOf fileURL: URL) throws {
    let nextPlayer = try AVAudioPlayer(contentsOf: fileURL)
    nextPlayer.delegate = self
    nextPlayer.enableRate = true
    nextPlayer.rate = playbackRate
    nextPlayer.volume = volume
    player = nextPlayer
  }

  public func prepare() {
    player?.prepareToPlay()
  }

  public func play() -> Bool {
    player?.play() ?? false
  }

  public func pause() {
    player?.pause()
  }

  public func stop() {
    player?.stop()
    player = nil
  }

  nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully _: Bool) {
    let duration = player.duration
    Task { @MainActor [weak self] in
      self?.onFinish?(duration)
    }
  }
}
