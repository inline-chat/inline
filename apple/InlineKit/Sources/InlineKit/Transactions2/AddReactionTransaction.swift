import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct AddReactionTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .addReaction
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/AddReaction")
  private var emoji: String
  private var messageId: Int64
  private var chatId: Int64
  private var peerId: Peer
  private var userId: Int64

  public init(emoji: String, message: Message) {
    self.init(emoji: emoji, messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
  }

  public init(emoji: String, messageId: Int64, peerId: Peer, chatId: Int64) {
    input = .addReaction(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageID = messageId
      $0.emoji = emoji
    })
    self.messageId = messageId
    self.emoji = emoji
    self.peerId = peerId
    self.chatId = chatId
    // This is safe because we're always be logged in when using this transaction
    userId = Auth.shared.getCurrentUserId() ?? 0
  }

  // Methods
  public func optimistic() async {
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let existing = try Reaction
          .filter(
            Column("messageId") == messageId &&
              Column("chatId") == chatId && Column("emoji") == emoji
          ).fetchOne(db)

        if existing != nil {
          Log.shared.info("Reaction with this emoji already exists")
        } else {
          let reaction = Reaction(
            messageId: messageId,
            userId: userId,
            emoji: emoji,
            date: Date.now,
            chatId: chatId
          )
          try reaction.save(db)
        }
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedWithId(
          messageId: messageId,
          chatId: chatId,
          peer: peerId,
          animated: true
        )
      }
    } catch {
      log.error("Failed to add reaction \(error)")
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .addReaction(response) = result else {
      throw TransactionExecutionError.invalid
    }

    // Apply
    await Realtime.shared.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {}
}

// Helper

public extension Transaction2 {
  static func addReaction(emoji: String, message: InlineKit.Message) -> AddReactionTransaction {
    AddReactionTransaction(emoji: emoji, message: message)
  }
}
