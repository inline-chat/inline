import Foundation
import InlineKit
import Testing

@testable import InlineUI

@MainActor
@Suite("ForwardMessagesSheetModel")
struct ForwardMessagesSheetModelTests {
  @Test("selection uses message peer metadata without a database lookup")
  func selectionUsesMessagePeerMetadata() {
    let messages = [
      makeFullMessage(messageId: 11, chatId: 42, peerThreadId: 99),
      makeFullMessage(messageId: 12, chatId: 42, peerThreadId: 99),
    ]

    let selection = ForwardMessagesSheetModel.makeSelection(messages: messages)

    #expect(selection?.fromPeerId == .thread(id: 99))
    #expect(selection?.sourceChatId == 42)
    #expect(selection?.messageIds == [11, 12])
    #expect(selection?.previewMessageId == 11)
  }

  @Test("selection rejects messages from different source chats")
  func selectionRejectsMixedSourceChats() {
    let messages = [
      makeFullMessage(messageId: 11, chatId: 42, peerThreadId: 99),
      makeFullMessage(messageId: 12, chatId: 43, peerThreadId: 99),
    ]

    #expect(ForwardMessagesSheetModel.makeSelection(messages: messages) == nil)
  }
}

private func makeFullMessage(
  messageId: Int64,
  chatId: Int64,
  peerUserId: Int64? = nil,
  peerThreadId: Int64? = nil
) -> FullMessage {
  let message = Message(
    messageId: messageId,
    fromId: 1,
    date: Date(timeIntervalSince1970: 0),
    text: "hello",
    peerUserId: peerUserId,
    peerThreadId: peerThreadId,
    chatId: chatId
  )

  return FullMessage(
    senderInfo: nil,
    message: message,
    reactions: [],
    repliedToMessage: nil,
    attachments: []
  )
}
