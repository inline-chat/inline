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
  private var draftVoice: Client_MessageVoiceContent?
  private var isStarting = false
  private var startId = UUID()

  var isActive: Bool {
    phase != .idle
  }

  var draftVoiceAttachmentId: String? {
    guard let draftVoice else { return nil }
    return FileMediaItem.voice(draftVoice).getItemUniqueId()
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
    let shouldRemoveRecording = recording.map(shouldRemoveRecordingFile) ?? false
    Task { @MainActor in
      recorder?.cancel()
      if shouldRemoveRecording, let recordingURL {
        try? FileManager.default.removeItem(at: recordingURL)
      }
    }
  }

  func start() async {
    guard phase == .idle, !isStarting else { return }

    let startId = UUID()
    self.startId = startId
    isStarting = true
    defer {
      if self.startId == startId {
        isStarting = false
      }
    }

    guard let access = await ensureMicrophoneAccess() else { return }
    guard await settleMicrophoneAccessIfNeeded(access, startId: startId) else { return }
    guard self.startId == startId, phase == .idle else { return }

    do {
      let recorder = ComposeVoiceRecorder()
      recorder.onUpdate = { [weak self] duration, samples in
        self?.duration = duration
        self?.samples = samples
      }
      try recorder.start()

      guard self.startId == startId, phase == .idle else {
        recorder.cancel()
        return
      }

      self.recorder = recorder
      draftVoice = nil
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
    guard phase == .recording, let recorder else { return }

    do {
      let recording = try recorder.finish()
      self.recorder = nil
      self.recording = recording
      draftVoice = nil
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
    startId = UUID()
    isStarting = false
    recorder?.cancel()
    recorder = nil
    stopRecordingAction?()
    stopRecordingAction = nil
    stopPlayback(resetProgress: true)

    if let recording, shouldRemoveRecordingFile(recording) {
      try? FileManager.default.removeItem(at: recording.fileURL)
    }
    recording = nil
    draftVoice = nil

    reset()
  }

  func togglePlayback() {
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
    guard let recording else { return nil }
    stopPlayback(resetProgress: true)

    if let draftVoice {
      if shouldRemoveRecordingFile(recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
      }
      self.recording = nil
      self.draftVoice = nil
      reset()
      return .voice(draftVoice)
    }

    let voice = try FileCache.saveVoice(
      data: recording.data,
      duration: Int(max(1, recording.duration.rounded(.up))),
      waveform: recording.waveform,
      mimeType: recording.mimeType,
      fileExtension: recording.fileExtension
    )

    try? FileManager.default.removeItem(at: recording.fileURL)
    self.recording = nil
    draftVoice = nil
    reset()
    return .voice(voice)
  }

  func draftVoiceMediaItem() throws -> FileMediaItem? {
    guard phase == .review, let recording else { return nil }

    if let draftVoice {
      return .voice(draftVoice)
    }

    let voice = try FileCache.saveVoice(
      data: recording.data,
      duration: Int(max(1, recording.duration.rounded(.up))),
      waveform: recording.waveform,
      mimeType: recording.mimeType,
      fileExtension: recording.fileExtension
    )
    draftVoice = voice
    return .voice(voice)
  }

  func loadDraftVoice(_ voice: Client_MessageVoiceContent) -> Bool {
    guard let url = FileMediaItem.voice(voice).localFileURL(),
          let data = try? Data(contentsOf: url),
          !data.isEmpty
    else {
      return false
    }

    stopPlayback(resetProgress: true)
    recorder?.cancel()
    recorder = nil
    stopRecordingAction?()
    stopRecordingAction = nil

    draftVoice = voice
    recording = ComposeVoiceRecording(
      fileURL: url,
      data: data,
      duration: TimeInterval(max(1, voice.duration)),
      waveform: voice.waveform,
      mimeType: "audio/mp4",
      fileExtension: url.pathExtension.isEmpty ? "m4a" : url.pathExtension
    )
    duration = TimeInterval(max(1, voice.duration))
    samples = Array(voice.waveform)
    playbackProgress = 0
    isPlaying = false
    phase = .review
    return true
  }

  private func ensureMicrophoneAccess() async -> MicrophoneAccessGrant? {
    switch MacPermissions.mediaStatus(for: .audio) {
    case .authorized:
      return .authorized
    case .notDetermined:
      let granted = await MacPermissions.requestMediaAccess(for: .audio)
      if !granted {
        ToastCenter.shared.showError("Microphone access is required to record voice messages.")
        return nil
      }
      return .newlyAuthorized
    case .denied, .restricted:
      ToastCenter.shared.showError("Allow microphone access to record voice messages.")
      MacPermissions.openSystemSettings(.microphone)
      return nil
    @unknown default:
      ToastCenter.shared.showError("Microphone access is unavailable.")
      return nil
    }
  }

  private func settleMicrophoneAccessIfNeeded(_ access: MicrophoneAccessGrant, startId: UUID) async -> Bool {
    guard access == .newlyAuthorized else { return true }

    await Task.yield()
    try? await Task.sleep(nanoseconds: Self.microphonePermissionSettleDelay)
    guard self.startId == startId else { return false }

    if MacPermissions.mediaStatus(for: .audio) == .authorized {
      return true
    }

    ToastCenter.shared.showError("Microphone access is unavailable.")
    return false
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

  private func shouldRemoveRecordingFile(_ recording: ComposeVoiceRecording) -> Bool {
    guard let draftVoice,
          let draftURL = FileMediaItem.voice(draftVoice).localFileURL()
    else {
      return true
    }

    return draftURL.standardizedFileURL != recording.fileURL.standardizedFileURL
  }

  private func reset() {
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    phase = .idle
  }

  private static let microphonePermissionSettleDelay: UInt64 = 120_000_000
}

private enum MicrophoneAccessGrant: Equatable {
  case authorized
  case newlyAuthorized
}
