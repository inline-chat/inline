import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

public struct TransactionEditMessage: Transaction {
  // Properties
  var messageId: Int64
  var text: String
  var chatId: Int64
  var peerId: Peer

  // Config
  public var id = UUID().uuidString
  var config = TransactionConfig.default
  var date = Date()

  public init(messageId: Int64, text: String, chatId: Int64, peerId: Peer) {
    self.messageId = messageId
    self.text = text
    self.chatId = chatId
    self.peerId = peerId
  }

  // Methods
  func optimistic() {
    Log.shared.debug("Optimistic edit message \(messageId) \(peerId) \(chatId)")
    Task(priority: .userInitiated) {
      do {
        try AppDatabase.shared.dbWriter.write { db in
          var message = try Message
            .filter(Column("messageId") == messageId && Column("chatId") == chatId).fetchOne(db)
          if let current = message?.text, current == text {
            message?.editDate = nil
          } else {
            message?.editDate = Date()
            message?.text = text
          }
          try message?.saveMessage(db)
        }
      } catch {
        Log.shared.error("Failed to edit message \(error)")
      }

      // concern: is this edited message?

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedWithId(
          messageId: messageId,
          chatId: chatId,
          peer: peerId,
          animated: false
        )
      }
    }
  }

  func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .editMessage,
      input: .editMessage(EditMessageInput.with {
        $0.peerID = peerId.toInputPeer()
        $0.messageID = messageId
        $0.text = text
      })
    )

    guard case let .editMessage(response) = result else {
      throw EditMessageError.failed
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
    Task(priority: .userInitiated) {
      try? await AppDatabase.shared.dbWriter.write { db in
        var message = try Message
          .filter(Column("messageId") == messageId && Column("chatId") == chatId).fetchOne(db)
        if let current = message?.text, current == text {
          message?.editDate = nil
        } else {
          message?.editDate = Date()
          message?.text = text
        }
        try message?.saveMessage(db)
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedWithId(
          messageId: messageId,
          chatId: chatId,
          peer: peerId,
          animated: false
        )
      }
    }
  }

  func rollback() async {
    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      var message = try Message
        .filter(Column("messageId") == messageId && Column("chatId") == chatId).fetchOne(db)
      if let current = message?.text, current == text {
        message?.editDate = nil
      } else {
        message?.editDate = Date()
        message?.text = text
      }
      try message?.saveMessage(db)
    }
  }

  enum EditMessageError: Error {
    case failed
  }
}
