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

/// Reads the finalized audio file off the main actor. Capture wall time and microphone
/// energy cannot establish that an encoder actually produced a usable recording.
enum ComposeVoiceRecordingValidation {
  nonisolated static let minimumDuration: TimeInterval = 0.5
  nonisolated static let maxVoiceBytes = 20 * 1_024 * 1_024

  nonisolated static func load(fileURL: URL, waveform: Data) throws -> ComposeVoiceRecording {
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    guard byteCount > 0 else { throw ComposeVoiceRecorderError.emptyRecording }
    guard byteCount <= maxVoiceBytes else { throw ComposeVoiceRecorderError.fileTooLarge }

    let duration: TimeInterval
    do {
      let file = try AVAudioFile(forReading: fileURL)
      let sampleRate = file.processingFormat.sampleRate
      guard sampleRate.isFinite, sampleRate > 0, file.length > 0 else {
        throw ComposeVoiceRecorderError.invalidRecording
      }
      duration = Double(file.length) / sampleRate
      #if DEBUG
      print("Voice capture encodedSeconds=\(duration) frames=\(file.length) sampleRate=\(sampleRate) bytes=\(byteCount)")
      #endif
      guard duration.isFinite, duration >= minimumDuration else {
        throw ComposeVoiceRecorderError.tooShort
      }

      // Open the real decoder as well as the container. Zero-valued PCM is valid silence.
      guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024) else {
        throw ComposeVoiceRecorderError.invalidRecording
      }
      try file.read(into: buffer)
      guard buffer.frameLength > 0 else { throw ComposeVoiceRecorderError.invalidRecording }
    } catch let error as ComposeVoiceRecorderError {
      throw error
    } catch {
      throw ComposeVoiceRecorderError.invalidRecording
    }

    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { throw ComposeVoiceRecorderError.emptyRecording }
    guard data.count <= maxVoiceBytes else { throw ComposeVoiceRecorderError.fileTooLarge }
    return ComposeVoiceRecording(
      fileURL: fileURL,
      data: data,
      duration: duration,
      waveform: waveform,
      mimeType: "audio/mp4",
      fileExtension: "m4a"
    )
  }
}

enum ComposeVoiceRecorderError: LocalizedError, Equatable {
  case preparationFailed
  case startFailed
  case notRecording
  case emptyRecording
  case fileTooLarge
  case tooShort
  case invalidRecording
  case captureStopped
  case encodingFailed

  var errorDescription: String? {
    switch self {
      case .preparationFailed, .startFailed:
        "Could not start voice recording. Please try again."
      case .notRecording:
        "No active voice recording. Please try again."
      case .emptyRecording, .invalidRecording:
        "Could not capture voice audio. Please try again."
      case .fileTooLarge:
        "Voice recording is too large to send."
      case .tooShort:
        "Voice message is too short. Please try again."
      case .captureStopped, .encodingFailed:
        "Recording stopped unexpectedly. Review the recording or try again."
    }
  }
}
