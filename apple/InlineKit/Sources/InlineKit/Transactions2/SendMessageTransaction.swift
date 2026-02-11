import Auth
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

#if os(iOS)
import UIKit
#endif

public struct SendMessageTransaction: Transaction2 {
  // Private
  private var log = Log.scoped("Transactions/SendMessage")

  // Properties
  public var method: InlineProtocol.Method = .sendMessage
  public var context: Context
  public var type: TransactionKindType = .mutation(MutationConfig(retryAfterAck: true))

  public struct Context: Sendable, Codable {
    public var text: String?
    public var peerId: Peer
    public var chatId: Int64
    public var replyToMsgId: Int64?
    public var isSticker: Bool?
    public var isNudge: Bool
    public var entities: MessageEntities?
    public var sendMode: MessageSendMode?
    public var randomId: Int64
    public var temporaryMessageId: Int64

    enum CodingKeys: String, CodingKey {
      case text
      case peerId
      case chatId
      case replyToMsgId
      case isSticker
      case isNudge
      case entities
      case sendMode
      case randomId
      case temporaryMessageId
    }

    public init(
      text: String?,
      peerId: Peer,
      chatId: Int64,
      replyToMsgId: Int64?,
      isSticker: Bool?,
      isNudge: Bool,
      entities: MessageEntities?,
      sendMode: MessageSendMode?,
      randomId: Int64,
      temporaryMessageId: Int64
    ) {
      self.text = text
      self.peerId = peerId
      self.chatId = chatId
      self.replyToMsgId = replyToMsgId
      self.isSticker = isSticker
      self.isNudge = isNudge
      self.entities = entities
      self.sendMode = sendMode
      self.randomId = randomId
      self.temporaryMessageId = temporaryMessageId
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      text = try container.decodeIfPresent(String.self, forKey: .text)
      peerId = try container.decode(Peer.self, forKey: .peerId)
      chatId = try container.decode(Int64.self, forKey: .chatId)
      replyToMsgId = try container.decodeIfPresent(Int64.self, forKey: .replyToMsgId)
      isSticker = try container.decodeIfPresent(Bool.self, forKey: .isSticker)
      isNudge = try container.decodeIfPresent(Bool.self, forKey: .isNudge) ?? false
      entities = try container.decodeIfPresent(MessageEntities.self, forKey: .entities)
      if let rawValue = try container.decodeIfPresent(Int.self, forKey: .sendMode) {
        sendMode = MessageSendMode(rawValue: rawValue) ?? .modeUnspecified
      } else {
        sendMode = nil
      }
      randomId = try container.decode(Int64.self, forKey: .randomId)
      temporaryMessageId = try container.decode(Int64.self, forKey: .temporaryMessageId)
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encodeIfPresent(text, forKey: .text)
      try container.encode(peerId, forKey: .peerId)
      try container.encode(chatId, forKey: .chatId)
      try container.encodeIfPresent(replyToMsgId, forKey: .replyToMsgId)
      try container.encodeIfPresent(isSticker, forKey: .isSticker)
      if isNudge {
        try container.encode(isNudge, forKey: .isNudge)
      }
      try container.encodeIfPresent(entities, forKey: .entities)
      if let sendMode = sendMode {
        try container.encode(sendMode.rawValue, forKey: .sendMode)
      }
      try container.encode(randomId, forKey: .randomId)
      try container.encode(temporaryMessageId, forKey: .temporaryMessageId)
    }
  }

  public init(
    text: String?,
    peerId: Peer,
    chatId: Int64,
    replyToMsgId: Int64? = nil,
    isSticker: Bool? = nil,
    isNudge: Bool = false,
    entities: MessageEntities? = nil,
    sendMode: MessageSendMode? = nil
  ) {
    let randomId = Int64.random(in: 0 ... Int64.max)
    context = Context(
      text: text,
      peerId: peerId,
      chatId: chatId,
      replyToMsgId: replyToMsgId,
      isSticker: isSticker,
      isNudge: isNudge,
      entities: entities,
      sendMode: sendMode,
      randomId: randomId,
      temporaryMessageId: -1 * randomId
    )
  }

  public func input(from context: Context) -> InlineProtocol.RpcCall.OneOf_Input? {
    .sendMessage(.with {
      $0.peerID = context.peerId.toInputPeer()
      $0.randomID = context.randomId
      $0.temporarySendDate = Int64(Date().timeIntervalSince1970.rounded())
      $0.isSticker = context.isSticker ?? false

      if let text = context.text { $0.message = text }
      if let replyToMsgId = context.replyToMsgId { $0.replyToMsgID = replyToMsgId }
      if let entities = context.entities { $0.entities = entities }
      if let sendMode = context.sendMode { $0.sendMode = sendMode }
      if context.isNudge { $0.media = InputMedia.fromNudge() }
    })
  }

