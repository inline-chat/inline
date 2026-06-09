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

@MainActor
final class ComposeVoiceRecorder: NSObject {
  private let log = Log.scoped("ComposeVoiceRecorder")
  private var engine: AVAudioEngine?
  private var capture: VoiceCaptureState?
  private var meterTimer: Timer?
  private var startedAt: Date?

  var onUpdate: ((TimeInterval, [UInt8]) -> Void)?

  var isRecording: Bool {
    engine?.isRunning == true
  }

  func start() throws {
    cancel()
    stopMetering()

    let id = UUID().uuidString
    let rawURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-voice-\(id).caf")
    let finalURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("inline-voice-\(id).m4a")

    let engine = AVAudioEngine()
    let input = engine.inputNode

    do {
      try input.setVoiceProcessingEnabled(true)
    } catch {
      log.warning("Voice processing unavailable for input route: \(error.localizedDescription)")
    }

    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
      throw ComposeVoiceRecorderError.startFailed
    }

    guard inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved else {
      throw ComposeVoiceRecorderError.unsupportedInputFormat
    }

    let rawFile = try AVAudioFile(
      forWriting: rawURL,
      settings: inputFormat.settings,
      commonFormat: inputFormat.commonFormat,
      interleaved: inputFormat.isInterleaved
    )
    let capture = VoiceCaptureState(
      rawURL: rawURL,
      finalURL: finalURL,
      file: rawFile,
      sampleRate: inputFormat.sampleRate
    )

    input.installTap(onBus: 0, bufferSize: Self.bufferSize, format: inputFormat) { buffer, _ in
      capture.write(buffer)
    }

    do {
      engine.prepare()
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      capture.discardFiles()
      throw error
    }

    self.engine = engine
    self.capture = capture
    startedAt = Date()
    startMetering()
  }

  func finish() throws -> ComposeVoiceRecording {
    guard let engine, let capture else {
      throw ComposeVoiceRecorderError.notRecording
    }

    let elapsed = Date().timeIntervalSince(startedAt ?? Date())
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    stopMetering()
    self.engine = nil
    self.capture = nil
    startedAt = nil

    let result: VoiceCaptureResult
    do {
      result = try capture.finish()
      try Self.renderVoiceMessage(from: result.rawURL, to: result.finalURL)
    } catch {
      capture.discardFiles()
      throw error
    }

    try? FileManager.default.removeItem(at: result.rawURL)

    let data = try Data(contentsOf: result.finalURL)
    if data.isEmpty {
      try? FileManager.default.removeItem(at: result.finalURL)
      throw ComposeVoiceRecorderError.emptyRecording
    }

    let duration = max(result.duration, elapsed)
    return ComposeVoiceRecording(
      fileURL: result.finalURL,
      data: data,
      duration: duration,
      waveform: Self.waveformData(from: result.samples),
      mimeType: "audio/mp4",
      fileExtension: "m4a"
    )
  }

  func cancel() {
    let capture = capture
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    stopMetering()
    engine = nil
    self.capture = nil
    startedAt = nil
    capture?.discardFiles()
  }

  private func startMetering() {
    meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
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
    guard let capture else { return }

    let snapshot = capture.snapshot()
    onUpdate?(snapshot.duration, snapshot.samples)
  }

  nonisolated fileprivate static func normalizedPower(_ power: Float) -> Float {
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

  private static func renderVoiceMessage(from rawURL: URL, to finalURL: URL) throws {
    let analysis = try analyze(rawURL: rawURL)
    guard analysis.frameCount > 0 else {
      throw ComposeVoiceRecorderError.emptyRecording
    }

    let source = try AVAudioFile(forReading: rawURL)
    let sourceFormat = source.processingFormat
    guard let monoFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sourceFormat.sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw ComposeVoiceRecorderError.processingFailed
    }

    let output = try AVAudioFile(
      forWriting: finalURL,
      settings: aacSettings(sampleRate: sourceFormat.sampleRate),
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let gain = normalizationGain(forPeak: analysis.peak)
    let frameCapacity = AVAudioFrameCount(min(Self.processingBufferFrameCount, max(1, source.length)))

    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCapacity),
          let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCapacity)
    else {
      throw ComposeVoiceRecorderError.processingFailed
    }

    while source.framePosition < source.length {
      let remaining = AVAudioFrameCount(source.length - source.framePosition)
      let framesToRead = min(frameCapacity, remaining)
      try source.read(into: inputBuffer, frameCount: framesToRead)
      guard inputBuffer.frameLength > 0 else { break }
      try fillMonoBuffer(
        outputBuffer,
        from: inputBuffer,
        channel: analysis.channel,
        gain: gain
      )
      try output.write(from: outputBuffer)
    }
  }

  private static func analyze(rawURL: URL) throws -> VoiceAnalysis {
    let file = try AVAudioFile(forReading: rawURL)
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    guard channelCount > 0 else {
      throw ComposeVoiceRecorderError.unsupportedInputFormat
    }

    let frameCapacity = AVAudioFrameCount(min(Self.processingBufferFrameCount, max(1, file.length)))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
      throw ComposeVoiceRecorderError.processingFailed
    }

    var energy = Array(repeating: Double(0), count: channelCount)
    var peaks = Array(repeating: Float(0), count: channelCount)

    while file.framePosition < file.length {
      let remaining = AVAudioFrameCount(file.length - file.framePosition)
      let framesToRead = min(frameCapacity, remaining)
      try file.read(into: buffer, frameCount: framesToRead)
      guard buffer.frameLength > 0 else { break }
      guard let channels = buffer.floatChannelData else {
        throw ComposeVoiceRecorderError.unsupportedInputFormat
      }

      let frameCount = Int(buffer.frameLength)
      for channel in 0 ..< channelCount {
        let source = channels[channel]
        for frame in 0 ..< frameCount {
          let sample = source[frame]
          energy[channel] += Double(sample * sample)
          peaks[channel] = max(peaks[channel], abs(sample))
        }
      }
    }

    let selectedChannel = energy.indices.max { energy[$0] < energy[$1] } ?? 0
    return VoiceAnalysis(
      channel: selectedChannel,
      peak: peaks[selectedChannel],
      frameCount: file.length
    )
  }

  private static func fillMonoBuffer(
    _ outputBuffer: AVAudioPCMBuffer,
    from inputBuffer: AVAudioPCMBuffer,
    channel: Int,
    gain: Float
  ) throws {
    guard let inputChannels = inputBuffer.floatChannelData,
          let outputChannels = outputBuffer.floatChannelData
    else {
      throw ComposeVoiceRecorderError.unsupportedInputFormat
    }

    let channelCount = Int(inputBuffer.format.channelCount)
    guard channelCount > 0 else {
      throw ComposeVoiceRecorderError.unsupportedInputFormat
    }

    let selectedChannel = min(max(channel, 0), channelCount - 1)
    let frameCount = Int(inputBuffer.frameLength)
    let input = inputChannels[selectedChannel]
    let output = outputChannels[0]

    outputBuffer.frameLength = inputBuffer.frameLength
    for frame in 0 ..< frameCount {
      output[frame] = limited(input[frame] * gain)
    }
  }

  private static func normalizationGain(forPeak peak: Float) -> Float {
    guard peak.isFinite, peak > minimumPeakForNormalization else { return 1 }
    return min(maxNormalizationGain, targetPeak / peak)
  }

  private static func limited(_ sample: Float) -> Float {
    min(max(sample, -limitPeak), limitPeak)
  }

  private static func aacSettings(sampleRate: Double) -> [String: Any] {
    [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 40_000,
      AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]
  }

  private static let bufferSize: AVAudioFrameCount = 1_024
  private static let processingBufferFrameCount: AVAudioFramePosition = 8_192
  private static let targetPeak: Float = 0.891_251
  private static let limitPeak: Float = 0.98
  private static let maxNormalizationGain: Float = 4
  private static let minimumPeakForNormalization: Float = 0.001
}

