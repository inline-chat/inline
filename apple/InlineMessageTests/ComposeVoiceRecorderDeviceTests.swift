import AVFoundation
import AVKit
import Auth
import Foundation
import InlineConfig
import InlineKit
import Testing
import UIKit
@testable import InlineIOS

@Suite("Physical iOS voice capture", .serialized)
@MainActor
struct ComposeVoiceRecorderDeviceTests {
  @Test("Production capture plays through failed video replay and restarts",
        .enabled(if: ProcessInfo.processInfo.environment["INLINE_DEVICE_VOICE_CAPTURE"] == "1"))
  func captureAndRestart() async throws {
    // Check the runner before touching auth/database singletons, then prove that
    // the hosted process cannot use the installed app's account or database.
    let isTestProcess = TestProcess.isRunning
    try #require(isTestProcess)
    #if targetEnvironment(simulator)
    let isPhysicalDevice = false
    #else
    let isPhysicalDevice = true
    #endif
    try #require(isPhysicalDevice, "This opt-in probe requires a physical iPhone.")
    let authIsIsolated = !Auth.shared.getIsLoggedIn() && Auth.shared.getCurrentUserId() == nil
    try #require(authIsIsolated)
    let databaseIsIsolated = !AppDatabase.shared.isPersistent
    try #require(databaseIsIsolated)
    let applicationIsActive = UIApplication.shared.applicationState == .active
    try #require(applicationIsActive)
    let microphoneIsGranted = AVAudioApplication.shared.recordPermission == .granted
    try #require(microphoneIsGranted, "Grant microphone access in the Debug app before opting in.")
    let sessionIsVacant = InlineAudioSession.shared.current == nil
    try #require(sessionIsVacant)
    let voiceIsIdle = !SharedAudioPlayer.shared.isVoiceSelected
    try #require(voiceIsIdle)

    let recorder = ComposeVoiceRecorder()
    defer {
      recorder.onUpdate = nil
      recorder.onUnexpectedStop = nil
    }
    var summaries: [String] = []

    // Reuse the real recorder so the second start exercises its stop/cancel
    // cleanup and the production audio-session generation boundary.
    for attempt in 1 ... 2 {
      var observedDuration: TimeInterval = 0
      var updateCount = 0
      var monotonicProgress = true
      var unexpectedStop = false
      recorder.onUpdate = { duration, _ in
        monotonicProgress = monotonicProgress && duration.isFinite && duration >= observedDuration
        observedDuration = duration
        updateCount += 1
      }
      recorder.onUnexpectedStop = { _ in unexpectedStop = true }

      do {
        try await recorder.start()
        let ownsRecordingSession = InlineAudioSession.shared.current?.owner == .recording
        guard recorder.isRecording, ownsRecordingSession else {
          recorder.cancel()
          Issue.record("Production recorder did not enter active capture with recording ownership.")
          return
        }
        try await Task.sleep(for: .seconds(3))
        let captureIsStillActive = recorder.isRecording
        #expect(captureIsStillActive)
        #expect(!unexpectedStop)

        let recording = try await recorder.finish()
        let audio = try AVAudioFile(forReading: recording.fileURL)
        let sampleRate = audio.processingFormat.sampleRate
        let frameCount = audio.length
        let encodedBytes = recording.data.count
        let validatedDuration = recording.duration
        let encodedDuration = Double(frameCount) / sampleRate
        let ownerReleased = InlineAudioSession.shared.current == nil
        let recordingStopped = !recorder.isRecording
        #expect(recordingStopped)
        #expect(updateCount > 1)
        #expect(monotonicProgress)
        #expect(observedDuration >= 2)
        #expect(encodedDuration.isFinite && encodedDuration >= 2.5)
        #expect(abs(encodedDuration - observedDuration) < 0.75)
        #expect(abs(encodedDuration - validatedDuration) < 0.001)
        #expect(encodedBytes > 0)
        try #require(ownerReleased, "Production recording ownership was not released before restart.")

        if attempt == 1 {
          guard let defaults = UserDefaults(suiteName: "InlineVoiceDeviceProbe.\(UUID().uuidString)") else {
            Issue.record("Could not create isolated playback preferences.")
            return
          }
          let engine = AVAudioPlayerPlaybackEngine()
          let preview = AudioPlaybackCenter(engine: engine, userDefaults: defaults,
                                            audioSession: .shared, usesSystemIntegration: false)
          defer { preview.close() }
          preview.setPlaybackRate(1.5)
          try preview.play(fileURL: recording.fileURL,
                           item: AudioPlaybackItem(kind: .voice, chatId: 0, messageId: 0, mediaId: 0),
                           presentation: AudioPlaybackPresentation(display: AudioPlaybackDisplay(title: "Device capture")))
          try await requirePlaybackStart(preview)
          let ownsPlayback = engine.isPlaying && preview.isPlaying && InlineAudioSession.shared.current?.owner == .voice
          #expect(ownsPlayback)
          let startedSeconds = engine.currentTime
          let startedAt = ProcessInfo.processInfo.systemUptime
          try await Task.sleep(for: .milliseconds(600))
          let playedSeconds = engine.currentTime
          let measuredRate = (playedSeconds - startedSeconds) / (ProcessInfo.processInfo.systemUptime - startedAt)
          let selectedRate = preview.playbackRate
          #expect(selectedRate == 1.5)
          #expect(measuredRate > 1.2 && measuredRate < 1.8)
          preview.pause()
          let pausedSeconds = engine.currentTime
          try await Task.sleep(for: .milliseconds(200))
          let pauseDrift = abs(engine.currentTime - pausedSeconds)
          #expect(pauseDrift < 0.025)

          let sessionIsVacantForVideo = InlineAudioSession.shared.current == nil
          try #require(sessionIsVacantForVideo)
          guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
          else {
            Issue.record("No active UIKit scene for the local failed-video regression.")
            return
          }
          let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
          let window = UIWindow(windowScene: scene)
          let presenter = UIViewController()
          window.rootViewController = presenter
          let source = UIView(frame: CGRect(x: 20, y: 20, width: 48, height: 48))
          presenter.view.addSubview(source)
          let malformedVideo = FileManager.default.temporaryDirectory
            .appendingPathComponent("inline-video-failure-probe-\(UUID().uuidString).mp4")
          try Data("malformed local video fixture".utf8).write(to: malformedVideo)
          let viewer = ImageViewerController(videoURL: malformedVideo, sourceView: source)
          defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            previousKeyWindow?.makeKey()
          }
          window.makeKeyAndVisible()
          presenter.present(viewer, animated: false)
          var nativePlayer: AVPlayer?
          for _ in 0 ..< 80 {
            nativePlayer = viewer.children.compactMap { $0 as? AVPlayerViewController }.first?.player
            if nativePlayer?.currentItem?.status == .failed,
               nativePlayer?.timeControlStatus == .paused, InlineAudioSession.shared.current == nil { break }
            try await Task.sleep(for: .milliseconds(50))
          }
          guard let failedPlayer = nativePlayer else {
            Issue.record("Production video viewer did not create its native player within four seconds.")
            return
          }
          let videoItemFailed = failedPlayer.currentItem?.status == .failed
          let videoPlayerStatus = failedPlayer.status.rawValue
          let failedVideoReleased = failedPlayer.timeControlStatus == .paused && InlineAudioSession.shared.current == nil
          try #require(videoItemFailed && failedVideoReleased)

          let seekAccepted = preview.seek(to: 0.25)
          let seekSeconds = engine.currentTime
          #expect(seekAccepted)
          #expect(abs(seekSeconds - encodedDuration * 0.25) < 0.05)
          try preview.resume()
          try await requirePlaybackStart(preview)
          failedPlayer.play()
          try await Task.sleep(for: .milliseconds(250))
          let resumedSeconds = engine.currentTime
          let failedReplayPaused = failedPlayer.timeControlStatus == .paused
          let retainedVoiceOwnership = InlineAudioSession.shared.current?.owner == .voice && engine.isPlaying && preview.isPlaying
          #expect(failedReplayPaused)
          #expect(retainedVoiceOwnership)
          #expect(resumedSeconds > seekSeconds + 0.15)
          preview.close()
          let playbackOwnerReleased = InlineAudioSession.shared.current == nil
          try #require(playbackOwnerReleased)
          summaries.append("preview playedSeconds=\(playedSeconds) selectedRate=\(selectedRate) measuredRate=\(measuredRate) pauseDrift=\(pauseDrift) seekSeconds=\(seekSeconds) resumedSeconds=\(resumedSeconds) videoItemFailed=\(videoItemFailed) videoPlayerStatus=\(videoPlayerStatus) failedVideoReleased=\(failedVideoReleased) failedReplayPaused=\(failedReplayPaused) retainedVoiceOwnership=\(retainedVoiceOwnership) ownerReleased=\(playbackOwnerReleased)")
        }

        // Silence is valid. Retain successful local drafts and record only
        // aggregate metadata; never attach audio, waveform samples or file URLs.
        summaries.append("capture=\(attempt) updates=\(updateCount) progressSeconds=\(observedDuration) encodedSeconds=\(encodedDuration) frames=\(frameCount) sampleRate=\(sampleRate) bytes=\(encodedBytes) ownerReleased=\(ownerReleased)")
      } catch {
        // Use only the recorder's normal failure cancellation. Do not expose
        // underlying AVFoundation errors that may contain a generated file URL.
        recorder.cancel()
        let ownerReleased = InlineAudioSession.shared.current == nil
        #expect(ownerReleased)
        Issue.record("Production microphone capture, playback or encoded-file validation failed.")
        return
      }
    }
    Attachment.record(summaries.joined(separator: "\n"), named: "voice-device-capture-metadata.txt")
  }

  private func requirePlaybackStart(_ center: AudioPlaybackCenter) async throws {
    for _ in 0 ..< 80 {
      if center.isPlaying { return }
      if center.playbackError != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let started = center.isPlaying && !center.isStarting
    try #require(started, "Native activation did not complete with actual playback within four seconds.")
  }
}
