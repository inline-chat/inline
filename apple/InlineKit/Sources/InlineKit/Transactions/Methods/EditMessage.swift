import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

public struct TransactionEditMessage: Transaction {
  // Properties
  public var messageId: Int64
  public var text: String
  public var chatId: Int64
  public var peerId: Peer
  public var entities: MessageEntities?

  // Config
  public var id = UUID().uuidString
  public var config = TransactionConfig.default
  public var date = Date()

  public init(messageId: Int64, text: String, chatId: Int64, peerId: Peer, entities: MessageEntities? = nil) {
    self.messageId = messageId
    self.text = text
    self.chatId = chatId
    self.peerId = peerId
    self.entities = entities
  }

  // Methods
  public func optimistic() {
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
            message?.entities = entities
          }
          print("edited message \(entities)")
          let newMessage = try message?.saveMessage(db)
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

  public func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .editMessage,
      input: .editMessage(EditMessageInput.with {
        $0.peerID = peerId.toInputPeer()
        $0.messageID = messageId
        $0.text = text
        if let entities {
          $0.entities = entities
        }
      })
    )

    guard case let .editMessage(response) = result else {
      throw EditMessageError.failed
    }

    return response.updates
  }

  public func shouldRetryOnFail(error: Error) -> Bool {
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

  public func didSucceed(result: [InlineProtocol.Update]) async {
    await Realtime.shared.updates.applyBatch(updates: result)
  }

  public func didFail(error: Error?) async {}
  public func rollback() async {}

  enum EditMessageError: Error {
    case failed
  }
}
