import Foundation
import Testing

@testable import InlineKit

@Suite("ReplyThreadMessageProjection")
struct ReplyThreadMessageProjectionTests {
  private func makeFullMessage(messageId: Int64, chatId: Int64) -> FullMessage {
    let message = Message(
      messageId: messageId,
      fromId: 1,
      date: Date(timeIntervalSince1970: TimeInterval(messageId)),
      text: "message-\(messageId)",
      peerUserId: nil,
      peerThreadId: chatId,
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

  @Test("projection prepends parent message once")
  func projectionPrependsParentOnce() {
    let parent = makeFullMessage(messageId: 99, chatId: 7)
    let replies = [
      makeFullMessage(messageId: 3, chatId: 41),
      makeFullMessage(messageId: 2, chatId: 41),
    ]

    let projected = ReplyThreadMessageProjection.project(parentMessage: parent, replies: replies)

    #expect(projected.map(\.message.messageId) == [99, 3, 2])
  }

  @Test("projection does not duplicate parent when it is already present")
  func projectionDedupesParentMessage() {
    let parent = makeFullMessage(messageId: 99, chatId: 7)
    let replies = [
      parent,
      makeFullMessage(messageId: 3, chatId: 41),
    ]

    let projected = ReplyThreadMessageProjection.project(parentMessage: parent, replies: replies)

    #expect(projected.map(\.message.messageId) == [99, 3])
  }

  @Test("updated reply rows resolve by stable id when a parent message is projected ahead of replies")
  func updatedReplyRowsResolveByStableIdWithProjectedParent() {
    let parent = makeFullMessage(messageId: 99, chatId: 7)
    let updatedReply = makeFullMessage(messageId: 3, chatId: 41)

    let rows = ReplyThreadMessageProjection.rowIndexesForUpdatedMessages(
      [updatedReply],
      rowIndexByStableId: [
        parent.id: 1,
        updatedReply.id: 2,
      ]
    )

    #expect(rows == IndexSet(integer: 2))
  }
}
