import Foundation

/// Public playback errors used by both shared core controls and Inline adapters.
public enum AudioPlaybackError: LocalizedError, Sendable {
  case missingVoice
  case missingLocalFile
  case playbackUnavailable

  public var errorDescription: String? {
    switch self {
    case .missingVoice:
      "The selected message doesn't contain a playable voice payload."
    case .missingLocalFile:
      "The selected audio file isn't downloaded yet."
    case .playbackUnavailable:
      "There isn't an audio item ready to resume."
    }
  }
}
