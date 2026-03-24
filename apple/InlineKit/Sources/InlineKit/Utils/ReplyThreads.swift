import Foundation
import InlineProtocol
import Logger

public enum ReplyThreadResolutionError: Error {
  case invalidResponse
}

public enum ReplyThreads {
  private static let log = Log.scoped("ReplyThreads")

  public static func resolveChatId(for message: Message) async throws -> Int64 {
    if let existingChatId = message.replyThreadChatId {
      return existingChatId
    }

    let result = try await Api.realtime.send(.createSubthread(
      parentChatId: message.chatId,
      parentMessageId: message.messageId
    ))

    guard case let .createSubthread(response) = result, response.hasChat else {
      throw ReplyThreadResolutionError.invalidResponse
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let chat = Chat(from: response.chat)
        try chat.save(db)

        if response.hasDialog {
          _ = try response.dialog.saveFull(db)
        }

        if response.hasAnchorMessage {
          _ = try Message.save(db, protocolMessage: response.anchorMessage, publishChanges: false)
        }
      }
    } catch {
      log.error("Failed to persist reply thread resolution result", error: error)
    }

    return response.chat.id
  }
}