  enum CodingKeys: String, CodingKey {
    case context
  }

  var peerUserId: Int64? {
    if case let .user(id) = context.peerId { id } else { nil }
  }

  var peerThreadId: Int64? {
    if case let .thread(id) = context.peerId { id } else { nil }
  }

  var peerId: Peer {
    context.peerId
  }

  // Methods
  public func optimistic() async {
    log.debug("Optimistic send message")

    guard let fromId = Auth.shared.getCurrentUserId() else {
      log.error("Optimistic send message called without a current user id")
      return
    }

    let message = Message(
      messageId: context.temporaryMessageId,
      randomId: context.randomId,
      fromId: fromId,
      date: Date(), // Date here?
      text: context.text,
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      chatId: context.chatId,
      out: true,
      status: .sending,
      repliedToMessageId: context.replyToMsgId,
      fileId: nil,
      photoId: nil,
      videoId: nil,
      documentId: nil,
      transactionId: nil, // No longer using transaction ID in new system
      isSticker: context.isSticker,
      entities: context.entities
    )

    // Clear typing status
    Task(priority: .utility) {
      await ComposeActions.shared.stoppedTyping(for: peerId)
    }

    let newMessage = try? await AppDatabase.shared.dbWriter.write { db in
      do {
        // Save message
        try message.save(db)

        // Update last message id
        try Chat.updateLastMsgId(
          db,
          chatId: message.chatId,
          lastMsgId: message.messageId,
          date: message.date
        )

        // Fetch full message for update
        return try FullMessage.queryRequest()
          .filter(Column("messageId") == message.messageId)
          .filter(Column("chatId") == message.chatId)
          .fetchOne(db)
      } catch {
        log.error("Failed to save and fetch message", error: error)
        return nil
      }
    }

    #if os(iOS)
    Task(priority: .userInitiated) { @MainActor in
      if let newMessage {
        await MessagesPublisher.shared.messageAddedSync(fullMessage: newMessage, peer: context.peerId)
      } else {
        log.error("Failed to save message and push update")
      }
    }
    #else
    if let newMessage {
      await MessagesPublisher.shared.messageAddedSync(fullMessage: newMessage, peer: context.peerId)
    } else {
      log.error("Failed to save message and push update")
    }
    #endif
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .sendMessage(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Api.realtime.applyUpdates(response.updates)
  }

  public func failed(error: TransactionError2) async {
    log.error("Failed to send message", error: error)

    guard let currentUserId = Auth.getCurrentUserId() else {
      return
    }

    // Mark as failed
    do {
      let message = try await AppDatabase.shared.dbWriter.write { db in
        try Message
          .filter(Column("randomId") == context.randomId && Column("fromId") == currentUserId)
          .updateAll(
            db,
            Column("status").set(to: MessageSendingStatus.failed.rawValue)
          )
        return try Message.fetchOne(db, key: ["messageId": context.temporaryMessageId, "chatId": context.chatId])
      }

      // Update UI
      if let message {
        Task { @MainActor in
          try await Task.sleep(for: .milliseconds(100))
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: context.peerId, animated: true)
        }
      }

      #if os(macOS)
      await MacNotifications.shared.showMessageFailedNotification(
        chatId: context.chatId,
        peerId: context.peerId
      )
      #endif
    } catch {
      log.error("Failed to update message status on failure", error: error)
    }
  }

  public func cancelled() async {
    log.debug("Cancelled send message")

    do {
      // Remove from database and update chat state
      try await AppDatabase.shared.dbWriter.write { db in
        try Message.deleteMessages(db, messageIds: [context.temporaryMessageId], chatId: context.chatId)
      }

      // Remove from UI cache
      Task { @MainActor in
        MessagesPublisher.shared.messagesDeleted(messageIds: [context.temporaryMessageId], peer: context.peerId)
      }
    } catch {
      log.error("Failed to cancel send message", error: error)
    }
  }
}

// Helper

public extension Transaction2 where Self == SendMessageTransaction {
  static func sendMessage(
    text: String?,
    peerId: Peer,
    chatId: Int64,
    replyToMsgId: Int64? = nil,
    isSticker: Bool? = nil,
    isNudge: Bool = false,
    entities: MessageEntities? = nil,
    sendMode: MessageSendMode? = nil
  ) -> SendMessageTransaction {
    SendMessageTransaction(
      text: text,
      peerId: peerId,
      chatId: chatId,
      replyToMsgId: replyToMsgId,
      isSticker: isSticker,
      isNudge: isNudge,
      entities: entities,
      sendMode: sendMode
    )
  }
}
