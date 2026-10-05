import AVFoundation
import Foundation
import Testing
#if os(iOS)
@testable import InlineIOS
#else
@testable import IOSVoiceRecordingValidation
#endif

@Suite("iOS voice recording file validation", .serialized)
struct ComposeVoiceRecordingValidationTests {
  @Test("Short AAC captures are rejected using encoded frames", arguments: [0.07, 0.49])
  func rejectsShortEncodedCapture(seconds: Double) throws {
    let url = try silentAACFile(seconds: seconds)
    let audio = try AVAudioFile(forReading: url)
    #expect(audio.length > 0)
    #expect(Double(audio.length) / audio.processingFormat.sampleRate < 0.5)
    #expect(throws: ComposeVoiceRecorderError.tooShort) {
      // A long meter history cannot turn a nearly empty file into a valid message.
      try ComposeVoiceRecordingValidation.load(fileURL: url, waveform: Data(repeating: 0, count: 250))
    }
  }

  @Test("Full silent AAC recordings remain valid", arguments: [0.5, 2.0])
  func acceptsSilentRecording(seconds: Double) throws {
    let url = try silentAACFile(seconds: seconds)
    let audio = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 1_024))
    try audio.read(into: buffer)
    let samples = try #require(buffer.floatChannelData?[0])
    #expect(buffer.frameLength > 0)
    #expect((0 ..< Int(buffer.frameLength)).allSatisfy { abs(samples[$0]) <= Float.ulpOfOne })

    let waveform = Data(repeating: 0, count: 96)
    let recording = try ComposeVoiceRecordingValidation.load(fileURL: url, waveform: waveform)
    #expect(abs(recording.duration - seconds) < 2 / 44_100)
    #expect(recording.duration >= 0.5)
    #expect(try recording.data == Data(contentsOf: url))
    #expect(recording.waveform == waveform)
    #expect(recording.mimeType == "audio/mp4")
    #expect(recording.fileExtension == "m4a")
  }

  @Test("An unreadable container cannot become a reviewable draft")
  func rejectsUnreadableAudio() throws {
    let url = fixtureURL()
    try Data("invalid AAC container".utf8).write(to: url)
    #expect(throws: ComposeVoiceRecorderError.invalidRecording) {
      try ComposeVoiceRecordingValidation.load(fileURL: url, waveform: Data())
    }
  }

  private func silentAACFile(seconds: Double) throws -> URL {
    let url = fixtureURL()
    // Use the actual Apple AAC encoder and release the writer to finalize the M4A.
    try autoreleasepool {
      let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 40_000,
      ])
      let frameCount = AVAudioFrameCount((seconds * 44_100).rounded())
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount))
      buffer.frameLength = frameCount
      let samples = try #require(buffer.floatChannelData?[0])
      samples.update(repeating: 0, count: Int(frameCount))
      try file.write(from: buffer)
    }
    return url
  }

  private func fixtureURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("inline-voice-validation-\(UUID()).m4a")
  }
}
