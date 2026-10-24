@testable import InlineIOS
import Foundation
import InlineKit

enum MessageTestFixtures {
  private static let date = Date(timeIntervalSince1970: 1_787_816_400)
  private static let chatID: Int64 = 9_001
  private static let sender = User(
    id: 7_001,
    email: "ava@example.com",
    firstName: "Ava",
    lastName: "Lin"
  )

  /// A compact incoming text message in a thread. Tests copy it and adjust what they need.
  static func compactText() -> FullMessage {
    var message = Message(
      messageId: 10_001,
      fromId: sender.id,
      date: date,
      text: "A compact incoming message.",
      peerUserId: nil,
      peerThreadId: chatID,
      chatId: chatID,
      out: false
    )
    message.globalId = 10_001
    return FullMessage(
      senderInfo: UserInfo(user: sender),
      message: message,
      reactions: [],
      repliedToMessage: nil,
      attachments: []
    )
  }
}
