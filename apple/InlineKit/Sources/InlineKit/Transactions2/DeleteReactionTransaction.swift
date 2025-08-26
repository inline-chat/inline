import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteReactionTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .deleteReaction
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var emoji: String
    public var messageId: Int64
    public var peerId: Peer
    public var chatId: Int64
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/DeleteReaction")

  public init(emoji: String, message: Message) {
    self.init(emoji: emoji, messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
  }

  public init(emoji: String, messageId: Int64, peerId: Peer, chatId: Int64) {
    context = Context(emoji: emoji, messageId: messageId, peerId: peerId, chatId: chatId)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .deleteReaction(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageID = context.messageId
      $0.emoji = context.emoji
    })
  }

  // Computed

  public var emoji: String { context.emoji }
  public var messageId: Int64 { context.messageId }
  public var peerId: Peer { context.peerId }
  public var chatId: Int64 { context.chatId }

  // Methods
  public func optimistic() async {
    log.debug("Optimistic delete reaction \(messageId) \(peerId) \(chatId)")
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        _ = try Reaction
          .filter(Column("messageId") == messageId)
          .filter(Column("chatId") == chatId)
          .filter(Column("emoji") == emoji)
          .filter(Column("userId") == Auth.shared.currentUserId)
          .deleteAll(db)
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
      log.error("Failed to delete reaction \(error)")
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .deleteReaction(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }
}

// Helper

public extension Transaction2 where Self == DeleteReactionTransaction {
  static func deleteReaction(emoji: String, message: InlineKit.Message) -> DeleteReactionTransaction {
    DeleteReactionTransaction(emoji: emoji, message: message)
  }
}
