import Foundation
@testable import InlineKit
import Testing

@Suite("Scroll-to-bottom unread count")
struct ChatUnreadBadgeCountTests {
  @Test("shows the dialog count before anything is read")
  func showsDialogCount() {
    let count = ChatUnreadBadgeCount.resolve(
      unreadCount: 800,
      readInboxMaxId: 100,
      readFrontier: 0,
      coverage: coverage(holes: []),
      loadedMessages: (101 ... 150).map { message($0) }
    )
    #expect(count == 800)
  }

  @Test("falls as incoming rows are read, before the server confirms")
  func subtractsPendingReads() {
    let count = ChatUnreadBadgeCount.resolve(
      unreadCount: 800,
      readInboxMaxId: 100,
      readFrontier: 110,
      coverage: coverage(holes: []),
      loadedMessages: (95 ... 150).map { message($0) }
    )
    #expect(count == 790)
  }

  @Test("outgoing rows are not unread")
  func ignoresOutgoingRows() {
    let rows = [message(101), message(102, out: true), message(103, out: true), message(104)]
    let count = ChatUnreadBadgeCount.resolve(
      unreadCount: 3,
      readInboxMaxId: 100,
      readFrontier: 104,
      coverage: coverage(holes: []),
      loadedMessages: rows
    )
    #expect(count == 1)
  }

  @Test("the server's marker catching up does not count rows twice")
  func convergesWithServerUpdate() {
    let rows = (101 ... 150).map { message($0) }
    let before = ChatUnreadBadgeCount.resolve(
      unreadCount: 50, readInboxMaxId: 100, readFrontier: 120, coverage: coverage(holes: []), loadedMessages: rows
    )
    let after = ChatUnreadBadgeCount.resolve(
      unreadCount: 30, readInboxMaxId: 120, readFrontier: 120, coverage: coverage(holes: []), loadedMessages: rows
    )
    #expect(before == 30)
    #expect(after == 30)
  }

  @Test("a read that crosses unknown history is not subtracted")
  func stopsAtHoles() {
    let rows = (101 ... 150).map { message($0) }
    let blocked = ChatUnreadBadgeCount.resolve(
      unreadCount: 50, readInboxMaxId: 100, readFrontier: 140, coverage: coverage(holes: [101 ... 105]),
      loadedMessages: rows
    )
    let capped = ChatUnreadBadgeCount.resolve(
      unreadCount: 50, readInboxMaxId: 100, readFrontier: 140, coverage: coverage(holes: [121 ... 125]),
      loadedMessages: rows
    )
    #expect(blocked == 50)
    #expect(capped == 30)
  }

  @Test("never negative")
  func clampsAtZero() {
    let count = ChatUnreadBadgeCount.resolve(
      unreadCount: 3, readInboxMaxId: 0, readFrontier: 10, coverage: coverage(holes: []),
      loadedMessages: (1 ... 10).map { message($0) }
    )
    #expect(count == 0)
  }

  @Test("formats large counts compactly")
  func formats() {
    #expect(ChatUnreadBadgeCount.format(0) == "0")
    #expect(ChatUnreadBadgeCount.format(7) == "7")
    #expect(ChatUnreadBadgeCount.format(800) == "800")
    #expect(ChatUnreadBadgeCount.format(999) == "999")
    #expect(ChatUnreadBadgeCount.format(1_000) == "1K")
    #expect(ChatUnreadBadgeCount.format(1_299) == "1.2K")
    #expect(ChatUnreadBadgeCount.format(9_999) == "9.9K")
    #expect(ChatUnreadBadgeCount.format(12_345) == "12K")
  }

  private func message(_ id: Int64, out: Bool = false) -> FullMessage {
    FullMessage(
      senderInfo: nil,
      message: Message(
        messageId: id, fromId: out ? 1 : 2, date: Date(timeIntervalSince1970: Double(id)), text: "Unread",
        peerUserId: nil, peerThreadId: 1, chatId: 1, out: out
      ),
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }

  private func coverage(holes: [ClosedRange<Int64>]) -> MessageHistoryCoverageProjection {
    MessageHistoryCoverageProjection(
      messages: [],
      holes: holes.map { MessageHistoryHole(chatId: 1, lowerId: $0.lowerBound, upperId: $0.upperBound) },
      olderCandidateMessageID: nil,
      newerCandidateMessageID: nil
    )
  }
}
