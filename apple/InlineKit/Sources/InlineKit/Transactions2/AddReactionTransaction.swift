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
    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {}
}

// MARK: - Codable

extension AddReactionTransaction: Codable {
  enum CodingKeys: String, CodingKey {
    case emoji, messageId, chatId, peerId, userId
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(emoji, forKey: .emoji)
    try container.encode(messageId, forKey: .messageId)
    try container.encode(chatId, forKey: .chatId)
    try container.encode(peerId, forKey: .peerId)
    try container.encode(userId, forKey: .userId)
  }
  
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    emoji = try container.decode(String.self, forKey: .emoji)
    messageId = try container.decode(Int64.self, forKey: .messageId)
    chatId = try container.decode(Int64.self, forKey: .chatId)
    peerId = try container.decode(Peer.self, forKey: .peerId)
    userId = try container.decode(Int64.self, forKey: .userId)
    
    // Set method
    method = .addReaction
    
    // Reconstruct Protocol Buffer input
    input = .addReaction(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageID = messageId
      $0.emoji = emoji
    })
  }
}

// Helper

public extension Transaction2 {
  static func addReaction(emoji: String, message: InlineKit.Message) -> AddReactionTransaction {
    AddReactionTransaction(emoji: emoji, message: message)
  }
}
