import Foundation
import GRDB
import InlineKit
import InlineProtocol
import Logger

public struct TransactionCreateChat: Transaction {
  // Properties
  public var title: String
  public var emoji: String?
  public var isPublic: Bool
  public var spaceId: Int64
  public var participants: [Int64]

  // Config
  public var id = UUID().uuidString
  public var config = TransactionConfig.default
  public var date = Date()

  public init(title: String, emoji: String?, isPublic: Bool, spaceId: Int64, participants: [Int64]) {
    self.title = title
    self.emoji = emoji
    self.isPublic = isPublic
    self.spaceId = spaceId
    self.participants = participants
  }

  // Methods
  public func optimistic() {
    // No optimistic updates needed for chat creation
  }

  public func execute() async throws -> CreateChatResult {
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

    print("transaction result   = \(result)")

    guard case let .createChat(response) = result else {
      throw CreateChatError.failed
    }
    print("transaction response = \(response)")

    return response
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
          return false
      }
    }

    return false
  }

  public func didSucceed(result: CreateChatResult) async {
    do {
      // Save chat and dialog to database
      try await AppDatabase.shared.dbWriter.write { db in
        do {
          let chat = Chat(from: result.chat)
          try chat.save(db)
        } catch {
          Log.shared.error("Failed to save chat", error: error)
        }

        do {
          let dialog = Dialog(from: result.dialog)
          try dialog.save(db)
        } catch {
          Log.shared.error("Failed to save dialog", error: error)
        }
      }
    } catch {
      Log.shared.error("Failed to save chat in transaction", error: error)
    }
  }

  public func didFail(error: Error?) async {
    Log.shared.error("Failed to create chat", error: error)
  }

  public func rollback() async {
    // No rollback needed for chat creation
  }

  enum CreateChatError: Error {
    case failed
  }
}
