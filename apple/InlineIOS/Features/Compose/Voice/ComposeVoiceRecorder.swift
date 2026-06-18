import AVFoundation
import Foundation

struct ComposeVoiceRecording: Sendable {
  let fileURL: URL
  let data: Data
  let duration: TimeInterval
  let waveform: Data
  let mimeType: String
  let fileExtension: String
}

@MainActor
final class ComposeVoiceRecorder: NSObject {
  private var recorder: AVAudioRecorder?
  private var fileURL: URL?
  private var samples: [UInt8] = []
  private var meterTimer: Timer?
  private var startedAt: Date?
  private var sessionActive = false

  var onUpdate: ((TimeInterval, [UInt8]) -> Void)?

  var isRecording: Bool {
    recorder?.isRecording == true
  }

  func start() throws {
    cancel()
    stopMetering()
    try configureSession()

    let id = UUID().uuidString
    let finalURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-ios-voice-\(id).m4a")

    let recorder = try AVAudioRecorder(url: finalURL, settings: Self.recordingSettings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()

    guard recorder.record() else {
      try? FileManager.default.removeItem(at: finalURL)
      cleanupSession()
      throw ComposeVoiceRecorderError.startFailed
    }

    self.recorder = recorder
    fileURL = finalURL
    samples = []
    startedAt = Date()
    startMetering()
  }

  func finish() async throws -> ComposeVoiceRecording {
    guard let recorder, let fileURL else {
      throw ComposeVoiceRecorderError.notRecording
    }

    let elapsed = Date().timeIntervalSince(startedAt ?? Date())
    let duration = max(recorder.currentTime, elapsed)
    let samples = samples
    recorder.stop()
    stopMetering()
    self.recorder = nil
    self.fileURL = nil
    self.samples = []
    startedAt = nil
    cleanupSession()

    return try await Self.makeRecording(
      fileURL: fileURL,
      duration: duration,
      samples: samples
    )
  }

  func cancel() {
    let fileURL = fileURL
    recorder?.stop()
    stopMetering()
    recorder = nil
    self.fileURL = nil
    samples = []
    startedAt = nil
    if let fileURL {
      try? FileManager.default.removeItem(at: fileURL)
    }
    cleanupSession()
  }

  private func configureSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
    try? session.setPreferredSampleRate(Self.sampleRate)
    try session.setActive(true)
    sessionActive = true
  }

  private func cleanupSession() {
    guard sessionActive else { return }
    sessionActive = false
    try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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

    recorder.updateMeters()
    samples.append(Self.meterSample(fromAveragePower: recorder.averagePower(forChannel: 0)))

    let elapsed = Date().timeIntervalSince(startedAt ?? Date())
    let duration = max(recorder.currentTime, elapsed)
    onUpdate?(duration, Self.liveSamples(from: samples))
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
    duration: TimeInterval,
    samples: [UInt8]
  ) async throws -> ComposeVoiceRecording {
    try await Task.detached(priority: .userInitiated) {
      do {
        let data = try Data(contentsOf: fileURL)
        if data.isEmpty {
          try? FileManager.default.removeItem(at: fileURL)
          throw ComposeVoiceRecorderError.emptyRecording
        }

        if data.count > Self.maxVoiceBytes {
          try? FileManager.default.removeItem(at: fileURL)
          throw ComposeVoiceRecorderError.fileTooLarge
        }

        return ComposeVoiceRecording(
          fileURL: fileURL,
          data: data,
          duration: duration,
          waveform: Self.waveformData(from: samples),
          mimeType: "audio/mp4",
          fileExtension: "m4a"
        )
      } catch {
        try? FileManager.default.removeItem(at: fileURL)
        throw error
      }
    }.value
  }

  private nonisolated static func waveformData(from samples: [UInt8], targetCount: Int = 96) -> Data {
    Data(reducedSamples(samples, targetCount: targetCount, emptyValue: 28))
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
  private nonisolated static let maxVoiceBytes = 20 * 1_024 * 1_024
  private nonisolated static let recordingSettings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 40_000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
  ]
}

enum ComposeVoiceRecorderError: LocalizedError {
  case startFailed
  case notRecording
  case emptyRecording
  case fileTooLarge

  var errorDescription: String? {
    switch self {
    case .startFailed:
      "Could not start voice recording."
    case .notRecording:
      "No active voice recording."
    case .emptyRecording:
      "Voice recording is empty."
    case .fileTooLarge:
      "Voice recording is too large to send."
    }
  }
}
