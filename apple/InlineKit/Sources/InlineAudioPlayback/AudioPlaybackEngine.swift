import Foundation

/// Minimal engine boundary around concrete audio playback.
///
/// The center owns state transitions; engines only load local URLs and expose
/// player timing. This keeps the observable layer testable and allows an
/// `AVPlayer` streaming engine later without changing UI state.
@MainActor
public protocol AudioPlaybackEngine: AnyObject {
  var currentTime: TimeInterval { get set }
  var duration: TimeInterval { get }
  var isPlaying: Bool { get }
  var playbackRate: Float { get set }
  var volume: Float { get set }
  var onFinish: ((TimeInterval) -> Void)? { get set }

  func load(contentsOf fileURL: URL) throws
  func prepare()
  func play() -> Bool
  func pause()
  func stop()
}
