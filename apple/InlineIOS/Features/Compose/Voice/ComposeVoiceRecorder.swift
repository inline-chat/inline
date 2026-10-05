import AVFoundation
import Foundation
import InlineKit
import Logger

@MainActor
final class ComposeVoiceRecorder: NSObject, AVAudioRecorderDelegate {
  private let log = Log.scoped("ComposeVoiceRecorder")
  private var recorder: AVAudioRecorder?
  private var fileURL: URL?
  private var samples: [UInt8] = []
  private var meterTimer: Timer?
  private var startedAt: TimeInterval?
  private var capturedDuration: TimeInterval = 0
  private var lastProgressAt: TimeInterval = 0
  private var lastMeteredAt: TimeInterval = 0
  private var sessionToken: InlineAudioSession.Token?

  var onUpdate: ((TimeInterval, [UInt8]) -> Void)?
  var onUnexpectedStop: ((ComposeVoiceRecorderError) -> Void)?

  var isRecording: Bool {
    recorder?.isRecording == true
  }

  deinit {
    meterTimer?.invalidate()
    recorder?.stop()
    let sessionToken = sessionToken
    Task { @MainActor in
      if let sessionToken {
        InlineAudioSession.shared.release(sessionToken)
      }
    }
  }

  func start(isCurrent: @escaping @MainActor () -> Bool = { true }) async throws {
    cancel()
    stopMetering()

    let id = UUID().uuidString
    let finalURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-ios-voice-\(id).m4a")

    var attemptToken: InlineAudioSession.Token?
    do {
      let token = try await configureSession(isCurrent: isCurrent)
      attemptToken = token
      guard sessionToken == token, InlineAudioSession.shared.owns(token), isCurrent(), !Task.isCancelled
      else { throw CancellationError() }
      let recorder = try AVAudioRecorder(url: finalURL, settings: Self.recordingSettings)
      recorder.delegate = self
      recorder.isMeteringEnabled = true
      guard recorder.prepareToRecord() else {
        recorder.stop()
        throw ComposeVoiceRecorderError.preparationFailed
      }

      guard recorder.record() else {
        recorder.stop()
        throw ComposeVoiceRecorderError.startFailed
      }

      self.recorder = recorder
      fileURL = finalURL
      samples = []
      capturedDuration = 0
      let now = ProcessInfo.processInfo.systemUptime
      startedAt = now
      lastProgressAt = now
      lastMeteredAt = now
      logDiagnostics(event: "started", recorder: recorder)
      startMetering()
    } catch {
      logDiagnostics(event: "startFailed", recorder: nil)
      try? FileManager.default.removeItem(at: finalURL)
      if let attemptToken { cleanupSession(attemptToken) }
      throw error
    }
  }

  func finish() async throws -> ComposeVoiceRecording {
    guard let recorder, let fileURL else {
      throw ComposeVoiceRecorderError.notRecording
    }

    updateCapturedDuration(recorder.currentTime)
    let captureDuration = capturedDuration
    let wallDuration = self.wallDuration
    let samples = samples
    logDiagnostics(event: "finishing", recorder: recorder)
    recorder.delegate = nil
    recorder.stop()
    stopMetering()
    self.recorder = nil
    self.fileURL = nil
    self.samples = []
    startedAt = nil
    capturedDuration = 0
    cleanupSession()

    do {
      let recording = try await Self.makeRecording(fileURL: fileURL, samples: samples)
      log.info("Validated voice capture encodedSeconds=\(recording.duration) recorderSeconds=\(captureDuration) wallSeconds=\(wallDuration) bytes=\(recording.data.count)")
      return recording
    } catch {
      log.warning("Rejected voice capture recorderSeconds=\(captureDuration) wallSeconds=\(wallDuration)")
      throw error
    }
  }

  func cancel() {
    let fileURL = fileURL
    recorder?.delegate = nil
    recorder?.stop()
    stopMetering()
    recorder = nil
    self.fileURL = nil
    samples = []
    startedAt = nil
    capturedDuration = 0
    if let fileURL {
      try? FileManager.default.removeItem(at: fileURL)
    }
    cleanupSession()
  }

