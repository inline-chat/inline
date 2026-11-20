import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

@Suite("Voice transcription privacy")
struct PrivacyVoiceTranscriptionTests {
  @Test("on by default, and saves omit it until it is known")
  @MainActor
  func defaultOmitted() {
    let manager = PrivacySettingsManager()
    #expect(manager.transcribeVoiceMessages)
    #expect(!manager.toProtocol().hasTranscribeVoiceMessages)

    let fromOldServer = PrivacySettingsManager(from: InlineProtocol.PrivacySettings())
    #expect(fromOldServer.transcribeVoiceMessages)
    #expect(!fromOldServer.toProtocol().hasTranscribeVoiceMessages)
  }

  @Test("a user's choice and a server value are both sent back")
  @MainActor
  func explicitValues() {
    let manager = PrivacySettingsManager()
    manager.transcribeVoiceMessages = false
    #expect(manager.toProtocol().hasTranscribeVoiceMessages)
    #expect(!manager.toProtocol().transcribeVoiceMessages)

    let fromServer = PrivacySettingsManager(from: .with { $0.transcribeVoiceMessages = false })
    #expect(!fromServer.transcribeVoiceMessages)
    #expect(fromServer.toProtocol().hasTranscribeVoiceMessages)
  }

  @Test("the choice survives the local cache")
  @MainActor
  func codableRoundTrip() throws {
    let manager = PrivacySettingsManager(transcribeVoiceMessages: false)
    let restored = try JSONDecoder().decode(PrivacySettingsManager.self, from: JSONEncoder().encode(manager))
    #expect(restored.transcribeVoiceMessagesValue == false)

    let unknown = try JSONDecoder().decode(
      PrivacySettingsManager.self,
      from: JSONEncoder().encode(PrivacySettingsManager())
    )
    #expect(unknown.transcribeVoiceMessagesValue == nil)
  }
}
