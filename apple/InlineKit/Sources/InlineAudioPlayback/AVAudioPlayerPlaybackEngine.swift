import AVFoundation
import Foundation

/// Local-file playback engine backed by `AVAudioPlayer`.
@MainActor
public final class AVAudioPlayerPlaybackEngine: NSObject, AudioPlaybackEngine, AVAudioPlayerDelegate {
  public var onFinish: ((TimeInterval) -> Void)?
  public var onFailure: (() -> Void)?

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

  private(set) var player: AVAudioPlayer?

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

  public func prepare() throws {
    guard player?.prepareToPlay() == true else { throw AudioPlaybackError.preparationFailed }
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

  nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard let self, let current = self.player, ObjectIdentifier(current) == identity, !current.isPlaying else { return }
      if flag { onFinish?(current.duration) } else { onFailure?() }
    }
  }

  nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error _: Error?) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
      onFailure?()
    }
  }
}
