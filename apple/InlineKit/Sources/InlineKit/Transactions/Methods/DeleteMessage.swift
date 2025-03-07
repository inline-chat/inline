import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

public struct TransactionDeleteMessage: Transaction {
  // Properties
  var messageIds: [Int64]
  var peerId: Peer
  var chatId: Int64

  // Config
  public var id = UUID().uuidString
  var config = TransactionConfig.default
  var date = Date()

  public init(messageIds: [Int64], peerId: Peer, chatId: Int64) {
    self.messageIds = messageIds
    self.peerId = peerId
    self.chatId = chatId
  }

  // Methods
  func optimistic() {
    Log.shared.debug("Optimistic delete message \(messageIds) \(peerId) \(chatId)")
    do {
      try AppDatabase.shared.dbWriter.write { db in
        let chat = try Chat.fetchOne(db, id: chatId)

        let prevChatLastMsgId = chat?.lastMsgId

        for messageId in messageIds {
          try Message.filter(Column("messageId") == messageId && Column("chatId") == chatId).deleteAll(db)
        }

        // Update last message
        for messageId in messageIds {
          guard prevChatLastMsgId == messageId else { continue }

          let previousMessage = try Message
            .filter(Column("chatId") == chat?.id)
            .order(Column("date").desc)
            .limit(1, offset: 1)
            .fetchOne(db)

          var updatedChat = chat
          updatedChat?.lastMsgId = previousMessage?.messageId
          try updatedChat?.save(db)
        }
      }
    } catch {
      Log.shared.error("Failed to delete message \(error)")
    }

    DispatchQueue.main.async {
      MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerId)
    }
  }

  func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .deleteMessages,
      input: .deleteMessages(DeleteMessagesInput.with {
        $0.peerID = peerId.toInputPeer()
        $0.messageIds = messageIds
      })
    )

    guard case let .deleteMessages(response) = result else {
      throw DeleteMessageError.failed
    }

    return response.updates
  }

  func shouldRetryOnFail(error: Error) -> Bool {
    if let error = error as? RealtimeAPIError {
      switch error {
        case let .rpcError(_, _, code):
          switch code {
            case 400, 401:
              return false

            default:
              return true
          }
        default:
          return true
      }
    }

    return true
  }

  func didSucceed(result: [InlineProtocol.Update]) async {
    await Realtime.shared.updates.applyBatch(updates: result)
  }

  func didFail(error: Error?) async {
    Log.shared.error("Failed to delete message", error: error)

    try? await AppDatabase.shared.dbWriter.write { db in
      var chat = try Chat.fetchOne(db, id: chatId)
    }

    DispatchQueue.main.async {
      MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerId)
    }
  }

  func rollback() async {
    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      var chat = try Chat.fetchOne(db, id: chatId)

      let prevChatLastMsgId = chat?.lastMsgId

      for messageId in messageIds {
        try Message.filter(Column("messageId") == messageId && Column("chatId") == chatId).deleteAll(db)
      }

      // Update last message
      for messageId in messageIds {
        guard prevChatLastMsgId == messageId else { continue }

        let previousMessage = try Message
          .filter(Column("chatId") == chat?.id)
          .order(Column("date").desc)
          .limit(1, offset: 1)
          .fetchOne(db)

        var updatedChat = chat
        updatedChat?.lastMsgId = previousMessage?.messageId
        try updatedChat?.save(db)

        break
      }
    }
  }

  enum DeleteMessageError: Error {
    case failed
  }
}
