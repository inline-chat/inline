import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import MultipartFormDataKit

public struct TransactionAddReaction: Transaction {
  // Properties
  public var message: Message
  public var emoji: String
  public var userId: Int64
  public var peerId: Peer

  // Config
  public var id = UUID().uuidString
  public var config = TransactionConfig.default
  public var date = Date()

  public init(message: Message, emoji: String, userId: Int64, peerId: Peer) {
    self.message = message
    self.emoji = emoji
    self.userId = userId
    self.peerId = peerId
  }

  // Methods
  public func optimistic() {
    Log.shared.debug("Optimistic add reaction \(message.messageId) \(peerId) \(message.chatId)")
    Task(priority: .userInitiated) {
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

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedSync(message: message, peer: peerId, animated: true)
      }
    }
  }

  public func execute() async throws -> [InlineProtocol.Update] {
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

  public func shouldRetryOnFail(error: Error) -> Bool {
    // disable retry
    false
  }

  public func didSucceed(result: [InlineProtocol.Update]) async {
    await Realtime.shared.applyUpdates(result)
  }

  public func didFail(error: Error?) async {
    Log.shared.error("Failed to delete message", error: error)
    Task(priority: .userInitiated) {
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

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedSync(message: message, peer: peerId, animated: true)
      }
    }
  }

  public func rollback() async {
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
