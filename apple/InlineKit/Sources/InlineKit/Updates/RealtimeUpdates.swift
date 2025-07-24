import Auth
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
    // log.debug("Received update type: \(update.update)")

    // TODO: Save update state

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

        case let .deleteReaction(deleteReaction):
          try deleteReaction.apply(db)

        case let .editMessage(editMessage):
          try editMessage.apply(db)

        case let .newChat(newChat):
          try newChat.apply(db)

        case let .spaceMemberAdd(spaceMemberAdd):
          try spaceMemberAdd.apply(db)

        case let .spaceMemberDelete(spaceMemberDelete):
          try spaceMemberDelete.apply(db)

        case let .joinSpace(joinSpace):
          try joinSpace.apply(db)

        case let .participantAdd(participantAdd):
          try participantAdd.apply(db)

        case let .participantDelete(participantDelete):
          try participantDelete.apply(db)

        case let .newMessageNotification(newMessageNotification):
          try newMessageNotification.apply(db)

        case let .updateUserSettings(userSettings):
          userSettings.apply()

        case let .chatHasNewUpdates(chatHasNewUpdates):
          try chatHasNewUpdates.apply(db)

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

    try Chat.updateLastMsgId(db, chatId: message.chatID, lastMsgId: msg.messageId, date: msg.date)

    // increase unread count if message is not ours
    if var dialog = try? Dialog.get(peerId: msg.peerId).fetchOne(db) {
      dialog.unreadCount = (dialog.unreadCount ?? 0) + (msg.out == false ? 1 : 0)
      try dialog.update(db)
    }

    #if os(macOS)
    // Show notification for incoming messages
    if msg.out == false {
      Task { @MainActor in
        let mode = INUserSettings.current.notification.mode
        // Only show notification if mode is all
        guard mode == .all else { return }
        Task.detached {
          // Handle notification
          await MacNotifications.shared.handleNewMessage(protocolMsg: message)
        }
      }
    }
    #endif
  }
}

extension InlineProtocol.UpdateNewMessageNotification {
  func apply(_ db: Database) throws {
    #if os(macOS)
    // Show notification for incoming messages
    if message.out == false {
      Task { @MainActor in
        let mode = INUserSettings.current.notification.mode
        // Only show notification if mode is all
        guard mode != .all else { return }
        Task.detached {
          // Handle notification
          await MacNotifications.shared.handleNewMessage(protocolMsg: message)
        }
      }
    }
    #endif
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

    if let action {
      Task { await ComposeActions.shared.addComposeAction(for: peerID.toPeer(), action: action, userId: userID) }
    } else {
      // cancel - remove action for specific user, not all users
      Task { await ComposeActions.shared.removeComposeAction(for: peerID.toPeer(), userId: userID) }
    }
  }
}

extension InlineProtocol.UpdateDeleteMessages {
  func apply(_ db: Database) throws {
    guard let chat = try Chat.getByPeerId(peerId: peerID.toPeer()) else {
      Log.shared.error("Failed to find chat for peer \(peerID.toPeer())")
      return
    }

    do {
      // let chat = try Chat.fetchOne(db, id: chatId)
      let chatId = chat.id
      var prevChatLastMsgId = chat.lastMsgId

      // Delete messages
      for messageId in messageIds {
        // Update last message first
        if prevChatLastMsgId == messageId {
          let previousMessage = try Message
            .filter(Column("chatId") == chat.id)
            .order(Column("date").desc)
            .limit(1, offset: 1)
            .fetchOne(db)

          var updatedChat = chat
          updatedChat.lastMsgId = previousMessage?.messageId
          try updatedChat.save(db)

          // update so if next message is deleted, we can use it to update again
          prevChatLastMsgId = messageId
        }

        // TODO: Optimize this to use keys
        try Message
          .filter(Column("messageId") == messageId)
          .filter(Column("chatId") == chatId)
          .deleteAll(db)
      }

      Task(priority: .userInitiated) { @MainActor in
        MessagesPublisher.shared.messagesDeleted(messageIds: messageIds, peer: peerID.toPeer())
      }

    } catch {
      Log.shared.error("Failed to delete messages", error: error)
    }
  }
}

