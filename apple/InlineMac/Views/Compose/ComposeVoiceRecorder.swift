import AVFoundation
import Foundation
import Logger

struct ComposeVoiceRecording {
  let fileURL: URL
  let data: Data
  let duration: TimeInterval
  let waveform: Data
  let mimeType: String
  let fileExtension: String
}

final class ComposeVoiceRecorder: NSObject {
  private let log = Log.scoped("ComposeVoiceRecorder")
  private var recorder: AVAudioRecorder?
  private var meterTimer: Timer?
  private var startedAt: Date?
  private var samples: [UInt8] = []

  var onUpdate: ((TimeInterval, [UInt8]) -> Void)?

  var isRecording: Bool {
    recorder?.isRecording == true
  }

  func start() throws {
    stopMetering()
    samples.removeAll()

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-voice-\(UUID().uuidString).m4a")

    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32_000,
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ]

    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.isMeteringEnabled = true
    recorder.prepareToRecord()

    guard recorder.record() else {
      throw ComposeVoiceRecorderError.startFailed
    }

    self.recorder = recorder
    startedAt = Date()
    startMetering()
  }

  func finish() throws -> ComposeVoiceRecording {
    guard let recorder else {
      throw ComposeVoiceRecorderError.notRecording
    }

    let duration = max(recorder.currentTime, Date().timeIntervalSince(startedAt ?? Date()))
    let url = recorder.url
    recorder.stop()
    stopMetering()
    self.recorder = nil
    startedAt = nil

    let data = try Data(contentsOf: url)
    if data.isEmpty {
      try? FileManager.default.removeItem(at: url)
      throw ComposeVoiceRecorderError.emptyRecording
    }

    return ComposeVoiceRecording(
      fileURL: url,
      data: data,
      duration: duration,
      waveform: Self.waveformData(from: samples),
      mimeType: "audio/mp4",
      fileExtension: "m4a"
    )
  }

  func cancel() {
    let url = recorder?.url
    recorder?.stop()
    stopMetering()
    recorder = nil
    startedAt = nil
    samples.removeAll()

    if let url {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func startMetering() {
    meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.captureMeter()
      }
    }
  }

  private func stopMetering() {
    meterTimer?.invalidate()
    meterTimer = nil
  }

  private func captureMeter() {
    guard let recorder else { return }

    recorder.updateMeters()
    let power = recorder.averagePower(forChannel: 0)
    let normalized = Self.normalizedPower(power)
    let sample = UInt8(max(0, min(255, Int((normalized * 255).rounded()))))
    samples.append(sample)
    onUpdate?(recorder.currentTime, samples)
  }

  private static func normalizedPower(_ power: Float) -> Float {
    guard power.isFinite else { return 0 }
    if power <= -60 { return 0 }
    if power >= 0 { return 1 }

    return pow(10, power / 20)
  }

  private static func waveformData(from samples: [UInt8], targetCount: Int = 96) -> Data {
    guard !samples.isEmpty else {
      return Data(repeating: 28, count: targetCount)
    }

    if samples.count <= targetCount {
      return Data(samples)
    }

    let bucketSize = Double(samples.count) / Double(targetCount)
    let reduced = (0 ..< targetCount).map { index -> UInt8 in
      let start = Int(Double(index) * bucketSize)
      let end = min(samples.count, Int(Double(index + 1) * bucketSize))
      guard start < end else { return 0 }
      return samples[start ..< end].max() ?? 0
    }

    return Data(reduced)
  }
}

enum ComposeVoiceRecorderError: LocalizedError {
  case startFailed
  case notRecording
  case emptyRecording

  var errorDescription: String? {
    switch self {
    case .startFailed:
      "Could not start voice recording."
    case .notRecording:
      "No active voice recording."
    case .emptyRecording:
      "Voice recording is empty."
    }
  }
}