enum ComposeVoiceRecorderError: LocalizedError {
  case startFailed
  case notRecording
  case emptyRecording
  case unsupportedInputFormat
  case processingFailed

  var errorDescription: String? {
    switch self {
    case .startFailed:
      "Could not start voice recording."
    case .notRecording:
      "No active voice recording."
    case .emptyRecording:
      "Voice recording is empty."
    case .unsupportedInputFormat:
      "The active microphone format isn't supported."
    case .processingFailed:
      "Could not process voice recording."
    }
  }
}

private struct VoiceCaptureResult {
  let rawURL: URL
  let finalURL: URL
  let duration: TimeInterval
  let samples: [UInt8]
}

private struct VoiceAnalysis {
  let channel: Int
  let peak: Float
  let frameCount: AVAudioFramePosition
}

private final class VoiceCaptureState: @unchecked Sendable {
  private let lock = NSLock()
  private let rawURL: URL
  private let finalURL: URL
  private let sampleRate: Double

  private var file: AVAudioFile?
  private var frames: AVAudioFramePosition = 0
  private var samples: [UInt8] = []
  private var error: Error?

  init(rawURL: URL, finalURL: URL, file: AVAudioFile, sampleRate: Double) {
    self.rawURL = rawURL
    self.finalURL = finalURL
    self.file = file
    self.sampleRate = sampleRate
  }

  func write(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    defer { lock.unlock() }

    guard error == nil, let file else { return }

    do {
      try file.write(from: buffer)
      frames += AVAudioFramePosition(buffer.frameLength)
      samples.append(Self.meterSample(from: buffer))
    } catch {
      self.error = error
    }
  }

  func snapshot() -> (duration: TimeInterval, samples: [UInt8]) {
    lock.lock()
    defer { lock.unlock() }

    return (duration: duration, samples: samples)
  }

  func finish() throws -> VoiceCaptureResult {
    lock.lock()
    let result = VoiceCaptureResult(
      rawURL: rawURL,
      finalURL: finalURL,
      duration: duration,
      samples: samples
    )
    let error = error
    file = nil
    lock.unlock()

    if let error {
      throw error
    }

    return result
  }

  func discardFiles() {
    lock.lock()
    file = nil
    lock.unlock()

    try? FileManager.default.removeItem(at: rawURL)
    try? FileManager.default.removeItem(at: finalURL)
  }

  private var duration: TimeInterval {
    guard sampleRate > 0 else { return 0 }
    return TimeInterval(frames) / sampleRate
  }

  private static func meterSample(from buffer: AVAudioPCMBuffer) -> UInt8 {
    guard let channels = buffer.floatChannelData else { return 0 }

    let channelCount = Int(buffer.format.channelCount)
    let frameCount = Int(buffer.frameLength)
    guard channelCount > 0, frameCount > 0 else { return 0 }

    var bestPower = Float.leastNonzeroMagnitude
    for channel in 0 ..< channelCount {
      let source = channels[channel]
      var sum = Float(0)
      for frame in 0 ..< frameCount {
        let sample = source[frame]
        sum += sample * sample
      }
      bestPower = max(bestPower, sum / Float(frameCount))
    }

    let rms = sqrt(bestPower)
    let db = 20 * log10(max(rms, 0.000_001))
    let normalized = ComposeVoiceRecorder.normalizedPower(db)
    return UInt8(max(0, min(255, Int((normalized * 255).rounded()))))
  }
}
