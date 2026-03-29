import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct GetChatTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/GetChat")

  // Properties
  public var method: InlineProtocol.Method = .getChat
  public var context: Context
  public var type: TransactionKindType = .query()

  public struct Context: Sendable, Codable {
    public var peer: Peer
  }

  public init(peer: Peer) {
    context = Context(peer: peer)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .getChat(.with {
      $0.peerID = context.peer.toInputPeer()
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // MARK: - Transaction Methods

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .getChat(response) = result else {
      throw TransactionExecutionError.invalid
    }

    log.trace("getChat result: \(response)")

    guard response.hasChat else {
      log.error("getChat result missing chat")
      throw TransactionExecutionError.invalid
    }

    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try Self.persist(response, in: db)
      }
      log.trace("getChat saved")
    } catch {
      log.error("Failed to save chat/dialog in transaction", error: error)
      throw TransactionExecutionError.invalid
    }
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to get chat", error: error)
  }

  static func persist(_ response: InlineProtocol.GetChatResult, in db: Database) throws {
    let log = Log.scoped("Transactions/GetChat")
    let chat: Chat

    if response.hasDialog {
      chat = try ReplyThreadTransactionPersistence.persistChatAndDialog(
        chat: response.chat,
        dialog: response.dialog,
        in: db,
        log: log
      )
    } else {
      chat = try ReplyThreadTransactionPersistence.persistChat(
        response.chat,
        in: db,
        log: log
      )
    }

    try ReplyThreadTransactionPersistence.persistPinnedMessageIds(
      response.pinnedMessageIds,
      chatId: chat.id,
      in: db
    )

    if response.hasAnchorMessage {
      try ReplyThreadTransactionPersistence.persistAnchorMessage(
        response.anchorMessage,
        in: db,
        log: Log.scoped("Transactions/GetChat")
      )
    }
  }
}

enum ReplyThreadTransactionPersistence {
  static func ensureParentChatPlaceholderIfNeeded(
    for chat: Chat,
    in db: Database,
    log: Log
  ) throws {
    guard let parentChatId = chat.parentChatId else { return }
    guard try Chat.fetchOne(db, id: parentChatId) == nil else { return }

    let placeholder = Chat(
      id: parentChatId,
      date: Date(timeIntervalSince1970: 0),
      type: .privateChat,
      title: nil,
      spaceId: chat.spaceId,
      peerUserId: nil,
      lastMsgId: nil,
      emoji: nil,
      isPublic: nil,
      createdBy: nil,
      parentChatId: nil,
      parentMessageId: nil,
      createState: nil
    )
    try placeholder.save(db)
    log.trace("Inserted placeholder parent chat for reply thread \(chat.id) -> \(parentChatId)")
  }

  static func persistChat(
    _ protoChat: InlineProtocol.Chat,
    in db: Database,
    log: Log
  ) throws -> Chat {
    do {
      var chat = Chat(from: protoChat)
      try ensureParentChatPlaceholderIfNeeded(for: chat, in: db, log: log)
      if let existingChat = try Chat.fetchOne(db, id: chat.id), chat.lastMsgId == nil {
        chat.lastMsgId = existingChat.lastMsgId
      }
      try chat.save(db)
      return chat
    } catch {
      log.error("Failed to persist reply-thread chat", error: error)
      throw error
    }
  }

  static func persistChatAndDialog(
    chat protoChat: InlineProtocol.Chat,
    dialog protoDialog: InlineProtocol.Dialog,
    in db: Database,
    log: Log
  ) throws -> Chat {
    do {
      let chat = try persistChat(protoChat, in: db, log: log)
      _ = try protoDialog.saveFull(db)
      return chat
    } catch {
      log.error("Failed to persist reply-thread chat/dialog", error: error)
      throw error
    }
  }

  static func persistPinnedMessageIds(
    _ pinnedMessageIds: [Int64],
    chatId: Int64,
    in db: Database
  ) throws {
    try PinnedMessage.filter(Column("chatId") == chatId).deleteAll(db)

    for (index, messageId) in pinnedMessageIds.enumerated() {
      let pinned = PinnedMessage(chatId: chatId, messageId: messageId, position: Int64(index))
      try pinned.save(db)
    }
  }

  static func persistAnchorMessage(
    _ anchorMessage: InlineProtocol.Message,
    in db: Database,
    log: Log
  ) throws {
    guard try Chat.fetchOne(db, id: anchorMessage.chatID) != nil else {
      log.warning("Skipping anchorMessage save because parent chat is missing: \(anchorMessage.chatID)")
      return
    }

    _ = try Message.save(db, protocolMessage: anchorMessage, publishChanges: false)
  }
}

// MARK: - Helper

public extension Transaction2 where Self == GetChatTransaction {
  static func getChat(peer: Peer) -> GetChatTransaction {
    GetChatTransaction(peer: peer)
  }
}
