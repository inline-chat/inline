import Foundation
@testable import InlineMacUI
import Testing

struct MessageListViewportTests {
  @Test func positionRoundTripsWithoutLosingInt64Precision() throws {
    let anchor = try #require(MessageListViewportAnchor(messageID: Int64.max - 1, offsetY: 27.625))
    let position = MessageListInitialPosition.anchor(anchor)
    let data = try JSONEncoder().encode(position)
    #expect(try JSONDecoder().decode(MessageListInitialPosition.self, from: data) == position)
    #expect(position.messageID == Int64.max - 1)
    #expect(!position.followsLatest)
  }

  @Test func optimisticAndMalformedAnchorsAreNotRestorable() {
    #expect(MessageListViewportAnchor(messageID: 0, offsetY: 0) == nil)
    #expect(MessageListViewportAnchor(messageID: -40, offsetY: 0) == nil)
    #expect(MessageListViewportAnchor(messageID: 40, offsetY: .nan) == nil)
    #expect(MessageListViewportAnchor(messageID: 40, offsetY: .infinity) == nil)
    let data = Data(#"{"messageID":-1,"offsetY":0}"#.utf8)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(MessageListViewportAnchor.self, from: data)
    }
  }

  @Test func viewportRangeIncludesToolbarAndComposeInsets() {
    #expect(clamp(-100) == -72)
    #expect(clamp(-30) == -30)
    #expect(clamp(530) == 530)
    #expect(clamp(700) == 580)
  }

  @Test func shortChatHasAStableReachableOrigin() {
    #expect(MessageListViewportGeometry.clampedOffset(
      0, contentHeight: 80, viewportHeight: 500, topInset: 72, bottomInset: 80
    ) == -72)
  }

  @Test func prependPreservesTheSamePointInsideTheMessage() throws {
    let anchor = try #require(MessageListViewportAnchor(messageID: 500, offsetY: 21.5))
    let oldRowTop = 200.0
    let newRowTop = 380.0
    let inset = 72.0
    let oldViewport = oldRowTop + anchor.offsetY - inset
    let newViewport = clamp(newRowTop + anchor.offsetY - inset)
    #expect(newViewport - oldViewport == newRowTop - oldRowTop)
    #expect(newViewport + inset - newRowTop == anchor.offsetY)
  }

  @Test func missingCoordinatePrefersCertifiedNewerThenOlder() {
    #expect(MessageListViewportGeometry.nearestMessage(to: 100, in: [20, 105, 140]) == 105)
    #expect(MessageListViewportGeometry.nearestMessage(to: 100, in: [20, 90]) == 90)
    #expect(MessageListViewportGeometry.nearestMessage(to: 100, in: [-4, 0]) == nil)
    #expect(MessageListViewportGeometry.nearestMessage(to: 100, in: [110, 100, 90]) == 100)
  }

  @Test func latestIsASeparateSemanticPosition() throws {
    let position = MessageListInitialPosition.latest
    #expect(position.messageID == nil)
    #expect(position.followsLatest)
    let data = try JSONEncoder().encode(position)
    #expect(try JSONDecoder().decode(MessageListInitialPosition.self, from: data) == .latest)
  }

  private func clamp(_ offset: Double) -> Double {
    MessageListViewportGeometry.clampedOffset(
      offset, contentHeight: 1_000, viewportHeight: 500, topInset: 72, bottomInset: 80
    )
  }
}
