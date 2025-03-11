import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit
import RealtimeAPI

public struct TransactionAddReaction: Transaction {
  // Properties
  var message: Message
  var emoji: String
  var userId: Int64
  var peerId: Peer

  // Config
  public var id = UUID().uuidString
  var config = TransactionConfig.default
  var date = Date()

  public init(message: Message, emoji: String, userId: Int64, peerId: Peer) {
    self.message = message
    self.emoji = emoji
    self.userId = userId
    self.peerId = peerId
  }

  // Methods
  func optimistic() {
    Log.shared.debug("Optimistic add reaction \(message.messageId) \(peerId) \(message.chatId)")
    do {
      try AppDatabase.shared.dbWriter.write { db in
        let existing = try Reaction
          .filter(
            Column("messageId") == message.messageId && Column("chatId") == message
              .chatId && Column("emoji") == emoji
          ).fetchOne(db)
        if existing != nil {
          Log.shared.info("Reaction with this emoji already exists")
          return
        } else {
          let reaction = Reaction(
            messageId: message.messageId,
            userId: userId,
            emoji: emoji,
            date: Date.now,
            chatId: message.chatId
          )
          try reaction.save(db)
        }
      }
    } catch {
      Log.shared.error("Failed to add reaction \(error)")
    }

    Task { @MainActor in
      await MessagesPublisher.shared.messageUpdated(message: message, peer: peerId, animated: true)
    }
  }

  func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .addReaction,
      input: .addReaction(AddReactionInput.with {
        $0.peerID = peerId.toInputPeer()
        $0.messageID = message.messageId
        $0.emoji = emoji
      })
    )

    guard case let .addReaction(response) = result else {
      throw AddReactionError.failed
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
      let existing = try Reaction
        .filter(
          Column("messageId") == message.messageId && Column("chatId") == message
            .chatId && Column("emoji") == emoji
        ).fetchOne(db)
      if existing != nil {
        Log.shared.info("Reaction with this emoji already exists")
        return
      } else {
        let reaction = Reaction(
          messageId: message.messageId,
          userId: userId,
          emoji: emoji,
          date: Date.now,
          chatId: message.chatId
        )
        try reaction.save(db)
      }
    }

    Task { @MainActor in
      await MessagesPublisher.shared.messageUpdated(message: message, peer: peerId, animated: true)
    }
  }

  func rollback() async {
    let _ = try? await AppDatabase.shared.dbWriter.write { db in
      let existing = try Reaction
        .filter(
          Column("messageId") == message.messageId && Column("chatId") == message
            .chatId && Column("emoji") == emoji
        ).fetchOne(db)
      if existing != nil {
        Log.shared.info("Reaction with this emoji already exists")
        return
      } else {
        let reaction = Reaction(
          messageId: message.messageId,
          userId: userId,
          emoji: emoji,
          date: Date.now,
          chatId: message.chatId
        )
        try reaction.save(db)
      }
    }
  }

  enum AddReactionError: Error {
    case failed
  }
}
