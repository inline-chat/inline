import AVFoundation
import Combine
import Foundation
import InlineKit
import Logger
import UIKit

enum ComposeVoiceRecordingPhase: Equatable, Hashable {
  case idle
  case starting
  case recording
  case finishing
  case review
}

@MainActor
final class ComposeVoiceRecordingViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
  @Published private(set) var phase: ComposeVoiceRecordingPhase = .idle
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var samples: [UInt8] = []
  @Published private(set) var isPlaying = false
  @Published private(set) var playbackProgress: Double = 0
  @Published private(set) var isSending = false

  let inputController: VoiceInputController

  private let log = Log.scoped("ComposeVoiceRecordingViewModel")

  private var recorder: ComposeVoiceRecorder?
  private var recording: ComposeVoiceRecording?
  private var player: AVAudioPlayer?
  private var playbackTimer: Timer?
  private var playbackSessionToken: InlineAudioSession.Token?
  private var isPreparingPlayback = false
  private var stopRecordingAction: (@Sendable () -> Void)?
  private var operationId = UUID()
  private var isPreparingStart = false
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool {
    phase != .idle
  }

  var canSend: Bool {
    phase == .review && recording != nil && !isSending
  }

  var shouldConfirmCancel: Bool {
    duration > Self.discardConfirmationDuration
  }

  override convenience init() {
    self.init(inputController: .shared)
  }

  init(inputController: VoiceInputController) {
    self.inputController = inputController
    super.init()
    observeSystemEvents()
  }

  deinit {
    playbackTimer?.invalidate()
    player?.stop()
    stopRecordingAction?()

    let recorder = recorder
    let recordingURL = recording?.fileURL
    let playbackSessionToken = playbackSessionToken
    Task { @MainActor in
      if let playbackSessionToken {
        InlineAudioSession.shared.release(playbackSessionToken)
      }
      recorder?.cancel()
      if let recordingURL {
        try? FileManager.default.removeItem(at: recordingURL)
      }
    }
  }

  func start(peerId: InlineKit.Peer) async {
    guard phase == .idle, !isPreparingStart else { return }

    let operationId = UUID()
    self.operationId = operationId
    isPreparingStart = true
    defer {
      if self.operationId == operationId {
        isPreparingStart = false
      }
    }

    guard let access = await ensureMicrophoneAccess() else { return }
    guard await waitForActiveApplication(operationId: operationId) else { return }
    guard await settleMicrophoneAccessIfNeeded(access, operationId: operationId) else { return }

    guard self.operationId == operationId else { return }
    guard UIApplication.shared.applicationState == .active else {
      return
    }

    enterStarting(operationId: operationId)
    await Task.yield()
    guard self.operationId == operationId, phase == .starting else { return }

    do {
      SharedAudioPlayer.shared.stop()

      let recorder = ComposeVoiceRecorder()
      recorder.onUpdate = { [weak self] duration, samples in
        self?.applyRecorderUpdate(duration: duration, samples: samples)
      }
      recorder.onUnexpectedStop = { [weak self] error in
        Task { @MainActor in
          guard let self, self.operationId == operationId, self.phase == .recording else { return }
          await self.finishRecording(showTooShortToast: true, unexpectedStop: error)
        }
      }
      // Cancellation must reach a recorder whose native activation is still pending.
      self.recorder = recorder
      try await recorder.start { [weak self] in
        guard let self else { return false }
        return self.operationId == operationId && self.phase == .starting
          && UIApplication.shared.applicationState == .active
      }

      guard self.operationId == operationId else {
        recorder.cancel()
        return
      }

      self.recorder = recorder
      duration = 0
      samples = []
      playbackProgress = 0
      isPlaying = false
      isSending = false
      refreshInputState()
      phase = .recording
      stopRecordingAction = ComposeActions.shared.startVoiceRecording(for: peerId)
    } catch {
      guard self.operationId == operationId else { return }
      self.recorder?.cancel()
      self.recorder = nil
      if error is CancellationError { reset(); return }
      log.error("Failed to start voice recording", error: error)
      showError(error.localizedDescription)
      if self.operationId == operationId {
        reset()
      }
    }
  }

  func stopRecording() {
    guard phase == .recording else { return }
    Task { @MainActor in
      await finishRecording(showTooShortToast: true)
    }
  }

  func selectInputDevice(_ deviceId: VoiceInputDevice.ID) {
    log.debug("Voice input picker selected explicit input phase=\(String(describing: phase))")
    guard phase == .recording else { return }

    do {
      try inputController.selectPreferredInput(deviceId: deviceId, persistence: .runtimeOnly)
    } catch {
      log.error("Failed to select voice recording input", error: error)
      showError(error.localizedDescription)
      refreshInputState()
      return
    }
  }

  func selectAutomaticInput() {
    log.debug("Voice input picker selected auto phase=\(String(describing: phase))")
    guard phase == .recording else { return }

    do {
      try inputController.selectAutomaticInput(persistence: .runtimeOnly)
    } catch {
      log.error("Failed to select automatic voice recording input", error: error)
      showError(error.localizedDescription)
      refreshInputState()
      return
    }
  }

  func cancel() {
    operationId = UUID()
    isPreparingStart = false
    recorder?.cancel()
    recorder = nil
    stopRecordingAction?()
    stopRecordingAction = nil
    stopPlayback(resetProgress: true)

    if let recording {
      try? FileManager.default.removeItem(at: recording.fileURL)
    }
    recording = nil

    reset()
  }

  func togglePlayback() {
    guard phase == .review, let recording else { return }

    if player?.isPlaying == true || isPreparingPlayback {
      pausePlayback()
      return
    }

    do {
      let player = try player ?? makePlaybackPlayer(for: recording)
      if playbackProgress >= 1 {
        player.currentTime = 0
        playbackProgress = 0
      }
      self.player = player
      let operationId = UUID()
      self.operationId = operationId
      let session = InlineAudioSession.shared
      let token = try session.acquire(.draftPreview)
      playbackSessionToken = token
      isPreparingPlayback = true
      Task { @MainActor [weak self] in
        do {
          try await session.activate(token, category: .playback, mode: .spokenAudio)
          guard let self, self.operationId == operationId, phase == .review, self.player === player,
                playbackSessionToken == token, session.owns(token), !Task.isCancelled
          else { session.release(token); return }
          guard player.prepareToPlay() else { throw ComposeVoicePlaybackError.preparationFailed }
          guard player.play() else { throw ComposeVoicePlaybackError.playFailed }
          isPreparingPlayback = false
          isPlaying = true
          startPlaybackTimer()
        } catch {
          session.release(token)
          guard let self, self.operationId == operationId, phase == .review, self.player === player,
                playbackSessionToken == token else { return }
          playbackSessionToken = nil
          if !(error is CancellationError) {
            logPlaybackError("Failed to play voice recording", error: error, recording: recording)
            showError((error as? AudioPlaybackError)?.localizedDescription ?? "Failed to play voice message")
          }
          stopPlayback(resetProgress: true)
        }
      }
    } catch {
      logPlaybackError("Failed to play voice recording", error: error, recording: recording)
      showError((error as? AudioPlaybackError)?.localizedDescription ?? "Failed to play voice message")
      stopPlayback(resetProgress: true)
    }
  }

  func seekPlayback(to progress: Double) {
    guard phase == .review, let recording else { return }
    if isPreparingPlayback { pausePlayback() }

    do {
      let player = try player ?? makePlaybackPlayer(for: recording)

      let duration = max(player.duration, recording.duration)
      let clampedProgress = min(max(progress, 0), 1)
      player.currentTime = duration * clampedProgress

      self.player = player
      playbackProgress = clampedProgress
      if player.isPlaying {
        isPlaying = true
        startPlaybackTimer()
      }
    } catch {
      logPlaybackError("Failed to seek voice recording", error: error, recording: recording)
      showError("Failed to seek voice message")
      stopPlayback(resetProgress: true)
    }
  }

  func takeVoiceMediaItem() throws -> FileMediaItem? {
    guard canSend, let recording else { return nil }
    isSending = true
    defer {
      if phase == .review {
        isSending = false
      }
    }

    stopPlayback(resetProgress: true)

    let voice = try FileCache.saveVoice(
      data: recording.data,
      duration: Int(max(1, recording.duration.rounded(.up))),
      waveform: recording.waveform,
      mimeType: recording.mimeType,
      fileExtension: recording.fileExtension
    )

    try? FileManager.default.removeItem(at: recording.fileURL)
    self.recording = nil
    reset()
    return .voice(voice)
  }

  private func finishRecording(
    showTooShortToast: Bool,
    unexpectedStop: ComposeVoiceRecorderError? = nil
  ) async {
    guard phase == .recording, let recorder else { return }

    let operationId = self.operationId
    phase = .finishing
    self.recorder = nil
    stopRecordingAction?()
    stopRecordingAction = nil

    do {
      let recording = try await recorder.finish()

      guard self.operationId == operationId else {
        try? FileManager.default.removeItem(at: recording.fileURL)
        return
      }

      self.recording = recording
      duration = recording.duration
      samples = Array(recording.waveform)
      playbackProgress = 0
      isPlaying = false
      isSending = false
      phase = .review
      if let unexpectedStop {
        showError(unexpectedStop.localizedDescription)
      }
    } catch {
      guard self.operationId == operationId else { return }
      log.error("Failed to finish voice recording", error: error)
      if showTooShortToast {
        showError(error.localizedDescription)
      }
      resetFinishedAttempt()
    }
  }

  private func applyRecorderUpdate(duration: TimeInterval, samples: [UInt8]) {
    guard phase == .recording else { return }
    self.duration = duration
    self.samples = samples
  }

  private func enterStarting(operationId: UUID) {
    self.operationId = operationId
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    isSending = false
    phase = .starting
  }

  private func refreshInputState() {
    guard phase == .recording || phase == .starting else { return }
    inputController.refresh()
  }

  private func observeSystemEvents() {
    let center = NotificationCenter.default

    center.publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard Self.isInterruptionStart(notification) else { return }
        Task { @MainActor in
          guard let self else { return }
          await self.handleSystemStop()
        }
      }
      .store(in: &cancellables)

    center.publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        let reason = Self.routeChangeReason(notification)
        Task { @MainActor in
          guard let self else { return }
          self.recorder?.logRouteChange(reason: reason)

          if let reason, Self.shouldApplyPreferredInput(for: reason) {
            self.applyPreferredInput()
          } else {
            self.refreshInputState()
          }

          guard let reason, Self.shouldStopForRouteChange(reason) else { return }
          await self.handleSystemStop()
        }
      }
      .store(in: &cancellables)

    center.publisher(for: UIApplication.didBecomeActiveNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.applyPreferredInput()
          self.refreshInputState()
        }
      }
      .store(in: &cancellables)

    center.publisher(for: UIApplication.didEnterBackgroundNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          await self.handleAppBackground()
        }
      }
      .store(in: &cancellables)
  }

  private func handleSystemStop() async {
    if isPreparingStart {
      cancelPendingStart()
      return
    }

    switch phase {
    case .recording:
      await finishRecording(showTooShortToast: false)
    case .starting, .finishing:
      cancel()
    case .review:
      stopPlayback(resetProgress: false)
    case .idle:
      break
    }
  }

  private func applyPreferredInput() {
    guard phase == .recording else { return }

    do {
      try inputController.applyPreferredInput()
    } catch {
      log.error("Failed to apply preferred voice recording input", error: error)
      refreshInputState()
    }
  }

  private func handleAppBackground() async {
    if isPreparingStart {
      cancelPendingStart()
      return
    }

    switch phase {
    case .recording:
      await finishRecording(showTooShortToast: false)
    case .starting, .finishing:
      cancel()
    case .review:
      stopPlayback(resetProgress: false)
    case .idle:
      break
    }
  }

  private nonisolated static func isInterruptionStart(_ notification: Notification) -> Bool {
    guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: rawValue)
    else {
      return false
    }

    return type == .began
  }

  private nonisolated static func routeChangeReason(_ notification: Notification) -> AVAudioSession.RouteChangeReason? {
    guard let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue)
    else {
      return nil
    }

    return reason
  }

  private nonisolated static func shouldApplyPreferredInput(for reason: AVAudioSession.RouteChangeReason) -> Bool {
    switch reason {
    case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .wakeFromSleep:
      return true
    case .noSuitableRouteForCategory, .override, .routeConfigurationChange, .unknown:
      return false
    @unknown default:
      return false
    }
  }

  private nonisolated static func shouldStopForRouteChange(_ reason: AVAudioSession.RouteChangeReason) -> Bool {
    switch reason {
    case .noSuitableRouteForCategory:
      return true
    case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override, .wakeFromSleep,
         .routeConfigurationChange, .unknown:
      return false
    @unknown default:
      return false
    }
  }

  private func ensureMicrophoneAccess() async -> MicrophoneAccessGrant? {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      return .authorized
    case .undetermined:
      let granted = await requestMicrophoneAccess()
      if !granted {
        showError("Microphone access is required to record voice messages.")
        return nil
      }
      return .newlyAuthorized
    case .denied:
      showError("Allow microphone access to record voice messages.")
      openAppSettings()
      return nil
    @unknown default:
      showError("Microphone access is unavailable.")
      return nil
    }
  }

  private func settleMicrophoneAccessIfNeeded(_ access: MicrophoneAccessGrant, operationId: UUID) async -> Bool {
    guard access == .newlyAuthorized else { return true }

    await Task.yield()
    try? await Task.sleep(nanoseconds: Self.microphonePermissionSettleDelay)
    guard self.operationId == operationId else { return false }

    if AVAudioApplication.shared.recordPermission == .granted {
      return true
    }

    showError("Microphone access is unavailable.")
    return false
  }

  private func waitForActiveApplication(operationId: UUID) async -> Bool {
    for _ in 0...Self.applicationActivationWaitAttempts {
      guard self.operationId == operationId, !Task.isCancelled else { return false }
      if UIApplication.shared.applicationState == .active {
        return true
      }
      try? await Task.sleep(nanoseconds: Self.applicationActivationPollInterval)
    }

    return false
  }

  private func cancelPendingStart() {
    guard isPreparingStart else { return }
    operationId = UUID()
    isPreparingStart = false
    recorder?.cancel()
    recorder = nil
    if phase == .starting { reset() }
  }

  private func requestMicrophoneAccess() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func deactivatePlaybackSession() {
    guard let playbackSessionToken else { return }
    self.playbackSessionToken = nil
    InlineAudioSession.shared.release(playbackSessionToken)
  }

  private func makePlaybackPlayer(for recording: ComposeVoiceRecording) throws -> AVAudioPlayer {
    let player = try AVAudioPlayer(data: recording.data)
    player.delegate = self
    return player
  }

  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard let self, let current = self.player, ObjectIdentifier(current) == identity, !current.isPlaying else { return }
      if !flag {
        self.showError("Failed to play voice message")
      }
      self.stopPlayback(resetProgress: true)
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    let identity = ObjectIdentifier(player)
    Task { @MainActor [weak self] in
      guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
      if let recording = self.recording {
        self.logPlaybackError(
          "Failed to decode voice recording",
          error: error ?? ComposeVoicePlaybackError.decodeFailed,
          recording: recording
        )
      }
      self.showError("Failed to play voice message")
      self.stopPlayback(resetProgress: true)
    }
  }

  private func logPlaybackError(_ message: String, error: Error, recording: ComposeVoiceRecording) {
    let route = AVAudioSession.sharedInstance().currentRoute.outputs
      .map(\.portType.rawValue)
      .joined(separator: ",")
    let fileExists = FileManager.default.fileExists(atPath: recording.fileURL.path)
    log.error(
      "\(message) bytes=\(recording.data.count) duration=\(recording.duration) progress=\(playbackProgress) fileExists=\(fileExists) route=\(route)",
      error: error
    )
  }

  private func startPlaybackTimer() {
    playbackTimer?.invalidate()
    playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.updatePlaybackProgress()
      }
    }
  }

  private func updatePlaybackProgress() {
    guard let player else {
      stopPlayback(resetProgress: true)
      return
    }

    if player.duration > 0 {
      playbackProgress = min(1, max(0, player.currentTime / player.duration))
    }

    if player.isPlaying {
      return
    }

    isPlaying = false
    playbackTimer?.invalidate()
    playbackTimer = nil
    deactivatePlaybackSession()

    if player.currentTime >= player.duration {
      player.currentTime = 0
      playbackProgress = 0
    }
  }

  private func pausePlayback() {
    cancelPendingPlayback()
    player?.pause()
    playbackTimer?.invalidate()
    playbackTimer = nil
    isPlaying = false
    deactivatePlaybackSession()
  }

  private func stopPlayback(resetProgress: Bool) {
    cancelPendingPlayback()
    playbackTimer?.invalidate()
    playbackTimer = nil
    player?.stop()
    player = nil
    isPlaying = false
    deactivatePlaybackSession()
    if resetProgress {
      playbackProgress = 0
    }
  }

  private func reset() {
    isPreparingStart = false
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    isSending = false
    phase = .idle
  }

  private func cancelPendingPlayback() {
    if isPreparingPlayback {
      operationId = UUID()
      isPreparingPlayback = false
    }
  }

  private func resetFinishedAttempt() {
    recording = nil
    reset()
  }

  private func showError(_ message: String) {
    ToastManager.shared.showToast(message, type: .error, systemImage: "exclamationmark.triangle.fill")
  }

  private static let discardConfirmationDuration: TimeInterval = 10
  private static let microphonePermissionSettleDelay: UInt64 = 120_000_000
  private static let applicationActivationPollInterval: UInt64 = 50_000_000
  private static let applicationActivationWaitAttempts = 40
}

private enum MicrophoneAccessGrant: Equatable {
  case authorized
  case newlyAuthorized
}

private enum ComposeVoicePlaybackError: LocalizedError {
  case preparationFailed
  case playFailed
  case decodeFailed

  var errorDescription: String? {
    switch self {
    case .preparationFailed:
      "Could not prepare voice recording."
    case .playFailed:
      "Could not play voice recording."
    case .decodeFailed:
      "Could not decode voice recording."
    }
  }
}