  private func configureSession(isCurrent: @MainActor () -> Bool) async throws -> InlineAudioSession.Token {
    // Fence pending voice downloads as well as a currently playing message.
    SharedAudioPlayer.shared.stop()
    let sessionOwner = InlineAudioSession.shared
    let token = try sessionOwner.acquire(.recording)
    sessionToken = token
    do {
      try await sessionOwner.activate(
        token,
        category: .playAndRecord,
        mode: .default,
        options: [.allowBluetoothHFP, .defaultToSpeaker]
      )
      guard sessionToken == token, sessionOwner.owns(token), isCurrent(), !Task.isCancelled
      else { throw CancellationError() }
      let session = AVAudioSession.sharedInstance()
      // The recorder owns the encoded sample rate; leave hardware timing to the route.
      _ = try VoiceInputController.shared.applyPreferredInput(to: session)
      return token
    } catch {
      cleanupSession(token)
      throw error
    }
  }

  private func cleanupSession(_ token: InlineAudioSession.Token? = nil) {
    guard let token = token ?? sessionToken else { return }
    if sessionToken == token { sessionToken = nil }
    InlineAudioSession.shared.release(token)
  }

  private func startMetering() {
    meterTimer = Timer.scheduledTimer(withTimeInterval: Self.meterInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.publishMeter()
      }
    }
  }

  private func stopMetering() {
    meterTimer?.invalidate()
    meterTimer = nil
  }

  private func publishMeter() {
    guard let recorder else { return }

    guard recorder.isRecording else {
      reportUnexpectedStop(.captureStopped, recorder: recorder)
      return
    }

    let now = ProcessInfo.processInfo.systemUptime
    // A busy main actor is not evidence that audio stopped. Start observing again
    // after a timer gap instead of counting the unobserved interval as a stall.
    if now - lastMeteredAt > Self.maximumMeterGap {
      lastProgressAt = now
    }
    lastMeteredAt = now
    if updateCapturedDuration(recorder.currentTime) {
      lastProgressAt = now
    }
    if now - lastProgressAt >= Self.captureStallTimeout {
      reportUnexpectedStop(.captureStopped, recorder: recorder)
      return
    }

    recorder.updateMeters()
    samples.append(Self.meterSample(fromAveragePower: recorder.averagePower(forChannel: 0)))

    onUpdate?(capturedDuration, Self.liveSamples(from: samples))
  }

  @discardableResult
  private func updateCapturedDuration(_ currentTime: TimeInterval) -> Bool {
    guard currentTime.isFinite, currentTime > capturedDuration else { return false }
    capturedDuration = currentTime
    return true
  }

  private var wallDuration: TimeInterval {
    guard let startedAt else { return 0 }
    return max(0, ProcessInfo.processInfo.systemUptime - startedAt)
  }

  func logRouteChange(reason: AVAudioSession.RouteChangeReason?) {
    guard let recorder else { return }
    logDiagnostics(event: "routeChanged:\(reason?.rawValue ?? 0)", recorder: recorder)
  }

  private func logDiagnostics(event: String, recorder: AVAudioRecorder?) {
    let session = AVAudioSession.sharedInstance()
    let inputs = session.currentRoute.inputs.prefix(4).map(\.portType.rawValue).joined(separator: ",")
    let outputs = session.currentRoute.outputs.prefix(4).map(\.portType.rawValue).joined(separator: ",")
    let ownsSession = sessionToken.map { InlineAudioSession.shared.owns($0) } ?? false
    let preferredInput = session.preferredInput?.portType.rawValue ?? "automatic"
    let diagnostic = "Voice capture event=\(event) recorderSeconds=\(capturedDuration) wallSeconds=\(wallDuration) recording=\(recorder?.isRecording ?? false) ownsSession=\(ownsSession) inputAvailable=\(session.isInputAvailable) inputMuted=\(AVAudioApplication.shared.isInputMuted) sampleRate=\(session.sampleRate) category=\(session.category.rawValue) mode=\(session.mode.rawValue) inputs=\(inputs) outputs=\(outputs) preferredInput=\(preferredInput) meterMaximum=\(samples.max() ?? 0)"
    log.info(diagnostic)
    #if DEBUG
    // Device launch consoles forward stdout, while unified logs require a separate stream.
    print(diagnostic)
    #endif
  }

  private func reportUnexpectedStop(_ error: ComposeVoiceRecorderError, recorder: AVAudioRecorder) {
    guard self.recorder === recorder, meterTimer != nil else { return }
    updateCapturedDuration(recorder.currentTime)
    logDiagnostics(event: "unexpectedStop", recorder: recorder)
    stopMetering()
    onUnexpectedStop?(error)
  }

  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    let identity = ObjectIdentifier(recorder)
    Task { @MainActor [weak self] in
      guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
      self.reportUnexpectedStop(flag ? .captureStopped : .encodingFailed, recorder: current)
    }
  }

  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
    let identity = ObjectIdentifier(recorder)
    Task { @MainActor [weak self] in
      guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
      self.reportUnexpectedStop(.encodingFailed, recorder: current)
    }
  }

  nonisolated fileprivate static func normalizedPower(_ power: Float) -> Float {
    guard power.isFinite else { return 0 }
    if power <= -60 { return 0 }
    if power >= 0 { return 1 }

    let linear = pow(10, power / 20)
    return pow(linear, 0.55)
  }

  private nonisolated static func makeRecording(
    fileURL: URL,
    samples: [UInt8]
  ) async throws -> ComposeVoiceRecording {
    try await Task.detached(priority: .userInitiated) {
      do {
        return try ComposeVoiceRecordingValidation.load(fileURL: fileURL, waveform: Self.waveformData(from: samples))
      } catch {
        try? FileManager.default.removeItem(at: fileURL)
        throw error
      }
    }.value
  }

  private nonisolated static func waveformData(from samples: [UInt8], targetCount: Int = 96) -> Data {
    Data(reducedSamples(samples, targetCount: targetCount, emptyValue: 0))
  }

  private nonisolated static func liveSamples(from samples: [UInt8]) -> [UInt8] {
    guard samples.count < liveSampleCount else {
      return Array(samples.suffix(liveSampleCount))
    }

    return Array(repeating: 0, count: liveSampleCount - samples.count) + samples
  }

  private nonisolated static func reducedSamples(
    _ samples: [UInt8],
    targetCount: Int,
    emptyValue: UInt8 = 0
  ) -> [UInt8] {
    let targetCount = max(targetCount, 1)
    guard !samples.isEmpty else {
      return Array(repeating: emptyValue, count: targetCount)
    }

    guard samples.count != targetCount else { return samples }

    if samples.count < targetCount {
      let scale = Double(max(samples.count - 1, 0)) / Double(max(targetCount - 1, 1))
      return (0 ..< targetCount).map { index in
        samples[Int((Double(index) * scale).rounded())]
      }
    }

    let bucketSize = Double(samples.count) / Double(targetCount)
    return (0 ..< targetCount).map { index -> UInt8 in
      let start = Int(Double(index) * bucketSize)
      let end = min(samples.count, max(start + 1, Int(Double(index + 1) * bucketSize)))
      return samples[start ..< end].max() ?? 0
    }
  }

  private nonisolated static func meterSample(fromAveragePower power: Float) -> UInt8 {
    let normalized = normalizedPower(power)
    return UInt8(max(0, min(255, Int((normalized * 255).rounded()))))
  }

  private nonisolated static let sampleRate: Double = 44_100
  private nonisolated static let meterInterval: TimeInterval = 1.0 / 25.0
  private nonisolated static let liveSampleCount = 120
  private nonisolated static let maximumMeterGap: TimeInterval = 1
  private nonisolated static let captureStallTimeout: TimeInterval = 4
  private static let recordingSettings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 1,
    AVEncoderBitRateKey: 40_000,
    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
  ]
}
