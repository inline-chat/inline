import Auth
import Foundation
import InlineProtocol

/// Sends transient dictation audio without creating a stored file or chat message.
public enum DraftVoiceTranscription {
  public static let maximumBytes = 4 * 1024 * 1024
  public static let maximumDuration: TimeInterval = 600

  public static func transcribe(
    audio: Data,
    mimeType: String,
    duration: TimeInterval,
    accountToken: AuthAccountMutationToken
  ) async throws -> String {
    try validate(audio: audio, duration: duration)
    try Task.checkCancellation()
    try Auth.shared.handle.validateAccountMutation(accountToken)
    let result = try await Api.realtime.callRpcDirect(
      method: .transcribeVoiceDraft,
      input: .transcribeVoiceDraft(.with {
        $0.audio = audio
        $0.mimeType = mimeType
        $0.duration = UInt32(max(1, duration.rounded(.up)))
      }),
      timeout: .seconds(35),
      accountToken: accountToken
    )
    try Task.checkCancellation()
    try Auth.shared.handle.validateAccountMutation(accountToken)
    guard case let .transcribeVoiceDraft(transcript) = result else { throw Failure.invalidResponse }
    let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw Failure.emptyTranscript }
    return text
  }

  static func validate(audio: Data, duration: TimeInterval) throws {
    guard duration.isFinite, duration > 0, duration <= maximumDuration else { throw Failure.recordingTooLong }
    guard !audio.isEmpty, audio.count <= maximumBytes else { throw Failure.invalidAudio }
  }

  private enum Failure: LocalizedError {
    case recordingTooLong, invalidAudio, invalidResponse, emptyTranscript

    var errorDescription: String? {
      switch self {
      case .recordingTooLong: "Dictation must be 10 minutes or less."
      case .invalidAudio: "This recording is empty or too large. Please record a shorter dictation."
      case .invalidResponse: "Could not transcribe this recording. Please try again."
      case .emptyTranscript: "No speech was recognized. Try again or record another dictation."
      }
    }
  }
}