extension InlineProtocol.UpdateMessageAttachment {
  func apply(_ db: Database) throws {
    if attachment.attachment == nil {
      let attachmentId = attachment.id

      try Attachment
        .filter(Column("externalTaskId") == attachmentId)
        .deleteAll(db)

      try ExternalTask
        .filter(Column("id") == attachmentId)
        .deleteAll(db)

      Log.shared.debug("Deleted attachment with ID: \(attachmentId)")
    } else {
      guard let messageAttachment = attachment.attachment else {
        Log.shared.error("Message attachment is nil")
        return
      }

      let message = try Message.filter(Column("messageId") == messageID).filter(Column("chatId") == chatID)
        .fetchOne(db)

      if let message {
        _ = try Attachment.saveWithInnerItems(db, attachment: attachment, messageClientGlobalId: message.globalId!)
      }
    }

    let message = try Message.filter(Column("messageId") == messageID).filter(Column("chatId") == chatID)
      .fetchOne(db)

    if let message {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
        }
      }
    }
  }
}

extension InlineProtocol.UpdateReaction {
  func apply(_ db: Database) throws {
    _ = try Reaction.save(db, protocolMessage: reaction)
    let message = try Message
      .filter(Column("messageId") == reaction.messageID)
      .filter(Column("chatId") == reaction.chatID)
      .fetchOne(
        db
      )

    if let message {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
        }
      }
    }
  }
}

extension InlineProtocol.UpdateDeleteReaction {
  func apply(_ db: Database) throws {
    _ = try Reaction.filter(
      Column("messageId") == messageID
    ).filter(Column("chatId") == chatID)
      .filter(Column("emoji") == emoji)
      .filter(
        Column("userId") == userID
      ).deleteAll(db)

    let message = try Message
      .filter(Column("messageId") == messageID)
      .filter(Column("chatId") == chatID)
      .fetchOne(
        db
      )

    if let message {
      db.afterNextTransaction { _ in
        Task(priority: .userInitiated) { @MainActor in
          MessagesPublisher.shared.messageUpdatedSync(message: message, peer: message.peerId, animated: true)
        }
      }
    }
  }
}

extension InlineProtocol.UpdateEditMessage {
  func apply(_ db: Database) throws {
    let savedMessage = try Message.save(db, protocolMessage: message, publishChanges: true)

    db.afterNextTransaction { _ in
      Task { @MainActor in
        MessagesPublisher.shared.messageUpdatedWithId(
          messageId: message.id,
          chatId: message.chatID,
          peer: message.peerID.toPeer(),
          animated: false
        )
      }
    }
  }
}

extension InlineProtocol.UpdateNewChat {
  func apply(_ db: Database) throws {
    if hasUser {
      Log.shared.debug("saving user \(user)")
      do {
        // Save user if it's a private chat
        let _ = try User.save(db, user: user)
      } catch {
        Log.shared.error("Failed to save user", error: error)
      }
    }

    Log.shared.debug("saving chat \(chat)")
    do {
      let chat = Chat(from: chat)
      try chat.save(db)
    } catch {
      Log.shared.error("Failed to save chat", error: error)
    }

    do {
      let dialog = Dialog(optimisticForChat: Chat(from: chat))
      Log.shared.debug("saving dialog \(dialog)")
      try dialog.save(db)
    } catch {
      Log.shared.error("Failed to save dialog", error: error)
    }
  }
}

extension InlineProtocol.UpdateSpaceMemberAdd {
  func apply(_ db: Database) throws {
    let _ = try User.save(db, user: user)
    let member = Member(from: member)
    try member.save(db)
  }
}

