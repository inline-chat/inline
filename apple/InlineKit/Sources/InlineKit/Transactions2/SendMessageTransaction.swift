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
  // Properties
  public var method: InlineProtocol.Method = .sendMessage
  public var input: InlineProtocol.RpcCall.OneOf_Input?

  // Private
  private var log = Log.scoped("Transactions/SendMessage")
  private var text: String?
  private var peerId: Peer
  private var chatId: Int64
  private var replyToMsgId: Int64?
  private var isSticker: Bool?
  private var entities: MessageEntities?

  // State
  private var randomId: Int64
  private var peerUserId: Int64?
  private var peerThreadId: Int64?
  private var temporaryMessageId: Int64
  private var date = Date()

  public init(
    text: String?,
    peerId: Peer,
    chatId: Int64,
    replyToMsgId: Int64? = nil,
    isSticker: Bool? = nil,
    entities: MessageEntities? = nil
  ) {
    self.text = text
    self.peerId = peerId
    self.chatId = chatId
    self.replyToMsgId = replyToMsgId
    self.isSticker = isSticker
    self.entities = entities

    randomId = Int64.random(in: 0 ... Int64.max)
    peerUserId = if case let .user(id) = peerId { id } else { nil }
    peerThreadId = if case let .thread(id) = peerId { id } else { nil }
    temporaryMessageId = -1 * randomId

    // Create input for send message
    input = .sendMessage(.with {
      $0.peerID = peerId.toInputPeer()
      $0.randomID = randomId
      $0.temporarySendDate = Int64(date.timeIntervalSince1970.rounded())
      $0.isSticker = isSticker ?? false

      if let text { $0.message = text }
      if let replyToMsgId { $0.replyToMsgID = replyToMsgId }
      if let entities { $0.entities = entities }
    })
  }

  // Methods
  public func optimistic() async {
    log.debug("Optimistic send message")

    let message = Message(
      messageId: temporaryMessageId,
      randomId: randomId,
      fromId: Auth.getCurrentUserId()!,
      date: date,
      text: text,
      peerUserId: peerUserId,
      peerThreadId: peerThreadId,
      chatId: chatId,
      out: true,
      status: .sending,
      repliedToMessageId: replyToMsgId,
      fileId: nil,
      photoId: nil,
      videoId: nil,
      documentId: nil,
      transactionId: nil, // No longer using transaction ID in new system
      isSticker: isSticker,
      entities: entities
    )

    // Clear typing status
    Task {
      await ComposeActions.shared.stoppedTyping(for: peerId)
    }

    Task(priority: .userInitiated) {
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

      Task(priority: .userInitiated) { @MainActor in
        if let newMessage {
          MessagesPublisher.shared.messageAddedSync(fullMessage: newMessage, peer: peerId)
        } else {
          log.error("Failed to save message and push update")
        }
      }
    }
  }

  public func apply(_ result: RpcResult.OneOf_Result?) async throws(TransactionExecutionError) {
    guard case let .sendMessage(response) = result else {
      throw TransactionExecutionError.invalid
    }

    await Realtime.shared.applyUpdates(response.updates)
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
          .filter(Column("randomId") == randomId && Column("fromId") == currentUserId)
          .updateAll(
            db,
            Column("status").set(to: MessageSendingStatus.failed.rawValue)
          )
        return try Message.fetchOne(db, key: ["messageId": temporaryMessageId, "chatId": chatId])
      }

      // Update UI
      if let message {
        Task { @MainActor in
          try await Task.sleep(for: .milliseconds(100))
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: peerId, animated: true)
        }
      }
    } catch {
      log.error("Failed to update message status on failure", error: error)
    }
  }

  public func cancelled() async {
    log.debug("Cancelled send message")

    do {
      // Remove from database and update chat state
      try await AppDatabase.shared.dbWriter.write { db in
        try Message.deleteMessages(db, messageIds: [temporaryMessageId], chatId: chatId)
      }

      // Remove from UI cache
      Task { @MainActor in
        MessagesPublisher.shared.messagesDeleted(messageIds: [temporaryMessageId], peer: peerId)
      }
    } catch {
      log.error("Failed to cancel send message", error: error)
    }
  }
}

// Helper

public extension Transaction2 {
  static func sendMessage(
    text: String?,
    peerId: Peer,
    chatId: Int64,
    replyToMsgId: Int64? = nil,
    isSticker: Bool? = nil,
    entities: MessageEntities? = nil
  ) -> SendMessageTransaction {
    SendMessageTransaction(
      text: text,
      peerId: peerId,
      chatId: chatId,
      replyToMsgId: replyToMsgId,
      isSticker: isSticker,
      entities: entities
    )
  }
}
