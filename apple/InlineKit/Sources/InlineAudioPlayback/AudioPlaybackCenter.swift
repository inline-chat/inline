import AVFoundation
import Foundation
import Observation

/// The only loaded-player and playback-position owner. Message admission lives in the app adapter.
@MainActor
@Observable
public final class AudioPlaybackCenter {
  public static let shared = AudioPlaybackCenter(usesSystemIntegration: true)

  public private(set) var item: AudioPlaybackItem?
  public private(set) var sourceURL: URL?
  public private(set) var display: AudioPlaybackDisplay?
  public private(set) var openTarget: AudioPlaybackOpenTarget?
  public private(set) var isPlaying = false
  public private(set) var isStarting = false
  public private(set) var currentTime: TimeInterval = 0
  public private(set) var duration: TimeInterval = 0
  public private(set) var playbackRate: Float
  public private(set) var volume: Float
  public private(set) var playbackError: String?

  @ObservationIgnored public var canResume: () -> Bool = { true }
  @ObservationIgnored public var onUserIntent: (() -> Void)?
  @ObservationIgnored public var onAudioTakeover: ((InlineAudioSession.Owner) -> Void)?
  @ObservationIgnored private let engine: AudioPlaybackEngine
  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let audioSession: InlineAudioSession
  @ObservationIgnored private var sessionToken: InlineAudioSession.Token?
  @ObservationIgnored private var progressTimer: Timer?
  @ObservationIgnored private var progressVisible = true
  @ObservationIgnored private var revision: UInt64 = 0
  @ObservationIgnored private var interruptionIntent: (item: AudioPlaybackItem, revision: UInt64)?
  @ObservationIgnored private var hasPlayed = false
  @ObservationIgnored private var permitsSystemControls = false
  #if os(iOS)
  @ObservationIgnored private var systemIntegration: IOSVoicePlaybackSystem?
  #endif

  private static let playbackRateDefaultsKey = "inline.sharedAudioPlayer.playbackRate"
  private static let volumeDefaultsKey = "inline.sharedAudioPlayer.volume"

  public var state: AudioPlaybackState {
    AudioPlaybackState(item: item, sourceURL: sourceURL, display: display, openTarget: openTarget,
                       isPlaying: isPlaying, currentTime: currentTime, duration: duration,
                       playbackRate: playbackRate, volume: volume)
  }

  public init(
    engine: AudioPlaybackEngine = AVAudioPlayerPlaybackEngine(),
    userDefaults: UserDefaults = .standard,
    audioSession: InlineAudioSession = .shared,
    usesSystemIntegration: Bool = false
  ) {
    self.engine = engine
    self.userDefaults = userDefaults
    self.audioSession = audioSession
    playbackRate = Self.storedPlaybackRate(userDefaults: userDefaults)
    #if os(iOS)
    volume = 1
    #else
    volume = Self.storedVolume(userDefaults: userDefaults)
    #endif
    engine.onFinish = { [weak self] _ in self?.close() }
    engine.onFailure = { [weak self] in
      self?.close()
      self?.playbackError = AudioPlaybackError.preparationFailed.localizedDescription
    }
    #if os(iOS)
    if usesSystemIntegration {
      systemIntegration = IOSVoicePlaybackSystem(center: self)
      audioSession.willAcquire = { [weak self] owner in
        guard let self, owner != .voice else { return }
        if owner == .recording { close() } else { pause() }
        permitsSystemControls = false
        updateSystemPresentation()
        onAudioTakeover?(owner)
      }
    }
    #endif
  }

  public typealias Completion = @MainActor (Result<Void, Error>) -> Void

  /// Returns after admission. On iOS, completion reports the actual asynchronous start.
  public func play(fileURL: URL, item: AudioPlaybackItem, presentation: AudioPlaybackPresentation,
                   completion: Completion? = nil) throws {
    try loadAudio(fileURL: fileURL, item: item, presentation: presentation)
    try resume(completion: completion)
  }

  public func toggleOrPlay(fileURL: URL, item: AudioPlaybackItem, presentation: AudioPlaybackPresentation,
                           completion: Completion? = nil) throws {
    if self.item == item, sourceURL == fileURL { try toggleCurrentPlayback(completion: completion) }
    else { try play(fileURL: fileURL, item: item, presentation: presentation, completion: completion) }
  }

  /// Loads a paused selection without preparing playback hardware or acquiring the audio session.
  public func prepare(fileURL: URL, item: AudioPlaybackItem, presentation: AudioPlaybackPresentation) throws {
    guard self.item != item || sourceURL != fileURL else { return }
    try loadAudio(fileURL: fileURL, item: item, presentation: presentation)
  }

  public func pause() {
    registerIntent()
    pauseEngine()
  }

