import Testing

@testable import InlineKit

@Suite("Pinned Message Bar")
struct PinnedMessageBarTests {
  @Test("starts on the newest pin in chat order")
  func startsOnNewest() {
    let bar = PinnedMessageBar(messageIds: [30, 10, 20])

    #expect(bar.messageIds == [10, 20, 30])
    #expect(bar.displayedMessageId == 30)
    #expect(bar.displayedIndex == 2)
    #expect(bar.title == "Pinned Message")
  }

  @Test("tapping walks to older pins and wraps to the newest")
  func advanceWraps() {
    var bar = PinnedMessageBar(messageIds: [10, 20, 30])

    #expect(bar.advance() == 30)
    #expect(bar.displayedMessageId == 20)
    #expect(bar.title == "Pinned Message #2")
    #expect(bar.advance() == 20)
    #expect(bar.displayedMessageId == 10)
    #expect(bar.title == "Pinned Message #1")
    #expect(bar.advance() == 10)
    #expect(bar.displayedMessageId == 30)
  }

  @Test("titles follow Telegram for one and two pins")
  func titles() {
    var single = PinnedMessageBar(messageIds: [5])
    #expect(single.title == "Pinned Message")
    single.advance()
    #expect(single.displayedMessageId == 5)

    var pair = PinnedMessageBar(messageIds: [5, 9])
    #expect(pair.title == "Pinned Message")
    pair.advance()
    #expect(pair.title == "Previous Message")
  }

  @Test("a new pin is shown right away, even when it is older")
  func newPinIsShown() {
    var bar = PinnedMessageBar(messageIds: [10, 30])
    bar.update(messageIds: [10, 20, 30])

    #expect(bar.displayedMessageId == 20)
  }

  @Test("unpinning the shown pin falls back to the nearest older one")
  func unpinFallsBack() {
    var bar = PinnedMessageBar(messageIds: [10, 20, 30])
    bar.advance()
    bar.update(messageIds: [10, 30])
    #expect(bar.displayedMessageId == 10)

    bar.update(messageIds: [30])
    #expect(bar.displayedMessageId == 30)

    bar.update(messageIds: [])
    #expect(bar.displayedMessageId == nil)
    #expect(bar.isEmpty)
  }

  @Test("unrelated changes keep the shown pin")
  func keepsShownPin() {
    var bar = PinnedMessageBar(messageIds: [10, 20, 30])
    bar.advance()
    bar.update(messageIds: [20, 30])

    #expect(bar.displayedMessageId == 20)
  }

  @Test("show ignores ids that are not pinned")
  func showIgnoresUnknown() {
    var bar = PinnedMessageBar(messageIds: [10, 20])
    bar.show(10)
    #expect(bar.displayedMessageId == 10)
    bar.show(99)
    #expect(bar.displayedMessageId == 10)
  }

  @Test("stripe window keeps the shown pin visible")
  func stripeWindow() {
    #expect(PinnedMessageBar(messageIds: [1]).visibleStripeRange.isEmpty)
    #expect(PinnedMessageBar(messageIds: [1, 2, 3]).visibleStripeRange == 0 ..< 3)

    var bar = PinnedMessageBar(messageIds: [1, 2, 3, 4, 5, 6])
    #expect(bar.visibleStripeRange == 2 ..< 6)
    bar.show(4)
    #expect(bar.visibleStripeRange == 1 ..< 5)
    bar.show(1)
    #expect(bar.visibleStripeRange == 0 ..< 4)
  }
}
