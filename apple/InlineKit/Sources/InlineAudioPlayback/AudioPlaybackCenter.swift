import AVFoundation
import Foundation
import Observation

/// App-wide owner for audio playback state and controls.
///
/// This type is UI-facing state plus playback orchestration. It intentionally
/// knows nothing about Inline messages, GRDB, or platform navigation.
@MainActor
@Observable
public final class AudioPlaybackCenter {
  public static let shared = AudioPlaybackCenter()

  public private(set) var item: AudioPlaybackItem?
  public private(set) var sourceURL: URL?
  public private(set) var display: AudioPlaybackDisplay?
  public private(set) var openTarget: AudioPlaybackOpenTarget?
  public private(set) var isPlaying = false
  public private(set) var currentTime: TimeInterval = 0
  public private(set) var duration: TimeInterval = 0
  public private(set) var playbackRate: Float
  public private(set) var volume: Float

  public var state: AudioPlaybackState {
    AudioPlaybackState(
      item: item,
      sourceURL: sourceURL,
      display: display,
      openTarget: openTarget,
      isPlaying: isPlaying,
      currentTime: currentTime,
      duration: duration,
      playbackRate: playbackRate,
      volume: volume
    )
  }

  @ObservationIgnored private let engine: AudioPlaybackEngine
  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private var progressTimer: Timer?
  private static let playbackRateDefaultsKey = "inline.sharedAudioPlayer.playbackRate"
  private static let volumeDefaultsKey = "inline.sharedAudioPlayer.volume"

  #if os(iOS)
  @ObservationIgnored private var audioSessionActive = false
  #endif

  public init(
    engine: AudioPlaybackEngine = AVAudioPlayerPlaybackEngine(),
    userDefaults: UserDefaults = .standard
  ) {
    self.engine = engine
    self.userDefaults = userDefaults
    playbackRate = Self.storedPlaybackRate(userDefaults: userDefaults)
    volume = Self.storedVolume(userDefaults: userDefaults)
    self.engine.onFinish = { [weak self] duration in
      self?.handlePlaybackFinished(duration: duration)
    }
  }

  public func play(
    fileURL: URL,
    item: AudioPlaybackItem,
    presentation: AudioPlaybackPresentation
  ) throws {
    try loadAudio(
      fileURL: fileURL,
      item: item,
      presentation: presentation,
      startsPlaying: true,
      playbackFailureError: .playbackUnavailable
    )
  }

  /// Toggle if this exact source is already loaded; otherwise load and play it.
  /// The source URL matters because the same media item can be re-cached at a
  /// new local path after a download or cache repair.
  public func toggleOrPlay(
    fileURL: URL,
    item: AudioPlaybackItem,
    presentation: AudioPlaybackPresentation
  ) throws {
    if self.item == item, sourceURL == fileURL {
      try toggleCurrentPlayback()
      return
    }

    try play(fileURL: fileURL, item: item, presentation: presentation)
  }

  public func prepare(
    fileURL: URL,
    item: AudioPlaybackItem,
    presentation: AudioPlaybackPresentation
  ) throws {
    if self.item == item {
      return
    }

    try loadAudio(
      fileURL: fileURL,
      item: item,
      presentation: presentation,
      startsPlaying: false,
      playbackFailureError: .playbackUnavailable
    )
  }

  public func pause() {
    engine.pause()
    progressTimer?.invalidate()
    progressTimer = nil
    syncPlaybackState()
    isPlaying = false
    #if os(iOS)
    deactivateAudioSessionIfNeeded()
    #endif
  }

  public func close() {
    let preservedPlaybackRate = playbackRate
    let preservedVolume = volume
    progressTimer?.invalidate()
    progressTimer = nil
    engine.stop()
    item = nil
    sourceURL = nil
    display = nil
    openTarget = nil
    isPlaying = false
    currentTime = 0
    duration = 0
    playbackRate = preservedPlaybackRate
    volume = preservedVolume
    #if os(iOS)
    deactivateAudioSessionIfNeeded()
    #endif
  }

