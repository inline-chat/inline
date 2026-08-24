import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatParticipantsTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetChatParticipants")

  // Properties
  public var method: InlineProtocol.Method = .getChatParticipants
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    let chatID: Int64
  }

  public init(chatID: Int64) {
    context = Context(chatID: chatID)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChatParticipants(.with { $0.chatID = context.chatID })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChatParticipants(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChatParticipants result: \(response)")

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Self.apply(response, chatID: context.chatID, in: db)
      }
      log.trace("getChatParticipants saved")
    } catch {
      log.error("Failed to save chat participants", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  static func apply(
    _ response: InlineProtocol.GetChatParticipantsResult,
    chatID: Int64,
    in db: Database
  ) throws {
    try ChatParticipant.filter(Column("chatId") == chatID).deleteAll(db)
    try ChatParticipantGroup.filter(ChatParticipantGroup.Columns.chatId == chatID).deleteAll(db)

    for user in response.users {
      _ = try User.save(db, user: user)
    }

    for participant in response.participants {
      try ChatParticipant.save(db, from: participant, chatId: chatID)
    }

    for group in response.groups {
      try UserGroup.save(db, from: group)
    }

    for participant in response.groupParticipants {
      try ChatParticipantGroup.save(db, from: participant, chatId: chatID)
    }
    try Chat
      .filter(Chat.Columns.id == chatID)
      .updateAll(db, [Chat.Columns.participantRosterComplete.set(to: true)])
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatParticipantsTransaction {
  static func getChatParticipants(chatID: Int64) -> GetChatParticipantsTransaction {
    GetChatParticipantsTransaction(chatID: chatID)
  }
}
