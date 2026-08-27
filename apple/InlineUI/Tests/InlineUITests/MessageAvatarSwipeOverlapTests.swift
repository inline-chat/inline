import CoreGraphics
import Testing

@testable import InlineUI

@Suite("Message avatar swipe overlap")
struct MessageAvatarSwipeOverlapTests {
  @Test("selects the overlapping avatar regardless of message ownership")
  func selectsOverlappingAvatar() {
    let index = MessageAvatarSwipeOverlap.firstOverlappingIndex(
      messageFrame: CGRect(x: 0, y: 40, width: 300, height: 50),
      avatarFrames: [
        CGRect(x: 8, y: 4, width: 28, height: 28),
        CGRect(x: 8, y: 52, width: 28, height: 28),
      ]
    )

    #expect(index == 1)
  }

  @Test("uses front-to-back candidate order when avatars overlap the same message")
  func preservesCandidateOrder() {
    let index = MessageAvatarSwipeOverlap.firstOverlappingIndex(
      messageFrame: CGRect(x: 0, y: 40, width: 300, height: 50),
      avatarFrames: [
        CGRect(x: 8, y: 45, width: 28, height: 28),
        CGRect(x: 8, y: 52, width: 28, height: 28),
      ]
    )

    #expect(index == 0)
  }

  @Test("does not match edge-only contact")
  func rejectsEdgeOnlyContact() {
    let index = MessageAvatarSwipeOverlap.firstOverlappingIndex(
      messageFrame: CGRect(x: 0, y: 40, width: 300, height: 50),
      avatarFrames: [CGRect(x: 8, y: 90, width: 28, height: 28)]
    )

    #expect(index == nil)
  }

  @Test("ignores invalid message and avatar frames")
  func ignoresInvalidFrames() {
    #expect(MessageAvatarSwipeOverlap.firstOverlappingIndex(
      messageFrame: CGRect(x: 0, y: 40, width: 0, height: 50),
      avatarFrames: [CGRect(x: 8, y: 52, width: 28, height: 28)]
    ) == nil)

    #expect(MessageAvatarSwipeOverlap.firstOverlappingIndex(
      messageFrame: CGRect(x: 0, y: 40, width: 300, height: 50),
      avatarFrames: [
        CGRect(x: CGFloat.nan, y: 52, width: 28, height: 28),
        CGRect(x: 8, y: 52, width: 28, height: 28),
      ]
    ) == 1)
  }
}
