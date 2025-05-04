import Foundation
import GRDB
import InlineKit
import InlineProtocol
import Logger
import RealtimeAPI

public struct TransactionCreateChat: Transaction {
  // Properties
  public var title: String
  public var emoji: String?
  public var isPublic: Bool
  public var spaceId: Int64
  public var participants: [Int64]

  // Config
  public var id = UUID().uuidString
  var config = TransactionConfig.default
  var date = Date()

  public init(title: String, emoji: String?, isPublic: Bool, spaceId: Int64, participants: [Int64]) {
    self.title = title
    self.emoji = emoji
    self.isPublic = isPublic
    self.spaceId = spaceId
    self.participants = participants
  }

  // Methods
  func optimistic() {
    // No optimistic updates needed for chat creation
  }

  func execute() async throws -> [InlineProtocol.Update] {
    let result = try await Realtime.shared.invoke(
      .createChat,
      input: .createChat(
        CreateChatInput.with {
          $0.title = title
          $0.spaceID = spaceId
          if let emoji { $0.emoji = emoji }
          $0.isPublic = isPublic
          $0.participants = participants
            .map {
              userId in InputChatParticipant.with { $0.userID = Int64(userId) }
            }
        }
      )
    )

    guard case let .createChat(response) = result else {
      throw CreateChatError.failed
    }

    // Save chat and dialog to database
    try? await AppDatabase.shared.dbWriter.write { db in
      let chat = Chat(from: response.chat)
      try chat.save(db)

      let dialog = Dialog(from: response.dialog)
      try dialog.save(db)
    }

    return []
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
          return false
      }
    }
    
    return false
  }

  func didSucceed(result: [InlineProtocol.Update]) async {
    // No updates to apply
  }

  func didFail(error: Error?) async {
    Log.shared.error("Failed to create chat", error: error)
  }

  func rollback() async {
    // No rollback needed for chat creation
  }

  enum CreateChatError: Error {
    case failed
  }
}
