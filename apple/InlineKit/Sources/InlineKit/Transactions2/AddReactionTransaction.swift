import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct AddReactionTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .addReaction
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var emoji: String
    public var messageId: Int64
    public var peerId: Peer
    public var chatId: Int64
  }

  // Private
  private var log = Log.scoped("Transactions/AddReaction")

  public init(emoji: String, message: Message) {
    self.init(emoji: emoji, messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
  }

  public init(emoji: String, messageId: Int64, peerId: Peer, chatId: Int64) {
    context = Context(emoji: emoji, messageId: messageId, peerId: peerId, chatId: chatId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .addReaction(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageID = context.messageId
      $0.emoji = context.emoji
    })
  }

  // Computed

  var emoji: String { context.emoji }
  var messageId: Int64 { context.messageId }
  var peerId: Peer { context.peerId }
  var chatId: Int64 { context.chatId }

  public var executionKey: TransactionExecutionKey? {
    .chatMutation(chatID: context.chatId)
  }

  // Methods

  public func optimistic() async {
    // Signed out or switching accounts between the tap and this write.
    guard let userId = Auth.getCurrentUserId() else {
      log.warning("Skipped optimistic reaction without a current user")
      return
    }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let reaction = Reaction(
          messageId: messageId,
          userId: userId,
          emoji: emoji,
          date: Date.now,
          chatId: chatId
        )
        _ = try Reaction.save(db, reaction: reaction)
      }

      publishMessageUpdate()
    } catch {
      log.error("Failed to add reaction \(error)")
    }
  }

  /// Takes the optimistic reaction back off the message. If the server did
  /// apply it before the failure, the next update or sync adds it again.
  public func failed(error: TransactionError2) async {
    log.error("Failed to add reaction", error: error)
    guard let userId = Auth.getCurrentUserId() else { return }
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        _ = try Reaction
          .filter(Column("messageId") == messageId)
          .filter(Column("chatId") == chatId)
          .filter(Column("emoji") == emoji)
          .filter(Column("userId") == userId)
          .deleteAll(db)
      }
      publishMessageUpdate()
    } catch {
      log.error("Failed to roll back reaction", error: error)
    }
  }

  private func publishMessageUpdate() {
    Task(priority: .userInitiated) { @MainActor [messageId, chatId, peerId] in
      MessagesPublisher.shared.messageUpdatedWithId(
        messageId: messageId,
        chatId: chatId,
        peer: peerId,
        animated: true
      )
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .addReaction(response) = result else {
      throw TransactionExecutionError.invalid
    }

    // Apply
    await Api.realtime.applyUpdates(response.updates)
  }
}

// MARK: - Codable

extension AddReactionTransaction: Codable {
  enum CodingKeys: String, CodingKey {
    case context
  }
}

// Helper

public extension Transaction2 where Self == AddReactionTransaction {
  static func addReaction(emoji: String, message: InlineKit.Message) -> AddReactionTransaction {
    AddReactionTransaction(emoji: emoji, message: message)
  }
}