  public func seek(to progress: Double) {
    guard item != nil else { return }
    let clampedProgress = min(max(progress, 0), 1)
    engine.currentTime = engine.duration * clampedProgress
    currentTime = engine.currentTime
    duration = engine.duration
  }

  public func toggleCurrentPlayback() throws {
    if isPlaying {
      pause()
    } else {
      try resume()
    }
  }

  public func resume() throws {
    guard item != nil else {
      throw AudioPlaybackError.playbackUnavailable
    }

    #if os(iOS)
    try configureAudioSessionIfNeeded()
    #endif

    if engine.duration > 0, engine.currentTime >= engine.duration {
      engine.currentTime = 0
      currentTime = 0
    }

    applyStoredPlaybackControls()
    guard engine.play() else {
      throw AudioPlaybackError.playbackUnavailable
    }

    isPlaying = true
    duration = engine.duration
    startProgressTimer()
  }

  public func setPlaybackRate(_ rate: Float) {
    let clamped = min(max(rate, 0.5), 2)
    guard playbackRate != clamped else { return }
    playbackRate = clamped
    userDefaults.set(Double(clamped), forKey: Self.playbackRateDefaultsKey)
    engine.playbackRate = clamped
  }

  public func setVolume(_ volume: Float) {
    let clamped = min(max(volume, 0), 1)
    guard self.volume != clamped else { return }
    self.volume = clamped
    userDefaults.set(Double(clamped), forKey: Self.volumeDefaultsKey)
    engine.volume = clamped
  }

  public func previewVolume(_ volume: Float) {
    let clamped = min(max(volume, 0), 1)
    engine.volume = clamped
  }

  public func isCurrent(_ item: AudioPlaybackItem) -> Bool {
    self.item == item
  }

  private func loadAudio(
    fileURL: URL,
    item: AudioPlaybackItem,
    presentation: AudioPlaybackPresentation,
    startsPlaying: Bool,
    playbackFailureError: AudioPlaybackError
  ) throws {
    close()

    #if os(iOS)
    if startsPlaying {
      try configureAudioSessionIfNeeded()
    }
    #endif

    try engine.load(contentsOf: fileURL)
    applyStoredPlaybackControls()
    engine.prepare()

    if startsPlaying {
      guard engine.play() else {
        throw playbackFailureError
      }
    }

    self.item = item
    sourceURL = fileURL
    display = presentation.display
    openTarget = presentation.openTarget
    isPlaying = startsPlaying
    currentTime = engine.currentTime
    duration = engine.duration

    if startsPlaying {
      startProgressTimer()
    }
  }

  private func startProgressTimer() {
    progressTimer?.invalidate()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.syncPlaybackState()
      }
    }
  }

  private func syncPlaybackState() {
    guard item != nil else { return }
    currentTime = engine.currentTime
    duration = engine.duration
    isPlaying = engine.isPlaying
  }

  private func handlePlaybackFinished(duration _: TimeInterval) {
    close()
  }

  private func applyStoredPlaybackControls() {
    engine.playbackRate = playbackRate
    engine.volume = volume
  }

  private static func storedPlaybackRate(userDefaults: UserDefaults) -> Float {
    let value = userDefaults.double(forKey: playbackRateDefaultsKey)
    guard value > 0 else { return 1 }
    return min(max(Float(value), 0.5), 2)
  }

  private static func storedVolume(userDefaults: UserDefaults) -> Float {
    guard userDefaults.object(forKey: volumeDefaultsKey) != nil else { return 1 }
    return min(max(Float(userDefaults.double(forKey: volumeDefaultsKey)), 0), 1)
  }

  #if os(iOS)
  private func configureAudioSessionIfNeeded() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .spokenAudio, options: [])
    try session.setActive(true)
    audioSessionActive = true
  }

  private func deactivateAudioSessionIfNeeded() {
    guard audioSessionActive else { return }
    audioSessionActive = false
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }
  #endif
}