  public func close() {
    registerIntent()
    stopProgressTimer()
    engine.stop()
    item = nil
    sourceURL = nil
    display = nil
    openTarget = nil
    isPlaying = false
    isStarting = false
    currentTime = 0
    duration = 0
    hasPlayed = false
    permitsSystemControls = false
    playbackError = nil
    releaseSession()
    updateSystemPresentation()
  }

  @discardableResult
  public func seek(to progress: Double) -> Bool {
    guard progress.isFinite, duration.isFinite, duration > 0 else { return false }
    return seek(toTime: min(max(progress, 0), 1) * duration)
  }

  @discardableResult
  public func seek(toTime time: TimeInterval) -> Bool {
    guard item != nil, time.isFinite, engine.duration.isFinite, engine.duration > 0 else { return false }
    registerIntent()
    let wasPlaying = isPlaying
    engine.currentTime = min(max(time, 0), engine.duration)
    syncPlaybackState()
    if wasPlaying, currentTime >= duration { close() }
    else { updateSystemPresentation() }
    return true
  }

  public func toggleCurrentPlayback(completion: Completion? = nil) throws {
    if isPlaying || isStarting {
      pause()
      completion?(.success(()))
    } else { try resume(completion: completion) }
  }

  public func resume(completion: Completion? = nil) throws {
    guard !isPlaying else { completion?(.success(())); return }
    registerIntent()
    guard item != nil, canResume() else { throw AudioPlaybackError.playbackUnavailable }
    #if os(iOS)
    if let denial = audioSession.voiceDenial {
      playbackError = denial.localizedDescription
      throw denial
    }
    #endif
    if audioSession.requiresNativeTransition {
      let token = try audioSession.acquire(.voice)
      sessionToken = token
      isStarting = true
      let attemptRevision = revision
      let attemptItem = item
      let attemptURL = sourceURL
      let audioSession = audioSession
      updateSystemPresentation()
      Task { @MainActor [weak self] in
        do {
          try await audioSession.activate(token, configuration: .voicePlayback)
          guard let self, revision == attemptRevision, item == attemptItem, sourceURL == attemptURL,
                sessionToken == token, audioSession.owns(token), canResume(), !Task.isCancelled
          else {
            audioSession.release(token)
            if let self, sessionToken == token {
              sessionToken = nil
              isStarting = false
              updateSystemPresentation()
            }
            completion?(.failure(CancellationError()))
            return
          }
          try startEngine()
          completion?(.success(()))
        } catch {
          audioSession.release(token)
          guard let self, revision == attemptRevision, item == attemptItem, sourceURL == attemptURL,
                sessionToken == token
          else {
            completion?(.failure(CancellationError()))
            return
          }
          sessionToken = nil
          failStart(error)
          completion?(.failure(error))
        }
      }
      return
    }
    // macOS has no process AVAudioSession transition and retains synchronous player controls.
    do {
      try startEngine()
      completion?(.success(()))
    } catch {
      failStart(error)
      throw error
    }
  }

  private func startEngine() throws {
    if engine.duration > 0, engine.currentTime >= engine.duration { engine.currentTime = 0 }
    applyStoredPlaybackControls()
    // These player controls stay on MainActor, after owned native activation has completed.
    try engine.prepare()
    guard engine.play() else { throw AudioPlaybackError.playbackUnavailable }
    playbackError = nil
    isStarting = false
    isPlaying = true
    hasPlayed = true
    permitsSystemControls = true
    syncPlaybackState()
    if progressVisible { startProgressTimer() }
    updateSystemPresentation()
  }

  private func failStart(_ error: Error) {
    engine.pause()
    isStarting = false
    isPlaying = false
    releaseSession()
    playbackError = (error as? AudioPlaybackError)?.localizedDescription
      ?? "Couldn't play this voice message. Try again."
    updateSystemPresentation()
  }

  public func setPlaybackRate(_ rate: Float) {
    guard rate.isFinite else { return }
    let clamped = min(max(rate, 0.5), 2)
    guard playbackRate != clamped else { return }
    // A rate-only change updates the admitted start; it does not replace its transport intent.
    if isStarting { interruptionIntent = nil }
    else { registerIntent(notifyAdapter: false) }
    syncPlaybackState()
    playbackRate = clamped
    userDefaults.set(Double(clamped), forKey: Self.playbackRateDefaultsKey)
    engine.playbackRate = clamped
    updateSystemPresentation()
  }

  public func setVolume(_ volume: Float) {
    #if !os(iOS)
    guard volume.isFinite else { return }
    let clamped = min(max(volume, 0), 1)
    guard self.volume != clamped else { return }
    self.volume = clamped
    userDefaults.set(Double(clamped), forKey: Self.volumeDefaultsKey)
    engine.volume = clamped
    #endif
  }

  public func previewVolume(_ volume: Float) {
    #if !os(iOS)
    guard volume.isFinite else { return }
    engine.volume = min(max(volume, 0), 1)
    #endif
  }

