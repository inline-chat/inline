import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Message voice merge")
struct MessageVoiceMergeTests {
  @Test func theServersCopyOfOurOwnUploadKeepsItsLocalFile() {
    let sent = Client_MessageVoiceContent.with {
      $0.voiceID = -63; $0.duration = 4; $0.localRelativePath = "pending-voice.m4a"; $0.mimeType = "audio/mp4"
    }
    let confirmed = Client_MessageVoiceContent.with {
      $0.voiceID = 9001; $0.duration = 4; $0.cdnURL = "https://cdn.example/voice"
    }
    let merged = Message.mergedVoiceContent(incoming: confirmed, existing: sent)
    #expect(merged.voiceID == 9001)
    #expect(merged.localRelativePath == "pending-voice.m4a")
    #expect(merged.cdnURL == "https://cdn.example/voice")
    #expect(merged.mimeType == "audio/mp4")
  }

  @Test func aDifferentServerVoiceDropsTheOldLocalFile() {
    let stored = Client_MessageVoiceContent.with { $0.voiceID = 12; $0.localRelativePath = "old.m4a" }
    let replaced = Client_MessageVoiceContent.with { $0.voiceID = 13 }
    #expect(Message.mergedVoiceContent(incoming: replaced, existing: stored).localRelativePath.isEmpty)
  }
}
