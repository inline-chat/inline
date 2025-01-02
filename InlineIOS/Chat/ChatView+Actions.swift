
import Combine
import InlineKit
import InlineUI
import SwiftUI

extension ChatView {
  func sendDebugMessages() {
    Task {
      guard let chatId = fullChatViewModel.chat?.id else { return }

      // Send 80 messages with different lengths
      for i in 1...200 {
        let messageLength = Int.random(in: 10...200)
        let messageText = String(repeating: "Test message \(i) ", count: messageLength / 10)

        let peerUserId: Int64? = if case .user(let id) = peerId { id } else { nil }
        let peerThreadId: Int64? = if case .thread(let id) = peerId { id } else { nil }

        let randomId = Int64.random(in: Int64.min...Int64.max)
        let message = Message(
          messageId: -randomId,
          randomId: randomId,
          fromId: Auth.shared.getCurrentUserId()!,
          date: Date(),
          text: messageText,
          peerUserId: peerUserId,
          peerThreadId: peerThreadId,
          chatId: chatId,
          out: true,
          status: .sending,
          repliedToMessageId: nil
        )

        do {
          // Save to database
          try await database.dbWriter.write { db in
            try message.save(db)
          }

          // Send to server
          try await data.sendMessage(
            chatId: chatId,
            peerUserId: peerUserId,
            peerThreadId: peerThreadId,
            text: messageText,
            peerId: peerId,
            randomId: randomId,
            repliedToMessageId: nil
          )

          // Add small delay between messages
          try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        } catch {
          Log.shared.error("Failed to send debug message", error: error)
        }
      }
    }
  }
}