  public func isCurrent(_ item: AudioPlaybackItem) -> Bool { self.item == item }

  /// UI clock only. Background audio continues; system timing extrapolates from event snapshots.
  public func setProgressVisible(_ visible: Bool) {
    progressVisible = visible
    if visible {
      syncPlaybackState()
      if isPlaying { startProgressTimer() }
      updateSystemPresentation()
    } else { stopProgressTimer() }
  }

  public enum RemoteCommand: Sendable { case play, pause, toggle, seek(TimeInterval), stop }

  public var remoteCommandIdentity: AudioPlaybackCommandIdentity? {
    guard let item, item.kind == .voice, hasPlayed, permitsSystemControls else { return nil }
    return AudioPlaybackCommandIdentity(item: item, revision: revision)
  }

  @discardableResult
  public func handleRemoteCommand(_ command: RemoteCommand, expectedIdentity: AudioPlaybackCommandIdentity) -> Bool {
    guard remoteCommandIdentity == expectedIdentity, item?.kind == .voice, hasPlayed, permitsSystemControls, canResume(),
          audioSession.voiceDenial == nil else { return false }
    do {
      switch command {
      // Success admits an asynchronous start; hardware failure is projected by the core completion.
      case .play: if !isPlaying && !isStarting { try resume() }
      case .pause: pause()
      case .toggle: try toggleCurrentPlayback()
      case let .seek(time): return seek(toTime: time)
      case .stop: close()
      }
      return true
    } catch { return false }
  }

  public func interruptionBegan() {
    if isStarting {
      pause()
      interruptionIntent = nil
      return
    }
    guard let item, isPlaying else { interruptionIntent = nil; return }
    pauseEngine()
    interruptionIntent = (item, revision)
  }

  public func interruptionEnded(shouldResume: Bool, outputAvailable: Bool) {
    defer { interruptionIntent = nil }
    guard shouldResume, outputAvailable, let intent = interruptionIntent,
          intent.item == item, intent.revision == revision, canResume(), audioSession.voiceDenial == nil
    else { return }
    try? resume()
  }

  public func outputWasRemoved() { pause() }

  public func mediaServicesWereReset() {
    close()
    audioSession.invalidate()
  }

  private func loadAudio(fileURL: URL, item: AudioPlaybackItem, presentation: AudioPlaybackPresentation) throws {
    close()
    playbackError = nil
    do {
      try engine.load(contentsOf: fileURL)
      applyStoredPlaybackControls()
      guard engine.duration.isFinite, engine.duration > 0 else { throw AudioPlaybackError.preparationFailed }
    } catch {
      engine.stop()
      playbackError = "Couldn't play this voice message. Try again."
      throw error
    }
    // A valid loaded item exists even if session activation, preparation or play will fail.
    self.item = item
    sourceURL = fileURL
    display = presentation.display
    openTarget = presentation.openTarget
    syncPlaybackState()
  }

  private func registerIntent(notifyAdapter: Bool = true) {
    revision &+= 1
    interruptionIntent = nil
    if isStarting {
      isStarting = false
      releaseSession()
    }
    if notifyAdapter { onUserIntent?() }
  }

  private func pauseEngine() {
    engine.pause()
    stopProgressTimer()
    syncPlaybackState()
    isPlaying = false
    releaseSession()
    updateSystemPresentation()
  }

  private func releaseSession() {
    guard let token = sessionToken else { return }
    sessionToken = nil
    audioSession.release(token)
  }

  private func startProgressTimer() {
    stopProgressTimer()
    progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.syncPlaybackState() }
    }
  }

  private func stopProgressTimer() { progressTimer?.invalidate(); progressTimer = nil }

  private func syncPlaybackState() {
    guard item != nil else { return }
    currentTime = engine.currentTime
    duration = engine.duration
    // Transport events own this flag. The OS can stop AVAudioPlayer before its
    // interruption notification, so a clock sample must not erase resume intent.
  }

  public func clearPlaybackError() { playbackError = nil }

  private func applyStoredPlaybackControls() {
    engine.playbackRate = playbackRate
    engine.volume = volume
  }

  private func updateSystemPresentation() {
    #if os(iOS)
    systemIntegration?.update(eligible: item?.kind == .voice && hasPlayed && permitsSystemControls)
    #endif
  }

  private static func storedPlaybackRate(userDefaults: UserDefaults) -> Float {
    let value = userDefaults.double(forKey: playbackRateDefaultsKey)
    guard value.isFinite, value > 0 else { return 1 }
    return min(max(Float(value), 0.5), 2)
  }

  private static func storedVolume(userDefaults: UserDefaults) -> Float {
    let value = userDefaults.double(forKey: volumeDefaultsKey)
    guard userDefaults.object(forKey: volumeDefaultsKey) != nil, value.isFinite else { return 1 }
    return min(max(Float(value), 0), 1)
  }
}
