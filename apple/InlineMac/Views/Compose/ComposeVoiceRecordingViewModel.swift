import AVFoundation
import Combine
import Foundation
import InlineKit
import InlineMacUI
import InlineProtocol
import Logger

enum ComposeVoiceRecordingPhase: Equatable {
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

  private let peerId: InlineKit.Peer
  private let log = Log.scoped("ComposeVoiceRecordingViewModel")

  private let recorder: MacVoiceRecorder
  private var session: MacVoiceRecordingSession?
  private var recording: MacVoiceRecording?
  private var player: AVAudioPlayer?
  private var playbackTimer: Timer?
  private var stopRecordingAction: (@Sendable () -> Void)?
  private var draftVoice: Client_MessageVoiceContent?
  private var startTask: Task<Void, Never>?
  private var finishTask: Task<Bool, Never>?
  private var recorderUpdatesTask: Task<Void, Never>?
  private var operationId = UUID()

  var isActive: Bool {
    phase != .idle
  }

  var draftVoiceAttachmentId: String? {
    guard let draftVoice else { return nil }
    return FileMediaItem.voice(draftVoice).getItemUniqueId()
  }

  init(peerId: InlineKit.Peer, recorder: MacVoiceRecorder = .shared) {
    self.peerId = peerId
    self.recorder = recorder
  }

  deinit {
    startTask?.cancel()
    finishTask?.cancel()
    recorderUpdatesTask?.cancel()
    playbackTimer?.invalidate()
    player?.stop()
    stopRecordingAction?()

    let session = session
    let recordingURL = recording?.fileURL
    let draftRecordingURL = draftVoice.flatMap {
      FileMediaItem.voice($0).localFileURL()
    }
    let shouldRemoveRecording = recordingURL.map {
      draftRecordingURL?.standardizedFileURL != $0.standardizedFileURL
    } ?? false
    Task {
      await session?.cancel()
      if shouldRemoveRecording, let recordingURL {
        try? FileManager.default.removeItem(at: recordingURL)
      }
    }
  }

  func requestStart() {
    guard phase == .idle else { return }

    let operationId = UUID()
    self.operationId = operationId
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    phase = .starting
    startTask = Task { [weak self] in
      await self?.performStart(operationId: operationId)
    }
  }

  private func performStart(operationId: UUID) async {
    guard let access = await ensureMicrophoneAccess() else {
      resetIfCurrent(operationId)
      return
    }
    guard await settleMicrophoneAccessIfNeeded(access, operationId: operationId) else {
      resetIfCurrent(operationId)
      return
    }
    guard self.operationId == operationId, phase == .starting else { return }

    do {
      let session = try await recorder.start()

      guard self.operationId == operationId, phase == .starting else {
        await session.cancel()
        return
      }

      self.session = session
      observe(session.updates, operationId: operationId)
      startTask = nil
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
      resetIfCurrent(operationId)
    }
  }

  func pauseRecording(onFinished: (@MainActor () -> Void)? = nil) {
    guard phase == .recording, let session else { return }

    let operationId = UUID()
    self.operationId = operationId
    self.session = nil
    recorderUpdatesTask?.cancel()
    recorderUpdatesTask = nil
    stopRecordingAction?()
    stopRecordingAction = nil
    phase = .finishing

    finishTask = Task { [weak self] in
      guard let self else { return false }
      let finished = await finish(
        session: session,
        operationId: operationId
      )
      if finished {
        onFinished?()
      }
      return finished
    }
  }

  func finalizeRecordingForSend() async -> Bool {
    if phase == .recording {
      pauseRecording()
    }

    if phase == .finishing, let finishTask {
      _ = await finishTask.value
    }

    return phase == .review && recording != nil
  }

  func cancel() {
    operationId = UUID()
    startTask?.cancel()
    startTask = nil
    finishTask?.cancel()
    finishTask = nil
    recorderUpdatesTask?.cancel()
    recorderUpdatesTask = nil
    let session = session
    self.session = nil
    if let session {
      Task { await session.cancel() }
    }
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

  private func finish(
    session: MacVoiceRecordingSession,
    operationId: UUID
  ) async -> Bool {
    do {
      let recording = try await session.finish()
      guard self.operationId == operationId, phase == .finishing else {
        try? FileManager.default.removeItem(at: recording.fileURL)
        return false
      }

      self.recording = recording
      draftVoice = nil
      duration = recording.duration
      samples = Array(recording.waveform)
      playbackProgress = 0
      isPlaying = false
      finishTask = nil
      phase = .review
      return true
    } catch {
      guard self.operationId == operationId else { return false }
      log.error("Failed to finish voice recording", error: error)
      ToastCenter.shared.showError(error.localizedDescription)
      reset()
      return false
    }
  }

  private func observe(
    _ updates: AsyncStream<MacVoiceRecordingUpdate>,
    operationId: UUID
  ) {
    recorderUpdatesTask?.cancel()
    recorderUpdatesTask = Task { [weak self] in
      for await update in updates {
        guard !Task.isCancelled else { return }
        guard let self,
              self.operationId == operationId,
              self.phase == .recording
        else { return }
        duration = update.duration
        samples = update.samples
      }
    }
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
    operationId = UUID()
    startTask?.cancel()
    startTask = nil
    finishTask?.cancel()
    finishTask = nil
    recorderUpdatesTask?.cancel()
    recorderUpdatesTask = nil
    let session = session
    self.session = nil
    if let session {
      Task { await session.cancel() }
    }
    stopRecordingAction?()
    stopRecordingAction = nil

    draftVoice = voice
    recording = MacVoiceRecording(
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

  private func settleMicrophoneAccessIfNeeded(
    _ access: MicrophoneAccessGrant,
    operationId: UUID
  ) async -> Bool {
    guard access == .newlyAuthorized else { return true }

    await Task.yield()
    try? await Task.sleep(nanoseconds: Self.microphonePermissionSettleDelay)
    guard self.operationId == operationId else { return false }

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

  private func shouldRemoveRecordingFile(_ recording: MacVoiceRecording) -> Bool {
    guard let draftVoice,
          let draftURL = FileMediaItem.voice(draftVoice).localFileURL()
    else {
      return true
    }

    return draftURL.standardizedFileURL != recording.fileURL.standardizedFileURL
  }

  private func reset() {
    startTask = nil
    finishTask = nil
    duration = 0
    samples = []
    playbackProgress = 0
    isPlaying = false
    phase = .idle
  }

  private func resetIfCurrent(_ operationId: UUID) {
    guard self.operationId == operationId else { return }
    reset()
  }

  private static let microphonePermissionSettleDelay: UInt64 = 120_000_000
}

private enum MicrophoneAccessGrant: Equatable {
  case authorized
  case newlyAuthorized
}
