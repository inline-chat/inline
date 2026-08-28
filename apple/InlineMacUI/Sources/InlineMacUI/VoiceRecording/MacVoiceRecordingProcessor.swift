@preconcurrency import AVFoundation
import Foundation

struct MacVoiceCaptureOutput {
  let rawURL: URL
  let finalURL: URL
  let duration: TimeInterval
  let samples: [UInt8]
}

enum MacVoiceRecordingProcessor {
  static func process(
    _ capture: MacVoiceCaptureOutput,
    cancellation: MacVoiceProcessingCancellation
  ) throws -> MacVoiceRecording {
    do {
      try cancellation.checkCancellation()
      try renderVoiceMessage(
        from: capture.rawURL,
        to: capture.finalURL,
        cancellation: cancellation
      )
      try cancellation.checkCancellation()
      try? FileManager.default.removeItem(at: capture.rawURL)

      try cancellation.checkCancellation()
      let data = try Data(contentsOf: capture.finalURL)
      try cancellation.checkCancellation()
      guard !data.isEmpty else {
        try? FileManager.default.removeItem(at: capture.finalURL)
        throw MacVoiceRecorderError.emptyRecording
      }

      return MacVoiceRecording(
        fileURL: capture.finalURL,
        data: data,
        duration: capture.duration,
        waveform: waveformData(from: capture.samples),
        mimeType: "audio/mp4",
        fileExtension: "m4a"
      )
    } catch {
      try? FileManager.default.removeItem(at: capture.rawURL)
      try? FileManager.default.removeItem(at: capture.finalURL)
      throw error
    }
  }

  private static func waveformData(from samples: [UInt8], targetCount: Int = 96) -> Data {
    guard !samples.isEmpty else { return Data(repeating: 28, count: targetCount) }
    guard samples.count > targetCount else { return Data(samples) }

    let bucketSize = Double(samples.count) / Double(targetCount)
    return Data((0 ..< targetCount).map { index -> UInt8 in
      let start = Int(Double(index) * bucketSize)
      let end = min(samples.count, Int(Double(index + 1) * bucketSize))
      return start < end ? samples[start ..< end].max() ?? 0 : 0
    })
  }

  private static func renderVoiceMessage(
    from rawURL: URL,
    to finalURL: URL,
    cancellation: MacVoiceProcessingCancellation
  ) throws {
    try cancellation.checkCancellation()
    let analysis = try analyze(rawURL: rawURL, cancellation: cancellation)
    guard analysis.frameCount > 0 else { throw MacVoiceRecorderError.emptyRecording }

    try cancellation.checkCancellation()
    let source = try AVAudioFile(forReading: rawURL)
    let sourceFormat = source.processingFormat
    guard let monoFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sourceFormat.sampleRate,
      channels: 1,
      interleaved: false
    ) else {
      throw MacVoiceRecorderError.processingFailed
    }

    let output = try AVAudioFile(
      forWriting: finalURL,
      settings: aacSettings(sampleRate: sourceFormat.sampleRate),
      commonFormat: .pcmFormatFloat32,
      interleaved: false
    )
    let gain = normalizationGain(forPeak: analysis.peak)
    let capacity = AVAudioFrameCount(min(processingBufferFrameCount, max(1, source.length)))
    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: capacity),
          let outputBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity)
    else {
      throw MacVoiceRecorderError.processingFailed
    }

    while source.framePosition < source.length {
      try cancellation.checkCancellation()
      let remaining = AVAudioFrameCount(source.length - source.framePosition)
      try source.read(into: inputBuffer, frameCount: min(capacity, remaining))
      guard inputBuffer.frameLength > 0 else { break }
      try fillMonoBuffer(outputBuffer, from: inputBuffer, channel: analysis.channel, gain: gain)
      try cancellation.checkCancellation()
      try output.write(from: outputBuffer)
    }
    try cancellation.checkCancellation()
  }

  private static func analyze(
    rawURL: URL,
    cancellation: MacVoiceProcessingCancellation
  ) throws -> VoiceAnalysis {
    let file = try AVAudioFile(forReading: rawURL)
    let format = file.processingFormat
    let channelCount = Int(format.channelCount)
    guard channelCount > 0 else { throw MacVoiceRecorderError.unsupportedInputFormat }

    let capacity = AVAudioFrameCount(min(processingBufferFrameCount, max(1, file.length)))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      throw MacVoiceRecorderError.processingFailed
    }

    var energy = Array(repeating: Double(0), count: channelCount)
    var peaks = Array(repeating: Float(0), count: channelCount)
    while file.framePosition < file.length {
      try cancellation.checkCancellation()
      let remaining = AVAudioFrameCount(file.length - file.framePosition)
      try file.read(into: buffer, frameCount: min(capacity, remaining))
      guard buffer.frameLength > 0 else { break }
      guard let channels = buffer.floatChannelData else {
        throw MacVoiceRecorderError.unsupportedInputFormat
      }
      for channel in 0 ..< channelCount {
        let source = channels[channel]
        for frame in 0 ..< Int(buffer.frameLength) {
          let sample = source[frame]
          energy[channel] += Double(sample * sample)
          peaks[channel] = max(peaks[channel], abs(sample))
        }
      }
    }
    try cancellation.checkCancellation()

    let channel = energy.indices.max { energy[$0] < energy[$1] } ?? 0
    return VoiceAnalysis(channel: channel, peak: peaks[channel], frameCount: file.length)
  }

  private static func fillMonoBuffer(
    _ outputBuffer: AVAudioPCMBuffer,
    from inputBuffer: AVAudioPCMBuffer,
    channel: Int,
    gain: Float
  ) throws {
    guard let inputs = inputBuffer.floatChannelData,
          let outputs = outputBuffer.floatChannelData
    else {
      throw MacVoiceRecorderError.unsupportedInputFormat
    }
    let channelCount = Int(inputBuffer.format.channelCount)
    guard channelCount > 0 else { throw MacVoiceRecorderError.unsupportedInputFormat }

    let input = inputs[min(max(channel, 0), channelCount - 1)]
    let output = outputs[0]
    outputBuffer.frameLength = inputBuffer.frameLength
    for frame in 0 ..< Int(inputBuffer.frameLength) {
      output[frame] = min(max(input[frame] * gain, -limitPeak), limitPeak)
    }
  }

  private static func normalizationGain(forPeak peak: Float) -> Float {
    guard peak.isFinite, peak > minimumPeakForNormalization else { return 1 }
    return min(maxNormalizationGain, targetPeak / peak)
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

  private struct VoiceAnalysis {
    let channel: Int
    let peak: Float
    let frameCount: AVAudioFramePosition
  }

  private static let processingBufferFrameCount: AVAudioFramePosition = 8_192
  private static let targetPeak: Float = 0.891_251
  private static let limitPeak: Float = 0.98
  private static let maxNormalizationGain: Float = 4
  private static let minimumPeakForNormalization: Float = 0.001
}
