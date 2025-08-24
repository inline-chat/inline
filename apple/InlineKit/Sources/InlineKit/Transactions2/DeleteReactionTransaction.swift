import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct DeleteReactionTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .deleteReaction
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/DeleteReaction")
  private var emoji: String
  private var messageId: Int64
  private var chatId: Int64
  private var peerId: Peer

  public init(emoji: String, message: Message) {
    self.init(emoji: emoji, messageId: message.messageId, peerId: message.peerId, chatId: message.chatId)
  }

  public init(emoji: String, messageId: Int64, peerId: Peer, chatId: Int64) {
    input = .deleteReaction(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageID = messageId
      $0.emoji = emoji
    })
    self.messageId = messageId
    self.emoji = emoji
    self.peerId = peerId
    self.chatId = chatId
  }

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

  public func failed(error: TransactionError2) async {
    log.error("Failed to delete reaction", error: error)
  }
}

// MARK: - Codable

extension DeleteReactionTransaction: Codable {
  enum CodingKeys: String, CodingKey {
    case emoji, messageId, chatId, peerId
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(emoji, forKey: .emoji)
    try container.encode(messageId, forKey: .messageId)
    try container.encode(chatId, forKey: .chatId)
    try container.encode(peerId, forKey: .peerId)
  }
  
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    emoji = try container.decode(String.self, forKey: .emoji)
    messageId = try container.decode(Int64.self, forKey: .messageId)
    chatId = try container.decode(Int64.self, forKey: .chatId)
    peerId = try container.decode(Peer.self, forKey: .peerId)
    
    // Set method
    method = .deleteReaction
    
    // Reconstruct Protocol Buffer input
    input = .deleteReaction(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageID = messageId
      $0.emoji = emoji
    })
  }
}

// Helper

public extension Transaction2 {
  static func deleteReaction(emoji: String, message: InlineKit.Message) -> DeleteReactionTransaction {
    DeleteReactionTransaction(emoji: emoji, message: message)
  }
}
