import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct CreateSubthreadTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/CreateSubthread")

  public var method: InlineProtocol.Method = .createSubthread
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var parentChatId: Int64
    public var parentMessageId: Int64?
    public var title: String?
    public var description: String?
    public var emoji: String?
    public var participants: [Int64]
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public init(
    parentChatId: Int64,
    parentMessageId: Int64?,
    title: String? = nil,
    description: String? = nil,
    emoji: String? = nil,
    participants: [Int64] = []
  ) {
    context = Context(
      parentChatId: parentChatId,
      parentMessageId: parentMessageId,
      title: title,
      description: description,
      emoji: emoji,
      participants: participants
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .createSubthread(.with {
      $0.parentChatID = context.parentChatId
      if let parentMessageId = context.parentMessageId {
        $0.parentMessageID = parentMessageId
      }
      if let title = context.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
        $0.title = title
      }
      if let description = context.description?.trimmingCharacters(in: .whitespacesAndNewlines),
         !description.isEmpty
      {
        $0.description_p = description
      }
      if let emoji = context.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
        $0.emoji = emoji
      }
      $0.participants = context.participants.map { userId in
        InputChatParticipant.with { $0.userID = userId }
      }
    })
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .createSubthread(response) = result, response.hasChat else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        var chat = Chat(from: response.chat)
        if let existingChat = try Chat.fetchOne(db, key: chat.id), chat.lastMsgId == nil {
          chat.lastMsgId = existingChat.lastMsgId
        }
        try chat.save(db)

        if response.hasDialog {
          _ = try response.dialog.saveFull(db)
        }

        if response.hasAnchorMessage {
          _ = try Message.save(db, protocolMessage: response.anchorMessage, publishChanges: false)
        }
      }
    } catch {
      log.error("Failed to save createSubthread result", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to create subthread", error: error)
  }
}

public extension Transaction2 where Self == CreateSubthreadTransaction {
  static func createSubthread(
    parentChatId: Int64,
    parentMessageId: Int64?,
    title: String? = nil,
    description: String? = nil,
    emoji: String? = nil,
    participants: [Int64] = []
  ) -> CreateSubthreadTransaction {
    CreateSubthreadTransaction(
      parentChatId: parentChatId,
      parentMessageId: parentMessageId,
      title: title,
      description: description,
      emoji: emoji,
      participants: participants
    )
  }
}
