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
final class ComposeVoiceRecordingViewModel: ObservableObject {
  @Published private(set) var phase: ComposeVoiceRecordingPhase = .idle
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var samples: [UInt8] = []
  @Published private(set) var isPlaying = false
  @Published private(set) var playbackProgress: Double = 0
  @Published private(set) var isSending = false

  private let log = Log.scoped("ComposeVoiceRecordingViewModel")

  private var recorder: ComposeVoiceRecorder?
  private var recording: ComposeVoiceRecording?
  private var player: AVAudioPlayer?
  private var playbackTimer: Timer?
  private var playbackSessionActive = false
  private var stopRecordingAction: (@Sendable () -> Void)?
  private var operationId = UUID()
  private var cancellables: Set<AnyCancellable> = []

  var isActive: Bool {
    phase != .idle
  }

  var canSend: Bool {
    phase == .review && recording != nil && !isSending
  }

  init() {
    observeSystemEvents()
  }

  deinit {
    playbackTimer?.invalidate()
    player?.stop()
    stopRecordingAction?()

    let recorder = recorder
    let recordingURL = recording?.fileURL
    let shouldDeactivatePlaybackSession = playbackSessionActive
    Task { @MainActor in
      if shouldDeactivatePlaybackSession {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
      }
      recorder?.cancel()
      if let recordingURL {
        try? FileManager.default.removeItem(at: recordingURL)
      }
    }
  }

  @discardableResult
  func prepareToStart() -> Bool {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return false }
    guard phase == .idle else { return false }

    let operationId = UUID()
    enterStarting(operationId: operationId)
    return true
  }

  func start(peerId: InlineKit.Peer) async {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return }

    let operationId: UUID
    switch phase {
    case .idle:
      operationId = UUID()
      enterStarting(operationId: operationId)
    case .starting:
      operationId = self.operationId
    case .recording, .finishing, .review:
      return
    }

    await Task.yield()
    try? await Task.sleep(nanoseconds: 25_000_000)

    guard await ensureMicrophoneAccess() else {
      if self.operationId == operationId {
        reset()
      }
      return
    }

    guard self.operationId == operationId else { return }
    guard UIApplication.shared.applicationState == .active else {
      reset()
      return
    }

    do {
      SharedAudioPlayer.shared.stop()

      let recorder = ComposeVoiceRecorder()
      recorder.onUpdate = { [weak self] duration, samples in
        self?.applyRecorderUpdate(duration: duration, samples: samples)
      }
      try recorder.start()

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
      phase = .recording
      stopRecordingAction = ComposeActions.shared.startVoiceRecording(for: peerId)
    } catch {
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

  func cancel() {
    operationId = UUID()
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
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else {
      stopPlayback(resetProgress: true)
      return
    }

    guard phase == .review, let recording else { return }

    if player?.isPlaying == true {
      pausePlayback()
      return
    }

    do {
      try configurePlaybackSession()
      let player = try player ?? makePlaybackPlayer(for: recording)
      if playbackProgress >= 1 {
        player.currentTime = 0
        playbackProgress = 0
      }
      self.player = player
      guard player.play() else {
        throw ComposeVoicePlaybackError.playFailed
      }
      isPlaying = true
      startPlaybackTimer()
    } catch {
      logPlaybackError("Failed to play voice recording", error: error, recording: recording)
      showError("Failed to play voice message")
      stopPlayback(resetProgress: true)
    }
  }

  func seekPlayback(to progress: Double) {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return }
    guard phase == .review, let recording else { return }

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
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else {
      cancel()
      return nil
    }

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

  private func finishRecording(showTooShortToast: Bool) async {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else {
      cancel()
      return
    }

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

      guard recording.duration >= Self.minimumDuration else {
        discard(recording)
        if showTooShortToast {
          showError("Voice message is too short.")
        }
        resetFinishedAttempt()
        return
      }

      self.recording = recording
      duration = recording.duration
      samples = Array(recording.waveform)
      playbackProgress = 0
      isPlaying = false
      isSending = false
      phase = .review
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
        guard Self.shouldStopForRouteChange(notification) else { return }
        Task { @MainActor in
          guard let self else { return }
          await self.handleSystemStop()
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

  private func handleAppBackground() async {
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

  private nonisolated static func shouldStopForRouteChange(_ notification: Notification) -> Bool {
    guard let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue)
    else {
      return false
    }

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

  private func ensureMicrophoneAccess() async -> Bool {
    switch AVAudioApplication.shared.recordPermission {
    case .granted:
      return true
    case .undetermined:
      let granted = await requestMicrophoneAccess()
      if !granted {
        showError("Microphone access is required to record voice messages.")
      }
      return granted
    case .denied:
      showError("Allow microphone access to record voice messages.")
      openAppSettings()
      return false
    @unknown default:
      showError("Microphone access is unavailable.")
      return false
    }
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

  private func configurePlaybackSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .spokenAudio, options: [])
    try session.setActive(true)
    playbackSessionActive = true
  }

  private func deactivatePlaybackSession() {
    guard playbackSessionActive else { return }
    playbackSessionActive = false
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
  }

  private func makePlaybackPlayer(for recording: ComposeVoiceRecording) throws -> AVAudioPlayer {
    let player = try AVAudioPlayer(data: recording.data)
    player.prepareToPlay()
    return player
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
    player?.pause()
    playbackTimer?.invalidate()
    playbackTimer = nil
    isPlaying = false
    deactivatePlaybackSession()
  }

  private func stopPlayback(resetProgress: Bool) {
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
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    isSending = false
    phase = .idle
  }

  private func resetFinishedAttempt() {
    recording = nil
    reset()
  }

  private func discard(_ recording: ComposeVoiceRecording) {
    try? FileManager.default.removeItem(at: recording.fileURL)
  }

  private func showError(_ message: String) {
    ToastManager.shared.showToast(message, type: .error, systemImage: "exclamationmark.triangle.fill")
  }

  private static let minimumDuration: TimeInterval = 0.5
}

private enum ComposeVoicePlaybackError: LocalizedError {
  case playFailed

  var errorDescription: String? {
    switch self {
    case .playFailed:
      "Could not play voice recording."
    }
  }
}
