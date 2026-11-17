import AVFoundation
import InlineKit
import Logger
import UIKit

/// Plays one gallery video and owns the shared audio session while it has audible playback.
///
/// The session rules are carried over from the previous viewer: a video with audio must hold
/// `InlineAudioSession` before it plays, a muted or silent video never takes it, and the
/// session is released as soon as playback pauses, ends, or fails.
@MainActor
final class MediaGalleryVideoPlayer {
  let player: AVPlayer
  let url: URL
  /// Serves the player from the video's native download; nil when it plays `url` directly.
  let stream: NativeVideoStream?
  /// Called when play state, time, or readiness changes.
  var onUpdate: (() -> Void)?
  /// Starts over at the end instead of pausing, for short clips.
  var loops = false

  /// Mute and speed carry from one video to the next for the rest of the app session.
  static var prefersMuted = false
  static var preferredRate: Float = 1
  static let rates: [Float] = [0.5, 1, 1.25, 1.5, 2]

  private(set) var isStopped = false
  /// A seek asked for before the item could take it, applied once it's ready.
  private var pendingSeek: Double?
  private var hasAudio: Bool?
  private var wantsPlay = false
  private var sessionToken: InlineAudioSession.Token?
  private var sessionIsStarting = false
  private var pauseForActivation = false
  private var observations: [NSKeyValueObservation] = []
  private var endObserver: NSObjectProtocol?
  private var timeObserver: Any?

  /// The duration from the message, used before the item has loaded its own.
  private let fallbackDuration: Double

  init(url: URL, stream: NativeVideoStream? = nil, fallbackDuration: Double = 0) {
    self.url = url
    self.stream = stream
    self.fallbackDuration = fallbackDuration
    let asset = stream?.asset ?? AVURLAsset(url: url)
    player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    player.actionAtItemEnd = .pause
    player.isMuted = Self.prefersMuted
    player.defaultRate = Self.preferredRate
    observe()

    Task { @MainActor [weak self] in
      let hasAudio: Bool
      do {
        hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
      } catch {
        Log.shared.warning("Failed to inspect video audio tracks: \(error.localizedDescription)")
        // Unknown metadata must reserve audio before allowing playback.
        hasAudio = true
      }
      guard let self, !self.isStopped else { return }
      self.hasAudio = hasAudio
      if self.wantsPlay {
        self.play()
      }
    }
  }

  var isPlaying: Bool {
    wantsPlay || player.timeControlStatus != .paused
  }

  /// Waiting on data (or on track inspection) while playback was asked for.
  var isBuffering: Bool {
    guard !hasFailed else { return false }
    if wantsPlay { return true }
    return player.timeControlStatus == .waitingToPlayAtSpecifiedRate
      && player.reasonForWaitingToPlay != .noItemToPlay
      && !sessionIsStarting
  }

  var isFailed: Bool {
    hasFailed
  }

  /// Paused on the last frame after playing through.
  var isAtEnd: Bool {
    guard !isPlaying, duration > 0 else { return false }
    return currentTime >= duration - 0.1
  }

  var isMuted: Bool {
    get { player.isMuted }
    set {
      player.isMuted = newValue
      Self.prefersMuted = newValue
      onUpdate?()
    }
  }

  var rate: Float {
    get { player.defaultRate }
    set {
      Self.preferredRate = newValue
      player.defaultRate = newValue
      if player.timeControlStatus != .paused {
        player.rate = newValue
      }
      onUpdate?()
    }
  }

  var currentTime: Double {
    let seconds = player.currentTime().seconds
    return seconds.isFinite ? seconds : 0
  }

  var duration: Double {
    let seconds = player.currentItem?.duration.seconds ?? 0
    return seconds.isFinite ? seconds : 0
  }

  func play() {
    guard !isStopped else { return }
    wantsPlay = true
    guard hasAudio != nil else {
      onUpdate?()
      return
    }
    if let item = player.currentItem, item.duration.isNumeric,
       CMTimeCompare(player.currentTime(), item.duration) >= 0
    {
      player.seek(to: .zero)
    }
    wantsPlay = false
    if acquireSession() {
      player.play()
    }
    onUpdate?()
  }

  func pause() {
    wantsPlay = false
    player.pause()
    onUpdate?()
  }

  func togglePlayback() {
    isPlaying ? pause() : play()
  }

  /// Jumps by `seconds`, staying inside the video.
  func skip(by seconds: Double) {
    let length = duration > 0 ? duration : fallbackDuration
    guard length > 0 else { return }
    seek(toSeconds: min(max(0, currentTime + seconds), length))
  }

  /// Seeks to a time; before the item is ready, the seek waits for it.
  func seek(toSeconds seconds: Double) {
    guard player.currentItem?.status == .readyToPlay else {
      pendingSeek = seconds
      return
    }
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    onUpdate?()
  }

