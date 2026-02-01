import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct UpdateChatInfoTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/UpdateChatInfo")

  public var method: InlineProtocol.Method = .updateChatInfo
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    let chatID: Int64
    let title: String?
    let emoji: String?
  }

  public init(chatID: Int64, title: String?, emoji: String?) {
    if chatID == 0 {
      log.error("chat ID is zero")
    }

    context = Context(chatID: chatID, title: title, emoji: emoji)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .updateChatInfo(.with {
      $0.chatID = context.chatID
      if let title = context.title {
        $0.title = title
      }
      if let emoji = context.emoji {
        $0.emoji = emoji
      }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async throws(TransactionExecutionError) {
    log.trace("Updating chat info optimistically")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        if var chat = try Chat.fetchOne(db, id: context.chatID) {
          if let title = context.title {
            chat.title = title
          }
          if let emoji = context.emoji {
            chat.emoji = emoji.isEmpty ? nil : emoji
          }
          try chat.save(db)
        }
      }
    } catch {
      log.error("Failed to update chat info optimistically", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .updateChatInfo(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("updateChatInfo result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        let chat = Chat(from: response.chat)
        try chat.save(db)
      }
    } catch {
      log.error("Failed to save updated chat info", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("UpdateChatInfo transaction failed", error: error)
  }

  public func cancelled() async {
    log.trace("UpdateChatInfo transaction cancelled")
  }
}

public extension Transaction2 where Self == UpdateChatInfoTransaction {
  static func updateChatInfo(chatID: Int64, title: String?, emoji: String?) -> UpdateChatInfoTransaction {
    UpdateChatInfoTransaction(chatID: chatID, title: title, emoji: emoji)
  }
}
