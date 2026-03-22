import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateChatTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .createChat
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var title: String
    public var emoji: String?
    public var isPublic: Bool
    public var spaceId: Int64?
    public var participants: [Int64]
    public var reservedChatId: Int64?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  private var log = Log.scoped("Transactions/CreateChat")

  public init(
    title: String,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64],
    reservedChatId: Int64? = nil
  ) {
    context = Context(
      title: title,
      emoji: emoji,
      isPublic: isPublic,
      spaceId: spaceId,
      participants: participants,
      reservedChatId: reservedChatId
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createChat(.with {
      $0.title = context.title
      if let spaceId = context.spaceId { $0.spaceID = spaceId }
      if let emoji = context.emoji { $0.emoji = emoji }
      if let reservedChatId = context.reservedChatId { $0.reservedChatID = reservedChatId }
      $0.isPublic = context.isPublic
      $0.participants = context.participants.map { userId in
        InputChatParticipant.with { $0.userID = Int64(userId) }
      }
    })
  }

  public var satisfiedBlockersOnSuccess: [TransactionBlocker] {
    guard let reservedChatId = context.reservedChatId else { return [] }
    return [.chatCreated(chatId: reservedChatId)]
  }

  // Methods
  public func optimistic() async {
    guard let reservedChatId = context.reservedChatId else { return }

    let trimmedTitle = context.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let chat = Chat(
      id: reservedChatId,
      date: Date(),
      type: .thread,
      title: trimmedTitle.isEmpty ? nil : trimmedTitle,
      spaceId: context.spaceId,
      emoji: context.emoji,
      isPublic: context.isPublic,
      createdBy: Auth.shared.getCurrentUserId(),
      createState: .pending
    )
    let dialog = Dialog(optimisticForChat: chat)

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try chat.save(db)
        try dialog.save(db)
      }
    } catch {
      log.error("Failed to create optimistic chat", error: error)
    }
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
          var chat = Chat(from: response.chat)
          if let existingChat = try Chat.fetchOne(db, key: chat.id), chat.lastMsgId == nil {
            chat.lastMsgId = existingChat.lastMsgId
          }
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

    guard let reservedChatId = context.reservedChatId else { return }

    do {
      _ = try await AppDatabase.shared.dbWriter.write { db in
        try Chat
          .filter(Chat.Columns.id == reservedChatId)
          .updateAll(db, Chat.Columns.createState.set(to: ChatCreateState.failed.rawValue))
      }
    } catch {
      log.error("Failed to mark chat creation as failed", error: error)
    }
  }
}

// Helper

public extension Transaction2 where Self == CreateChatTransaction {
  static func createChat(
    title: String,
    emoji: String?,
    isPublic: Bool,
    spaceId: Int64?,
    participants: [Int64],
    reservedChatId: Int64? = nil
  ) -> CreateChatTransaction {
    CreateChatTransaction(
      title: title,
      emoji: emoji,
      isPublic: isPublic,
      spaceId: spaceId,
      participants: participants,
      reservedChatId: reservedChatId
    )
  }
}
