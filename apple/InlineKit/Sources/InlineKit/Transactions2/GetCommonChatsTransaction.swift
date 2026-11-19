import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

/// Threads the current user shares with another user, latest activity first.
/// The result is returned to the caller for its order and `nextOffset`; its
/// spaces, chats and dialogs are saved as sidecars.
public struct GetCommonChatsTransaction: Transaction2 {
  private var log = Log.scoped("Transactions/GetCommonChats")

  public var method: InlineProtocol.Method = .getCommonChats
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var userID: Int64
    /// `ChatListOffset` of the previous page, flattened to stay `Codable`.
    public var offsetChatID: Int64?
    public var offsetDate: Int64?
    public var limit: Int32?
  }

  public init(
    userID: Int64,
    offset: InlineProtocol.ChatListOffset? = nil,
    limit: Int32? = nil
  ) {
    context = Context(
      userID: userID,
      offsetChatID: offset?.chatID,
      offsetDate: offset.flatMap { $0.hasDate ? $0.date : nil },
      limit: limit
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getCommonChats(.with {
      $0.userID = context.userID
      if let offsetChatID = context.offsetChatID {
        $0.offset = .with {
          $0.chatID = offsetChatID
          if let offsetDate = context.offsetDate { $0.date = offsetDate }
        }
      }
      if let limit = context.limit { $0.limit = limit }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  public func optimistic() async {
    log.debug("GetCommonChats transaction - no optimistic updates")
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getCommonChats(response) = result else {
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Self.save(response, in: db)
      }
    } catch {
      log.error("Failed to save getCommonChats sidecars", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get common chats", error: error)
  }

  public func cancelled() async {
    log.debug("Cancelled getCommonChats transaction")
  }

  /// Spaces first, then chats, then dialogs, as their foreign keys require. The
  /// result carries no messages or users, so references to rows this device
  /// lacks are dropped rather than failing the whole page.
  static func save(_ response: InlineProtocol.GetCommonChatsResult, in db: Database) throws {
    // Only fill a missing space: a synced one keeps its own sequence and roster state.
    for space in response.spaces {
      guard try Space.fetchOne(db, id: space.id) == nil else { continue }
      try Space(from: space).save(db)
    }

    for protocolChat in response.chats {
      try Chat.saveSidecar(protocolChat, in: db)
    }

    for dialog in response.dialogs {
      _ = try dialog.saveFull(db)
    }
  }
}

public extension Transaction2 where Self == GetCommonChatsTransaction {
  static func getCommonChats(
    userID: Int64,
    offset: InlineProtocol.ChatListOffset? = nil,
    limit: Int32? = nil
  ) -> GetCommonChatsTransaction {
    GetCommonChatsTransaction(userID: userID, offset: offset, limit: limit)
  }
}

extension Chat {
  /// Saves a chat that arrived as a sidecar, without the messages, users or
  /// spaces it points at. References this device lacks keep their local values
  /// instead of failing the whole save on a foreign key.
  static func saveSidecar(_ protocolChat: InlineProtocol.Chat, in db: Database) throws {
    var chat = Chat(from: protocolChat)
    let existing = try Chat.fetchOne(db, id: chat.id)
    if let spaceId = chat.spaceId, try Space.fetchOne(db, id: spaceId) == nil {
      chat.spaceId = existing?.spaceId
    }
    if let createdBy = chat.createdBy, try User.fetchOne(db, id: createdBy) == nil {
      chat.createdBy = existing?.createdBy
    }
    if let parentChatId = chat.parentChatId, try Chat.fetchOne(db, id: parentChatId) == nil {
      chat.parentChatId = existing?.parentChatId
    }
    // Chat.lastMsgId is a deferred foreign key to a stored message. Keep the
    // local last message when the newer one has not been fetched yet.
    if let lastMsgId = chat.lastMsgId {
      let hasMessage = try Message
        .filter(Column("chatId") == chat.id)
        .filter(Column("messageId") == lastMsgId)
        .fetchCount(db) > 0
      if !hasMessage { chat.lastMsgId = existing?.lastMsgId }
    } else {
      chat.lastMsgId = existing?.lastMsgId
    }
    _ = try chat.saveFull(db)
  }
}
