import Foundation
@testable import InlineKit
import InlineProtocol
import Testing

/// Each test uses its own memo: the shared one is written by every message save in the test process.
@Suite("Link detection memo")
struct LinkDetectionMemoTests {
  @Test("remembered answers are the detector's answers")
  func memoMatchesDetector() {
    let memo = LinkDetectionMemo()
    let linked = "see https://inline.chat/docs"
    let plain = "no link in this one"

    #expect(Message.detectHasLink(text: linked, entities: nil, memo: memo))
    #expect(!Message.detectHasLink(text: plain, entities: nil, memo: memo))
    #expect(memo.cached(linked) == true)
    #expect(memo.cached(plain) == false)
    // Asking again answers from the memo, with the same result as the shared memo's path.
    #expect(Message.detectHasLink(text: linked, entities: nil, memo: memo))
    #expect(!Message.detectHasLink(text: plain, entities: nil, memo: memo))
    #expect(Message.detectHasLink(text: linked, entities: nil))
    #expect(!Message.detectHasLink(text: plain, entities: nil))
  }

  @Test("prewarm detects only texts the save would detect")
  func prewarmFollowsTheSave() {
    let memo = LinkDetectionMemo()
    let detected = "plain text"
    let serverMarked = "marked https://inline.chat"
    let withURLEntity = "entity https://inline.chat"
    let messages: [InlineProtocol.Message] = [
      .with { $0.message = detected },
      .with {
        $0.message = serverMarked
        $0.hasLink_p = true
      },
      .with {
        $0.message = withURLEntity
        $0.entities = .with { $0.entities = [.with { $0.type = .url }] }
      },
      .with { $0.message = "" },
      .with { _ in },
    ]

    Message.prepareLinkDetection(messages, memo: memo)

    #expect(memo.cached(detected) == false)
    #expect(memo.cached(serverMarked) == nil)
    #expect(memo.cached(withURLEntity) == nil)
  }

  @Test("a prewarmed batch survives a nearly full memo")
  func prewarmReservesRoom() {
    let memo = LinkDetectionMemo(capacity: 8)
    for index in 0 ..< 7 {
      memo.store("earlier \(index)", false)
    }
    let batch = (0 ..< 4).map { index in InlineProtocol.Message.with { $0.message = "batch \(index)" } }

    Message.prepareLinkDetection(batch, memo: memo)

    for index in 0 ..< 4 {
      #expect(memo.cached("batch \(index)") == false)
    }
  }

  @Test("the memo stays bounded in entries and text length")
  func memoIsBounded() {
    let memo = LinkDetectionMemo(capacity: 4, maxTextLength: 16)
    memo.store("first", false)
    for index in 0 ..< 4 {
      memo.store("filler \(index)", false)
    }
    // Full means cleared, so the first entry is gone instead of the memo growing.
    #expect(memo.cached("first") == nil)

    let long = String(repeating: "x", count: 17)
    memo.store(long, true)
    #expect(memo.cached(long) == nil)
  }
}
