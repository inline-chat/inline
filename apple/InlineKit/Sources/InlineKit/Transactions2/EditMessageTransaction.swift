import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

public struct EditMessageTransaction: Transaction2 {
  // Properties
  public var method: InlineProtocol.Method = .editMessage
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/EditMessage")
  private var messageId: Int64
  private var text: String
  private var chatId: Int64
  private var peerId: Peer
  private var entities: MessageEntities?

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
    input = .editMessage(.with {
      $0.peerID = peerId.toInputPeer()
      $0.messageID = messageId
      $0.text = text
      if let entities {
        $0.entities = entities
      }
    })
    self.messageId = messageId
    self.text = text
    self.chatId = chatId
    self.peerId = peerId
    self.entities = entities
  }

  // Methods
  public func optimistic() async {
    log.debug("Optimistic edit message \(messageId) \(peerId) \(chatId)")
    do {
      try await AppDatabase.shared.dbWriter.write { db in
        var message = try Message
          .filter(Column("messageId") == messageId && Column("chatId") == chatId).fetchOne(db)
        if let current = message?.text, current == text {
          message?.editDate = nil
        } else {
          message?.editDate = Date()
          message?.text = text
          message?.entities = entities
        }
        try message?.saveMessage(db)
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

public extension Transaction2 {
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
