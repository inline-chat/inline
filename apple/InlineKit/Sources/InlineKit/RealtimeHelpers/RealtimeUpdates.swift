import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeAPI

public actor UpdatesEngine: Sendable, RealtimeUpdatesProtocol {
  public static let shared = UpdatesEngine()

  private let database: AppDatabase = .shared
  private let log = Log.scoped("RealtimeUpdates")

  public func apply(update: InlineProtocol.Update, db: Database) {
    log.trace("apply realtime update")

    do {
      switch update.update {
        case let .newMessage(newMessageUpdate):
          try newMessageUpdate.apply(db)

        case let .updateMessageID(updateMessageId):
          try updateMessageId.apply(db)

        case let .updateUserStatus(updateUserStatus):
          try updateUserStatus.apply(db)

        case let .updateComposeAction(updateComposeAction):
          updateComposeAction.apply()

        case let .deleteMessages(deleteMessages):
          try deleteMessages.apply(db)

        case let .messageAttachment(updateMessageAttachment):
          try updateMessageAttachment.apply(db)

        case let .updateReaction(updateReaction):
          try updateReaction.apply(db)

        default:
          break
      }
    } catch {
      log.error("Failed to apply update", error: error)
    }
  }

  public func applyBatch(updates: [InlineProtocol.Update]) {
    log.debug("applying \(updates.count) updates")
    do {
      try database.dbWriter.write { db in
        for update in updates {
          self.apply(update: update, db: db)
        }
      }
    } catch {
      // handle error
      log.error("Failed to apply updates", error: error)
    }
  }
}

// MARK: Extensions

extension InlineProtocol.UpdateNewMessage {
  func apply(_ db: Database) throws {
    let msg = try Message.save(
      db,
      protocolMessage: message,
      publishChanges: true
    )

    // I think this needs to be faster
    var chat = try Chat.fetchOne(db, id: message.chatID)
    chat?.lastMsgId = msg.messageId
    try chat?.save(db)

    // increase unread count if message is not ours
    if var dialog = try? Dialog.get(peerId: msg.peerId).fetchOne(db) {
      dialog.unreadCount = (dialog.unreadCount ?? 0) + (msg.out == false ? 1 : 0)
      try dialog.update(db)
    }
  }
}

extension InlineProtocol.UpdateMessageId {
  func apply(_ db: Database) throws {
    Log.shared.debug("update message id \(randomID) \(messageID)")
    let message = try Message.filter(Column("randomId") == randomID).fetchOne(
      db
    )
    if var message {
      message.status = .sent
      message.messageId = messageID
      message.randomId = nil // should we do this?

      try message
        .saveMessage(
          db,
          onConflict: .ignore,
          publishChanges: true
        )

      // TODO: optimize this to update in one go
      var chat = try Chat.fetchOne(db, id: message.chatId)
      chat?.lastMsgId = message.messageId
      try chat?.save(db)
    }
  }
}

extension InlineProtocol.UpdateUserStatus {
  func apply(_ db: Database) throws {
    let onlineBoolean: Bool? = switch status.online {
      case .offline:
        false
      case .online:
        true
      default:
        nil
    }

    try User.filter(id: userID).updateAll(
      db,
      [
        Column("online").set(to: onlineBoolean),
        Column("lastOnline").set(to: status.lastOnline.hasDate ? status.lastOnline.date : nil),
      ]
    )
  }
}

extension InlineProtocol.UpdateComposeAction {
  func apply() {
    let action: ApiComposeAction? = switch self.action {
      case .typing:
        .typing
      case .uploadingDocument:
        .uploadingDocument
      case .uploadingPhoto:
        .uploadingPhoto
      case .uploadingVideo:
        .uploadingVideo
      default:
        nil
    }

    print("action: \(action)")

    if let action {
      Task { await ComposeActions.shared.addComposeAction(for: peerID.toPeer(), action: action, userId: userID) }
    } else {
      // cancel
      Task { await ComposeActions.shared.removeComposeAction(for: peerID.toPeer()) }
    }
  }
}

extension InlineProtocol.UpdateDeleteMessages {
  func apply(_ db: Database) throws {
    guard let chat = try Chat.getByPeerId(peerId: peerID.toPeer()) else {
      Log.shared.error("Failed to find chat for peer \(peerID.toPeer())")
      return
    }

    let prevChatLastMsgId = chat.lastMsgId

    for messageId in messageIds {
      try Message
        .filter(Column("messageId") == messageId && Column("chatId") == chat.id)
        .deleteAll(db)
    }

    // Update last message
    for messageId in messageIds {
      guard prevChatLastMsgId == messageId else { continue }

      let previousMessage = try Message
        .filter(Column("chatId") == chat.id)
        .order(Column("date").desc)
        .limit(1, offset: 1)
        .fetchOne(db)

      var updatedChat = chat
      updatedChat.lastMsgId = previousMessage?.messageId
      try updatedChat.save(db)

      break
    }

    Task { @MainActor in
      MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerID.toPeer())
    }
  }
}

extension InlineProtocol.UpdateMessageAttachment {
  func apply(_ db: Database) throws {
    guard let messageAttachment = attachment.attachment else {
      Log.shared.error("Message attachment is nil")
      return
    }

    guard case let .externalTask(externalTaskAttachment) = messageAttachment else {
      Log.shared.error("Unsupported attachment type")
      return
    }

    _ = try ExternalTask.save(db, externalTask: externalTaskAttachment)

    _ = try Attachment.save(db, messageAttachment: attachment)

    let message = try Message.filter(Column("messageId") == attachment.messageID).fetchOne(db)

    if let message {
      Task { @MainActor in
        await MessagesPublisher.shared
          .messageUpdated(message: message, peer: message.peerId, animated: true)
      }
    }
  }
}

extension InlineProtocol.UpdateReaction {
  func apply(_ db: Database) throws {
    print("RECIVED UPDATE FOR REACTON \(reaction)")
    _ = try Reaction.save(db, protocolMessage: reaction, publishChanges: true)
    let message = try Message.filter(Column("messageId") == reaction.messageID).fetchOne(db)
    print("RECIVED UPDATE FOR REACTON ON MESSAGE \(message)")
    if let message = message {
      print("TRIGERRING RELOAD")
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
        }
      }
    }
  }
}
