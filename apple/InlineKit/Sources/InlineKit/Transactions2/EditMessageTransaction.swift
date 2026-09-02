import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct EditMessageTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .editMessage
  public var context: Context
  public var type: TransactionKindType = .mutation()

  public struct Context: Sendable, Codable {
    public var messageId: Int64
    public var text: String
    public var chatId: Int64
    public var peerId: Peer
    public var entities: MessageEntities?
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  // Private
  private var log = Log.scoped("Transactions/EditMessage")

  public init(message: InlineKit.Message, text: String, entities: MessageEntities? = nil) {
    self.init(
      messageId: message.messageId,
      text: text,
      chatId: message.chatId,
      peerId: message.peerId,
      entities: entities
    )
  }

  public init(messageId: Int64, text: String, chatId: Int64, peerId: Peer, entities: MessageEntities? = nil) {
    context = Context(messageId: messageId, text: text, chatId: chatId, peerId: peerId, entities: entities)
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .editMessage(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.messageID = context.messageId
      $0.text = context.text
      if let entities = context.entities {
        $0.entities = entities
      }
    })
  }

  // Computed

  var messageId: Int64 { context.messageId }
  var text: String { context.text }
  var chatId: Int64 { context.chatId }
  var peerId: Peer { context.peerId }
  var entities: MessageEntities? { context.entities }

  public var executionKey: TransactionExecutionKey? {
    .chatMutation(chatID: context.chatId)
  }

  // Methods
  public func optimistic() async {
    log.debug("Optimistic edit message \(messageId) \(peerId) \(chatId)")
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        try applyOptimisticEdit(in: db)
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messageUpdatedWithId(
          messageId: messageId,
          chatId: chatId,
          peer: peerId,
          animated: false
        )
      }
    } catch {
      log.error("Failed to edit message \(error)")
    }
  }

  /// Keep canonical text, entity ranges and their optional block projection in
  /// one write. An unchanged string can still have a formatting-only edit.
  func applyOptimisticEdit(in db: Database, date: Date = Date()) throws {
    guard var message = try Message
      .filter(Column("messageId") == messageId && Column("chatId") == chatId).fetchOne(db),
      message.text?.utf8.elementsEqual(text.utf8) != true || message.entities != entities else { return }
    message.text = text
    message.entities = entities
    message.editDate = date
    message.blockContentPayload = .literalMath(text: text, entities: entities)
    try message.saveMessage(db, preserveExistingBlockContentWhenMissing: false)
    // The acknowledgement may contain the same text/entities we just saved;
    // it cannot detect that these cached translations belong to the old source.
    try Translation
      .filter(Translation.Columns.messageId == messageId && Translation.Columns.chatId == chatId)
      .deleteAll(db)
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(
    TransactionExecutionError
  ) {
    guard case let .editMessage(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {}
}

// Helper

public extension Transaction2 where Self == EditMessageTransaction {
  static func editMessage(
    message: InlineKit.Message,
    text: String,
    entities: MessageEntities? = nil
  ) -> EditMessageTransaction {
    EditMessageTransaction(message: message, text: text, entities: entities)
  }

  static func editMessage(
    messageId: Int64,
    text: String,
    chatId: Int64,
    peerId: Peer,
    entities: MessageEntities? = nil
  ) -> EditMessageTransaction {
    EditMessageTransaction(messageId: messageId, text: text, chatId: chatId, peerId: peerId, entities: entities)
  }
}
