import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateChatTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .createChat
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/CreateChat")
  private var title: String
  private var emoji: String?
  private var isPublic: Bool
  private var spaceId: Int64
  private var participants: [Int64]

  public init(title: String, emoji: String?, isPublic: Bool, spaceId: Int64, participants: [Int64]) {
    input = .createChat(.with {
      $0.title = title
      $0.spaceID = spaceId
      if let emoji { $0.emoji = emoji }
      $0.isPublic = isPublic
      $0.participants = participants.map { userId in
        InputChatParticipant.with { $0.userID = Int64(userId) }
      }
    })
    self.title = title
    self.emoji = emoji
    self.isPublic = isPublic
    self.spaceId = spaceId
    self.participants = participants
  }

  // Methods
  public func optimistic() async {
    // No optimistic updates needed
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .createChat(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      // Save chat and dialog to database
      try await AppDatabase.shared.dbWriter.write { db in
        do {
          let chat = Chat(from: response.chat)
          try chat.save(db)
        } catch {
          log.error("Failed to save chat", error: error)
        }

        do {
          let dialog = Dialog(from: response.dialog)
          try dialog.save(db)
        } catch {
          log.error("Failed to save dialog", error: error)
        }
      }
    } catch {
      log.error("Failed to save chat in transaction", error: error)
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to create chat", error: error)
  }
}

// MARK: - Codable

extension CreateChatTransaction: Codable {
  enum CodingKeys: String, CodingKey {
    case title, emoji, isPublic, spaceId, participants
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(title, forKey: .title)
    try container.encodeIfPresent(emoji, forKey: .emoji)
    try container.encode(isPublic, forKey: .isPublic)
    try container.encode(spaceId, forKey: .spaceId)
    try container.encode(participants, forKey: .participants)
  }
  
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    
    title = try container.decode(String.self, forKey: .title)
    emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
    isPublic = try container.decode(Bool.self, forKey: .isPublic)
    spaceId = try container.decode(Int64.self, forKey: .spaceId)
    participants = try container.decode([Int64].self, forKey: .participants)
    
    // Set method
    method = .createChat
    
    // Reconstruct Protocol Buffer input
    input = .createChat(.with {
      $0.title = title
      $0.spaceID = spaceId
      if let emoji { $0.emoji = emoji }
      $0.isPublic = isPublic
      $0.participants = participants.map { userId in
        InputChatParticipant.with { $0.userID = Int64(userId) }
      }
    })
  }
}

// Helper

public extension Transaction2 {
  static func createChat(
    title: String,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64,
    participants: [Int64]
  ) -> CreateChatTransaction {
    CreateChatTransaction(title: title, emoji: emoji, isPublic: isPublic, spaceId: spaceId, participants: participants)
  }
}
