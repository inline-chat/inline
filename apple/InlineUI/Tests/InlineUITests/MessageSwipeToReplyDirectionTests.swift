import Foundation
import Testing

@testable import InlineUI

@Suite("Message swipe-to-reply direction")
struct MessageSwipeToReplyDirectionTests {
  @Test("accepts only motion in the configured direction")
  func acceptsConfiguredDirection() {
    #expect(MessageSwipeToReplyDirection.leftToRight.accepts(12))
    #expect(!MessageSwipeToReplyDirection.leftToRight.accepts(-12))
    #expect(!MessageSwipeToReplyDirection.leftToRight.accepts(0))

    #expect(MessageSwipeToReplyDirection.rightToLeft.accepts(-12))
    #expect(!MessageSwipeToReplyDirection.rightToLeft.accepts(12))
    #expect(!MessageSwipeToReplyDirection.rightToLeft.accepts(0))
  }

  @Test("uses concise labels and reveals the edge behind the swipe")
  func labelsAndRevealedEdges() {
    #expect(MessageSwipeToReplyDirection.leftToRight.title == "Right")
    #expect(MessageSwipeToReplyDirection.rightToLeft.title == "Left")
    #expect(MessageSwipeToReplyDirection.leftToRight.revealsLeftEdge)
    #expect(!MessageSwipeToReplyDirection.rightToLeft.revealsLeftEdge)
  }

  @Test("bounds motion while preserving its configured sign")
  func boundsMotion() {
    #expect(MessageSwipeToReplyDirection.leftToRight.boundedOffset(80, maximum: 40) == 40)
    #expect(MessageSwipeToReplyDirection.rightToLeft.boundedOffset(-80, maximum: 40) == -40)
    #expect(MessageSwipeToReplyDirection.leftToRight.boundedOffset(-80, maximum: 40) == 0)
    #expect(MessageSwipeToReplyDirection.rightToLeft.boundedOffset(80, maximum: 40) == 0)
    #expect(MessageSwipeToReplyDirection.leftToRight.boundedOffset(80, maximum: 0) == 0)
  }

  @Test("storage preserves the legacy right-to-left default")
  func storageDefault() throws {
    let suiteName = "MessageSwipeToReplyDirectionTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(MessageSwipeToReplyDirection.stored(in: defaults) == .rightToLeft)

    defaults.set(
      MessageSwipeToReplyDirection.leftToRight.rawValue,
      forKey: MessageSwipeToReplyDirection.storageKey
    )
    #expect(MessageSwipeToReplyDirection.stored(in: defaults) == .leftToRight)
  }
}
