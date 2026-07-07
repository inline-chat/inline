import Foundation

/// Observable value state for global audio playback.
///
/// Keep this as lightweight data. Playback ownership and AVFoundation details
/// live in `AudioPlaybackCenter` and `AudioPlaybackEngine`.
public struct AudioPlaybackState: Equatable, Sendable {
  public var item: AudioPlaybackItem?
  public var sourceURL: URL?
  public var display: AudioPlaybackDisplay?
  public var openTarget: AudioPlaybackOpenTarget?
  public var isPlaying: Bool
  public var currentTime: TimeInterval
  public var duration: TimeInterval
  public var playbackRate: Float
  public var volume: Float

  public init(
    item: AudioPlaybackItem? = nil,
    sourceURL: URL? = nil,
    display: AudioPlaybackDisplay? = nil,
    openTarget: AudioPlaybackOpenTarget? = nil,
    isPlaying: Bool = false,
    currentTime: TimeInterval = 0,
    duration: TimeInterval = 0,
    playbackRate: Float = 1,
    volume: Float = 1
  ) {
    self.item = item
    self.sourceURL = sourceURL
    self.display = display
    self.openTarget = openTarget
    self.isPlaying = isPlaying
    self.currentTime = currentTime
    self.duration = duration
    self.playbackRate = playbackRate
    self.volume = volume
  }
}
