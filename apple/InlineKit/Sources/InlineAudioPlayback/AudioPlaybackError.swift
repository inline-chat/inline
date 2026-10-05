import Foundation

/// Public playback errors used by both shared core controls and Inline adapters.
public enum AudioPlaybackError: LocalizedError, Sendable {
  case missingVoice
  case missingLocalFile
  case unsupportedAudioFile
  case playbackUnavailable
  case preparationFailed
  case audioInUse(String)

  public var errorDescription: String? {
    switch self {
    case .missingVoice:
      "The selected message doesn't contain a playable voice payload."
    case .missingLocalFile:
      "The selected audio file isn't downloaded yet."
    case .unsupportedAudioFile:
      "The selected file isn't a supported audio format."
    case .playbackUnavailable:
      "Couldn't play this voice message. Try again."
    case .preparationFailed:
      "Couldn't play this voice message. Try again."
    case let .audioInUse(message):
      message
    }
  }
}
