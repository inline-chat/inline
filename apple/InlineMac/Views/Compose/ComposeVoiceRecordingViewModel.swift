import AVFoundation
import Combine
import Foundation
import InlineKit
import InlineProtocol
import Logger

enum ComposeVoiceRecordingPhase {
  case idle
  case recording
  case review
}

@MainActor
final class ComposeVoiceRecordingViewModel: ObservableObject {
  @Published private(set) var phase: ComposeVoiceRecordingPhase = .idle
  @Published private(set) var duration: TimeInterval = 0
  @Published private(set) var samples: [UInt8] = []
  @Published private(set) var isPlaying = false
  @Published private(set) var playbackProgress: Double = 0

  private let peerId: InlineKit.Peer
  private let log = Log.scoped("ComposeVoiceRecordingViewModel")

  private var recorder: ComposeVoiceRecorder?
  private var recording: ComposeVoiceRecording?
  private var player: AVAudioPlayer?
  private var playbackTimer: Timer?
  private var stopRecordingAction: (@Sendable () -> Void)?
  private var isStarting = false

  var isActive: Bool {
    phase != .idle
  }

  init(peerId: InlineKit.Peer) {
    self.peerId = peerId
  }

  deinit {
    playbackTimer?.invalidate()
    player?.stop()
    stopRecordingAction?()

    let recorder = recorder
    let recordingURL = recording?.fileURL
    Task { @MainActor in
      recorder?.cancel()
      if let recordingURL {
        try? FileManager.default.removeItem(at: recordingURL)
      }
    }
  }

  func start() async {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return }
    guard phase == .idle, !isStarting else { return }
    isStarting = true
    defer {
      isStarting = false
    }

    guard await ensureMicrophoneAccess() else { return }

    do {
      let recorder = ComposeVoiceRecorder()
      recorder.onUpdate = { [weak self] duration, samples in
        self?.duration = duration
        self?.samples = samples
      }
      try recorder.start()

      self.recorder = recorder
      duration = 0
      samples = []
      playbackProgress = 0
      isPlaying = false
      phase = .recording
      stopRecordingAction = ComposeActions.shared.startVoiceRecording(for: peerId)
    } catch {
      log.error("Failed to start voice recording", error: error)
      ToastCenter.shared.showError(error.localizedDescription)
      reset()
    }
  }

  func pauseRecording() {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else {
      cancel()
      return
    }

    guard phase == .recording, let recorder else { return }

    do {
      let recording = try recorder.finish()
      self.recorder = nil
      self.recording = recording
      stopRecordingAction?()
      stopRecordingAction = nil

      duration = recording.duration
      samples = Array(recording.waveform)
      playbackProgress = 0
      isPlaying = false
      phase = .review
    } catch {
      log.error("Failed to finish voice recording", error: error)
      ToastCenter.shared.showError(error.localizedDescription)
      cancel()
    }
  }

  func cancel() {
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
      player?.pause()
      isPlaying = false
      return
    }

    do {
      let player = try player ?? AVAudioPlayer(contentsOf: recording.fileURL)
      player.prepareToPlay()
      if playbackProgress >= 1 {
        player.currentTime = 0
        playbackProgress = 0
      }
      self.player = player
      player.play()
      isPlaying = true
      startPlaybackTimer()
    } catch {
      log.error("Failed to play voice recording", error: error)
      ToastCenter.shared.showError("Failed to play voice message")
      stopPlayback(resetProgress: true)
    }
  }

  func seekPlayback(to progress: Double) {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else { return }
    guard phase == .review, let recording else { return }

    do {
      let player = try player ?? AVAudioPlayer(contentsOf: recording.fileURL)
      player.prepareToPlay()

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
      log.error("Failed to seek voice recording", error: error)
      ToastCenter.shared.showError("Failed to seek voice message")
      stopPlayback(resetProgress: true)
    }
  }

  func takeVoiceMediaItem() throws -> FileMediaItem? {
    guard ExperimentalFeatureFlags.voiceMessagesEnabled else {
      cancel()
      return nil
    }

    guard let recording else { return nil }
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

  private func ensureMicrophoneAccess() async -> Bool {
    switch MacPermissions.mediaStatus(for: .audio) {
    case .authorized:
      return true
    case .notDetermined:
      let granted = await MacPermissions.requestMediaAccess(for: .audio)
      if !granted {
        ToastCenter.shared.showError("Microphone access is required to record voice messages.")
      }
      return granted
    case .denied, .restricted:
      ToastCenter.shared.showError("Allow microphone access to record voice messages.")
      MacPermissions.openSystemSettings(.microphone)
      return false
    @unknown default:
      ToastCenter.shared.showError("Microphone access is unavailable.")
      return false
    }
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

    if player.currentTime >= player.duration {
      player.currentTime = 0
      playbackProgress = 0
    }
  }

  private func stopPlayback(resetProgress: Bool) {
    playbackTimer?.invalidate()
    playbackTimer = nil
    player?.stop()
    player = nil
    isPlaying = false
    if resetProgress {
      playbackProgress = 0
    }
  }

  private func reset() {
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    phase = .idle
  }
}
