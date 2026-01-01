import Foundation
import Testing

@testable import InlineKit

@Suite("MessagesProgressiveViewModel Ordering Tests")
struct MessagesProgressiveViewModelOrderingTests {
  @Test("stable sort uses date + globalId tie-break")
  func testStableSortTieBreak() async throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let message3 = makeFullMessage(messageId: 3, globalId: 30, date: date)
    let message1 = makeFullMessage(messageId: 1, globalId: 10, date: date)
    let message2 = makeFullMessage(messageId: 2, globalId: 20, date: date)

    let batch = [message3, message1, message2]

    let sorted = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages(batch, reversed: false)
    }
    #expect(sorted.map { $0.message.globalId } == [10, 20, 30])

    let reversed = await MainActor.run {
      MessagesProgressiveViewModel.stableSortedMessages(batch, reversed: true)
    }
    #expect(reversed.map { $0.message.globalId } == [30, 20, 10])
  }
}

private func makeFullMessage(messageId: Int64, globalId: Int64?, date: Date) -> FullMessage {
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