  /// Seeks to a fraction of the video. While a scrub is still moving, a loose seek lands on
  /// a nearby keyframe so the picture keeps up; the final seek is exact.
  func seek(to fraction: Double, exact: Bool = true) {
    let length = duration > 0 ? duration : fallbackDuration
    guard length > 0 else { return }
    let target = CMTime(seconds: length * max(0, min(1, fraction)), preferredTimescale: 600)
    let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
    player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance)
    onUpdate?()
  }

  func stop() {
    guard !isStopped else { return }
    isStopped = true
    wantsPlay = false
    observations.forEach { $0.invalidate() }
    observations.removeAll()
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    player.pause()
    player.replaceCurrentItem(with: nil)
    stream?.close()
    releaseSession()
  }

  isolated deinit {
    stop()
  }

  // MARK: - Observation

  private func observe() {
    observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, change in
      let status = change.newValue
      Task { @MainActor [weak self] in
        self?.updateSession(observedStatus: status)
        self?.onUpdate?()
      }
    })
    observations.append(player.observe(\.isMuted, options: [.new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.updateSession() }
    })
    observations.append(player.observe(\.status, options: [.new]) { [weak self] _, change in
      guard change.newValue == .failed else { return }
      Task { @MainActor [weak self] in self?.updateSession() }
    })
    if let item = player.currentItem {
      observations.append(item.observe(\.status, options: [.new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if player.currentItem?.status == .readyToPlay, let seconds = pendingSeek {
            pendingSeek = nil
            seek(toSeconds: seconds)
          }
          updateSession()
          onUpdate?()
        }
      })
      endObserver = NotificationCenter.default.addObserver(
        forName: AVPlayerItem.didPlayToEndTimeNotification,
        object: item,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, !self.isStopped else { return }
          if self.loops {
            self.player.seek(to: .zero)
            self.player.play()
            return
          }
          self.player.pause()
          self.releaseSession()
          self.onUpdate?()
        }
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onUpdate?() }
    }
  }

  // MARK: - Audio session

  private var hasFailed: Bool {
    player.status == .failed || player.currentItem?.status == .failed
  }

  private func updateSession(observedStatus: AVPlayer.TimeControlStatus? = nil) {
    guard !isStopped else { return }
    // A failed item can remain waiting with a desired nonzero rate.
    guard !hasFailed else {
      if player.timeControlStatus != .paused { player.pause() }
      releaseSession()
      return
    }
    // Playback can be requested while track inspection is pending.
    guard let hasAudio else {
      if player.timeControlStatus != .paused { player.pause() }
      releaseSession()
      return
    }
    guard hasAudio, !player.isMuted else {
      releaseSession()
      return
    }
    if sessionIsStarting {
      if observedStatus == .paused {
        if pauseForActivation { pauseForActivation = false } else { releaseSession() }
      } else {
        pauseUntilActivation()
      }
      return
    }
    // Buffering is still an active playback request; keep ownership until paused.
    guard player.timeControlStatus != .paused else {
      releaseSession()
      return
    }
    if !acquireSession() {
      pauseUntilActivation()
    }
  }

  /// Returns true when playback may start now. When the session is still activating,
  /// playback starts on its own once activation finishes.
  private func acquireSession() -> Bool {
    guard !hasFailed else {
      if player.timeControlStatus != .paused { player.pause() }
      releaseSession()
      return false
    }
    guard let hasAudio else { return false }
    guard hasAudio, !player.isMuted else {
      releaseSession()
      return true
    }
    let session = InlineAudioSession.shared
    if let sessionToken, session.owns(sessionToken) { return !sessionIsStarting }

    do {
      let token = try session.acquire(.video)
      sessionToken = token
      sessionIsStarting = true
      pauseUntilActivation()
      Task { @MainActor [weak self] in
        do {
          try await session.activate(token, category: .playback, mode: .moviePlayback)
          guard let self, !self.isStopped, self.sessionToken == token, self.sessionIsStarting,
                session.owns(token), !Task.isCancelled, self.hasAudio == true, !self.player.isMuted,
                !self.hasFailed
          else {
            session.release(token)
            if let self, self.sessionToken == token { self.releaseSession() }
            return
          }
          self.sessionIsStarting = false
          self.pauseForActivation = false
          self.player.play()
        } catch {
          session.release(token)
          guard let self, !self.isStopped, self.sessionToken == token else { return }
          self.releaseSession()
          self.player.pause()
          if !(error is CancellationError) { Self.report(error) }
        }
      }
      return false
    } catch {
      releaseSession()
      Self.report(error)
      return false
    }
  }

  private func pauseUntilActivation() {
    guard player.timeControlStatus != .paused else { return }
    if sessionIsStarting { pauseForActivation = true }
    player.pause()
  }

  private func releaseSession() {
    sessionIsStarting = false
    pauseForActivation = false
    guard let sessionToken else { return }
    self.sessionToken = nil
    InlineAudioSession.shared.release(sessionToken)
  }

  private static func report(_ error: Error) {
    Log.shared.warning("Failed to acquire audio session for video: \(error.localizedDescription)")
    ToastManager.shared.showToast(
      error.localizedDescription,
      type: .error,
      systemImage: "exclamationmark.triangle.fill"
    )
  }
}

/// A view backed by an `AVPlayerLayer`.
final class MediaGalleryPlayerView: UIView {
  override static var layerClass: AnyClass {
    AVPlayerLayer.self
  }

  var playerLayer: AVPlayerLayer {
    // swiftlint:disable:next force_cast
    layer as! AVPlayerLayer
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    playerLayer.videoGravity = .resizeAspect
    isUserInteractionEnabled = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
