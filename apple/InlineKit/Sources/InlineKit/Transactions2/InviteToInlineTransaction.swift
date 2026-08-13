import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct InviteToInlineTransaction: Transaction2 {
  private let log = Log.scoped("Transactions/InviteToInline")

  public var method: InlineProtocol.Method = .inviteToInline
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var userID: Int64?
    public var email: String?
    public var phoneNumber: String?
  }

  public init(userID: Int64) {
    context = Context(userID: userID)
  }

  public init(email: String) {
    context = Context(email: email)
  }

  public init(phoneNumber: String) {
    context = Context(phoneNumber: phoneNumber)
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func input(from context: Context) -> RpcCall.OneOf_Input? {
    .inviteToInline(.with {
      if let userID = context.userID {
        $0.userID = userID
      } else if let email = context.email {
        $0.email = email
      } else if let phoneNumber = context.phoneNumber {
        $0.phoneNumber = phoneNumber
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .inviteToInline(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        _ = try User.save(db, user: response.user)
        var chat = Chat(from: response.chat)
        if let existing = try Chat.fetchOne(db, key: chat.id), chat.lastMsgId == nil {
          chat.lastMsgId = existing.lastMsgId
        }
        _ = try chat.saveFull(db)
        try response.dialog.saveFull(db)
      }
    } catch {
      log.error("Failed to save general invite projection", error: error)
      throw TransactionExecutionError.invalid
    }
  }
}

public extension Transaction2 where Self == InviteToInlineTransaction {
  static func inviteToInline(userID: Int64) -> InviteToInlineTransaction {
    InviteToInlineTransaction(userID: userID)
  }

  static func inviteToInline(email: String) -> InviteToInlineTransaction {
    InviteToInlineTransaction(email: email)
  }

  static func inviteToInline(phoneNumber: String) -> InviteToInlineTransaction {
    InviteToInlineTransaction(phoneNumber: phoneNumber)
  }
}
