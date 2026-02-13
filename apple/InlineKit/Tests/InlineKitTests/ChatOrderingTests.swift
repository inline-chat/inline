import Foundation
import Testing

@testable import InlineKit

@Suite("Chat last message ordering")
struct ChatOrderingTests {
  @Test("advances when there is no current last message date")
  func testAdvanceWhenNoCurrentDate() {
    let shouldAdvance = Chat.shouldAdvanceLastMessage(
      currentLastMsgId: nil,
      currentLastMsgDate: nil,
      newLastMsgId: 10,
      newDate: Date(timeIntervalSince1970: 100)
    )
    #expect(shouldAdvance)
  }

  @Test("advances when incoming date is newer")
  func testAdvanceWhenIncomingDateNewer() {
    let shouldAdvance = Chat.shouldAdvanceLastMessage(
      currentLastMsgId: 10,
      currentLastMsgDate: Date(timeIntervalSince1970: 100),
      newLastMsgId: 9,
      newDate: Date(timeIntervalSince1970: 101)
    )
    #expect(shouldAdvance)
  }

  @Test("does not advance when incoming date is older")
  func testDoNotAdvanceWhenIncomingDateOlder() {
    let shouldAdvance = Chat.shouldAdvanceLastMessage(
      currentLastMsgId: 10,
      currentLastMsgDate: Date(timeIntervalSince1970: 100),
      newLastMsgId: 99,
      newDate: Date(timeIntervalSince1970: 99)
    )
    #expect(shouldAdvance == false)
  }

  @Test("advances on same date only when incoming message id is newer")
  func testAdvanceOnSameDateWithNewerMessageId() {
    let shouldAdvance = Chat.shouldAdvanceLastMessage(
      currentLastMsgId: 10,
      currentLastMsgDate: Date(timeIntervalSince1970: 100),
      newLastMsgId: 11,
      newDate: Date(timeIntervalSince1970: 100)
    )
    #expect(shouldAdvance)
  }

  @Test("does not advance on same date when incoming message id is older")
  func testDoNotAdvanceOnSameDateWithOlderMessageId() {
    let shouldAdvance = Chat.shouldAdvanceLastMessage(
      currentLastMsgId: 10,
      currentLastMsgDate: Date(timeIntervalSince1970: 100),
      newLastMsgId: 9,
      newDate: Date(timeIntervalSince1970: 100)
    )
    #expect(shouldAdvance == false)
  }
}
