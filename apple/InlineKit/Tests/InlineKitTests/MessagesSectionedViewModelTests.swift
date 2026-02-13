import Foundation
import Testing

@testable import InlineKit

@Suite("MessagesSectionedViewModel Ordering Tests")
struct MessagesSectionedViewModelOrderingTests {
  @Test("section sort uses date + globalId + messageId tie-breakers")
  func testSectionSortUsesStableTieBreakers() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeSectionTestFullMessage(messageId: 3, globalId: 30, date: date)
    let message1 = makeSectionTestFullMessage(messageId: 1, globalId: 10, date: date)
    let message2 = makeSectionTestFullMessage(messageId: 2, globalId: 20, date: date)

    let sorted = await MainActor.run {
      MessagesSectionedViewModel.sortMessagesForSection([message3, message1, message2])
    }

    #expect(sorted.map { $0.message.globalId } == [30, 20, 10])
  }

  @Test("section sort falls back to messageId when globalId is missing")
  func testSectionSortFallsBackToMessageId() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeSectionTestFullMessage(messageId: 3, globalId: nil, date: date)
    let message1 = makeSectionTestFullMessage(messageId: 1, globalId: nil, date: date)
    let message2 = makeSectionTestFullMessage(messageId: 2, globalId: nil, date: date)

    let sorted = await MainActor.run {
      MessagesSectionedViewModel.sortMessagesForSection([message1, message2, message3])
    }

    #expect(sorted.map { $0.message.messageId } == [3, 2, 1])
  }
}

private func makeSectionTestFullMessage(messageId: Int64, globalId: Int64?, date: Date) -> FullMessage {
  var message = Message(
    messageId: messageId,
    fromId: 1,
    date: date,
    text: "hi",
    peerUserId: nil,
    peerThreadId: 1,
    chatId: 1
  )
  message.globalId = globalId

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: []
  )
}