extension InlineProtocol.UpdateSpaceMemberDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update space member delete user \(userID) from space \(spaceID)")

    do {
      // Delete the member from the database
      try Member
        .filter(Column("userId") == userID)
        .filter(Column("spaceId") == spaceID)
        .deleteAll(db)

      // If the removed user is the current user, clean up local data
      if userID == Auth.shared.getCurrentUserId() {
        // Remove all dialogs and chats for this space
        // Note: This is a simplified cleanup - you may need more comprehensive cleanup
        Log.shared.info("Current user was removed from space, cleaning up local data")

        do {
          // 1. Collect all chats that belong to the removed space
          let chatsInSpace = try Chat.filter(Column("spaceId") == spaceID).fetchAll(db)
          let chatIds = chatsInSpace.map(\.id)

          if !chatIds.isEmpty {
            // 2. Delete all messages, reactions, translations, participants, etc. that belong to those chats
            try Message.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
            try Reaction.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
            try ChatParticipant.filter(chatIds.contains(Column("chatId"))).deleteAll(db)

            // 3. Delete dialogs that reference these chats
            try Dialog.filter(chatIds.contains(Column("chatId"))).deleteAll(db)
          }

          // 4. Delete any dialogs that are directly associated with the space (safety)
          try Dialog.filter(Column("spaceId") == spaceID).deleteAll(db)

          // 5. Remove the chats themselves
          try Chat.filter(Column("spaceId") == spaceID).deleteAll(db)

          // 6. Remove all remaining members for this space (if any)
          try Member.filter(Column("spaceId") == spaceID).deleteAll(db)

          // 7. Finally delete the space record
          try Space.filter(Column("id") == spaceID).deleteAll(db)

        } catch {
          Log.shared.error("Failed to clean up space data", error: error)
        }

        // Notify UI so that any views related to this space can be dismissed
        Task.detached {
          NotificationCenter.default.post(
            name: Notification.Name("spaceDeletedNotification"),
            object: nil,
            userInfo: ["spaceId": spaceID]
          )
        }
      }
    } catch {
      Log.shared.error("Failed to delete space member", error: error)
    }
  }
}

extension InlineProtocol.UpdateJoinSpace {
  func apply(_ db: Database) throws {
    let space = Space(from: space)
    try space.save(db)
    let member = Member(from: member)
    try member.save(db)
  }
}

extension InlineProtocol.UpdateChatParticipantAdd {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant add \(chatID) \(participant.userID)")

    ChatParticipant.save(db, from: participant, chatId: chatID)
  }
}

extension InlineProtocol.UpdateChatParticipantDelete {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat participant delete \(chatID) \(userID)")

    do {
      try ChatParticipant.filter(Column("chatId") == chatID).filter(Column("userId") == userID).deleteAll(db)
    } catch {
      Log.shared.error("Failed to delete chat participant", error: error)
    }

    if userID == Auth.shared.getCurrentUserId() {
      do {
        try Message.filter(Column("chatId") == chatID).deleteAll(db)
      } catch {
        Log.shared.error("Failed to delete chat", error: error)
      }

      do {
        try Dialog.filter(Column("peerThreadId") == chatID).deleteAll(db)
      } catch {
        Log.shared.error("Failed to delete dialog", error: error)
      }

      do {
        try Chat.filter(Column("id") == chatID).deleteAll(db)
      } catch {
        Log.shared.error("Failed to delete chat", error: error)
      }

      // Post notification to pop chat route
      Task.detached {
        NotificationCenter.default.post(
          name: Notification.Name("chatDeletedNotification"),
          object: nil,
          userInfo: ["chatId": chatID]
        )
      }
    }
  }
}

extension InlineProtocol.UpdateUserSettings {
  func apply() {
    guard let settings = hasSettings ? settings.notificationSettings : nil else { return }

    Task { @MainActor in
      INUserSettings.current.updateFromServer(settings)
    }
  }
}

extension InlineProtocol.UpdateChatHasNewUpdates {
  func apply(_ db: Database) throws {
    Log.shared.debug("update chat has new updates \(chatID) \(updateSeq)")

    // Call realtime API to get updates for this chat
  }
}
