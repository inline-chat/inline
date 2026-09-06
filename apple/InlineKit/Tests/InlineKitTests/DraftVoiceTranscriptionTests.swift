import Foundation
import InlineProtocol
import Testing
@testable import InlineKit

@Suite("Draft voice transcription")
struct DraftVoiceTranscriptionTests {
  @Test("rejects empty or oversized recordings before an RPC")
  func invalidAudio() {
    #expect(throws: (any Error).self) {
      try DraftVoiceTranscription.validate(audio: Data(), duration: 1)
    }
    #expect(throws: (any Error).self) {
      try DraftVoiceTranscription.validate(
        audio: Data(count: DraftVoiceTranscription.maximumBytes + 1), duration: 1
      )
    }
  }

  @Test("rejects unbounded or invalid recording durations", arguments: [0.0, -1.0, 601.0, .infinity, .nan])
  func invalidDuration(_ duration: Double) {
    #expect(throws: (any Error).self) {
      try DraftVoiceTranscription.validate(audio: Data([1]), duration: duration)
    }
  }

  @Test("accepts the exact recording limits")
  func boundary() throws {
    try DraftVoiceTranscription.validate(
      audio: Data(count: DraftVoiceTranscription.maximumBytes),
      duration: DraftVoiceTranscription.maximumDuration
    )
  }

  @Test("audio and returned text survive protocol serialization")
  func protocolRoundTrip() throws {
    let request = RpcCall.with {
      $0.method = .transcribeVoiceDraft
      $0.transcribeVoiceDraft = .with {
        $0.audio = Data([1, 2, 3])
        $0.mimeType = "audio/mp4"
        $0.duration = 5
      }
    }
    #expect(try RpcCall(serializedBytes: request.serializedData()) == request)
    let result = RpcResult.with {
      $0.transcribeVoiceDraft = .with { $0.text = "سلام دنیا" }
    }
    #expect(try RpcResult(serializedBytes: result.serializedData()) == result)
  }
}
