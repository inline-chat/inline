import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

public struct TransactionDeleteReaction: Transaction {
  // Properties
  public var message: Message
  public var emoji: String
  public var peerId: Peer
  public var chatId: Int64

  // Config
  public var id = UUID().uuidString
  public var config = TransactionConfig.default
  public var date = Date()

  public init(message: Message, emoji: String, peerId: Peer, chatId: Int64) {
    self.message = message
    self.emoji = emoji
    self.peerId = peerId
    self.chatId = chatId
  }

  // Methods
  public func optimistic() {
    Log.shared.debug("Optimistic delete reaction \(message.messageId) \(peerId) \(message.chatId)")
    Task(priority: .userInitiated) {
      do {
        try AppDatabase.shared.dbWriter.write { db in
          _ = try Reaction
            .filter(
              Column("messageId") == message.messageId && Column("chatId") == message
                .chatId && Column("emoji") == emoji && Column("userId") == Auth.shared.getCurrentUserId() ?? 0
            ).deleteAll(db)
        }
      } catch {
        Log.shared.error("Failed to delete reaction \(error)")
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedSync(message: message, peer: peerId, animated: true)
      }
    }
  }

  public func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .deleteReaction,
      input: .deleteReaction(DeleteReactionInput.with {
        $0.peerID = peerId.toInputPeer()
        $0.messageID = message.messageId
        $0.emoji = emoji
      })
    )

    guard case let .deleteReaction(response) = result else {
      throw DeleteReactionError.failed
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

  public func didFail(error: Error?) async {
    Log.shared.error("Failed to delete message", error: error)
    Task(priority: .userInitiated) {
      do {
        try AppDatabase.shared.dbWriter.write { db in
          _ = try Reaction
            .filter(
              Column("messageId") == message.messageId && Column("chatId") == message
                .chatId && Column("emoji") == emoji && Column("userId") == Auth.shared.getCurrentUserId() ?? 0
            ).deleteAll(db)
        }
      } catch {
        Log.shared.error("Failed to delete reaction \(error)")
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedSync(message: message, peer: peerId, animated: true)
      }
    }
  }

  public func rollback() async {
    let _ = try? await AppDatabase.shared.dbWriter.write { db in

      _ = try Reaction
        .filter(
          Column("messageId") == message.messageId && Column("chatId") == message
            .chatId && Column("emoji") == emoji && Column("userId") == Auth.shared.getCurrentUserId() ?? 0
        ).deleteAll(db)
    }
  }

  enum DeleteReactionError: Error {
    case failed
  }
}
