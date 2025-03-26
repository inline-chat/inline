import Foundation
import GRDB
import Logger

enum DataManagerError: Error {
  case networkError
  case apiError(description: String, code: Int)
  case localSaveError
  case notAuthorized
}

// ?? should we use main actor here?

/// Query or mutate data on the server and update local database
@MainActor
public class DataManager: ObservableObject {
  private var database: AppDatabase
  private var log = Log.scoped("DataManager", enableTracing: false)

  public init(database: AppDatabase) {
    self.database = database
  }

  public static let shared = DataManager(database: AppDatabase.shared)

  public func fetchMe() async throws -> User {
    log.debug("fetchMe")
    do {
      let result = try await ApiClient.shared.getMe()

      let user = try await database.dbWriter.write { db in
        try result.user.saveFull(db)
      }

      return user
    } catch {
      Log.shared.error("Error fetching user", error: error)
      throw error
    }
  }

  public func createSpace(name: String) async throws -> Int64? {
    log.debug("createSpace")
    do {
      let result = try await ApiClient.shared.createSpace(name: name)
      let space = Space(from: result.space)
      try await database.dbWriter.write { db in
        try space.save(db)
        try Member(from: result.member).save(db)
        try result.chats.forEach { chat in
          try Chat(from: chat).save(db)
        }
      }
      return space.id
    } catch {
      Log.shared.error("Failed to create space", error: error)
      throw error
    }
  }

  public func createThread(spaceId: Int64, title: String, emoji: String? = nil) async throws -> Int64? {
    log.debug("createThread")
    do {
      let result = try await ApiClient.shared.createThread(title: title, spaceId: spaceId, emoji: emoji)
      // Create the chat
      let chat = Chat(from: result.chat)
      try await database.dbWriter.write { db in
        try chat.save(db)
      }
      return chat.id

    } catch {
      Log.shared.error("Failed to create thread", error: error)
      throw error
    }
  }

  public func createPrivateChat(userId: Int64) async throws -> Peer {
    log.debug("createPrivateChat")
    do {
      let result = try await ApiClient.shared.createPrivateChat(userId: userId)

      try await database.dbWriter.write { db in
        let chat = Chat(from: result.chat)
        try chat.save(db)

        try result.dialog.saveFull(db)
      }

      return Peer.user(id: result.user.id)
    } catch {
      Log.shared.error("Failed to create private chat", error: error)
      throw error
    }
  }

  public func createPrivateChatWithOptimistic(user: ApiUser) async throws {
    log.debug("createPrivateChat with optimistic")

    // Optimistic
    try await database.dbWriter.write { db in
      try user.saveFull(db)
      let dialog = Dialog(optimisticForUserId: user.id)
      try dialog.save(db, onConflict: .ignore)
    }
    log.debug("saved optimistic")

    let userId = user.id

    // Do in background
    Task { @MainActor in
      do {
        // Remote call
        let result = try await ApiClient.shared.createPrivateChat(userId: userId)
        try await database.dbWriter.write { db in
          let chat = Chat(from: result.chat)
          try chat.save(db, onConflict: .replace)
          let dialog = Dialog(from: result.dialog)
          try dialog.save(db, onConflict: .replace)
        }
        Log.shared.info("Created private chat with \(user.anyName) with chatID: \(result.chat.id)")
      } catch {
        Log.shared.error("Failed to create private chat", error: error)
        throw error
      }
    }
  }

  /// Get list of user spaces and saves them
  @discardableResult
  public func getSpaces() async throws -> [Space] {
    log.debug("getSpaces")
    do {
      let result = try await ApiClient.shared.getSpaces()

      let spaces = try await database.dbWriter.write { db in
        let spaces = result.spaces.map { space in
          Space(from: space)
        }
        try spaces.forEach { space in
          try space.save(db)
        }

        for member in result.members {
          let member = Member(from: member)
          try member.save(db)
        }
        return spaces
      }

      return spaces
    } catch {
      throw error
    }
  }

  /// Get one user
  public func getUser(id: Int64) async throws {
    log.debug("getUser")
    do {
      let result = try await ApiClient.shared.getUser(userId: id)

      let _ = try await database.dbWriter.write { db in
        try result.user.saveFull(db)
      }
    } catch {
      throw error
    }
  }

  public func deleteSpace(spaceId: Int64) async throws {
    log.debug("deleteSpace")
    do {
      try await database.dbWriter.write { db in
        try Space.deleteOne(db, id: spaceId)

        try Member
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Chat
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)
      }

      let _ = try await ApiClient.shared.deleteSpace(spaceId: spaceId)

    } catch {
      Log.shared.error("Failed to delete space", error: error)
      throw error
    }
  }

  public func leaveSpace(spaceId: Int64) async throws {
    log.debug("leaveSpace")
    do {
      try await database.dbWriter.write { db in
        try Space.deleteOne(db, id: spaceId)

        try Member
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Chat
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)
      }

      let _ = try await ApiClient.shared.leaveSpace(spaceId: spaceId)
    } catch {
      Log.shared.error("Failed to leave space", error: error)
      throw error
    }
  }

  @discardableResult
  public func getPrivateChats() async throws -> [Chat] {
    log.debug("getPrivateChats")
    do {
      let result = try await ApiClient.shared.getPrivateChats()

      let chats = try await database.dbWriter.write { db in
        // First save peer users if they exist
        try result.peerUsers.forEach { apiUser in
          try apiUser.saveFull(db)
        }

        // Then save chats with lastMsgId set to nil
        let chats = result.chats.map { chat in
          var chat = Chat(from: chat)
          chat.lastMsgId = nil
          return chat
        }
        try chats.forEach { chat in
          try chat.save(db, onConflict: .replace)
        }

        // Save messages
        try result.messages.forEach { message in
          let _ = try message.saveFullMessage(db, publishChanges: false)
        }

        // TODO: Optimize
        // Update chat's last message ids now
        let chats_ = result.chats.map { chat in Chat(from: chat) }
        try chats_.forEach { chat in
          try chat.save(db, onConflict: .replace)
        }

        try result.dialogs.forEach { dialog in
          try dialog.saveFull(db)
        }

        return chats
      }
      log.debug("fetched private chats")
      return chats
    } catch {
      log.error("Failed to get private chats", error: error)
      throw error
    }
  }

  public func getDialogs(spaceId: Int64) async throws {
    log.debug("get dialogs")
    do {
      // Fetch
      let result = try await ApiClient.shared.getDialogs(spaceId: spaceId)

      log.debug("fetched dialogs")

      // Save
      try await database.dbWriter.write { db in

        // Save chats
        let chats = result.chats.map { chat in

          var chat = Chat(from: chat)
          // to avoid foriegn key constraint
          chat.lastMsgId = nil // TODO: fix

          return chat
        }
        try chats.forEach { chat in
          try chat.save(db, onConflict: .replace)
        }

        // Save users
        try result.users.forEach { user in
          try user.saveFull(db)
        }

        // Save messages
        let messages = result.messages.map { message in
          Message(from: message)
        }
        try messages.forEach { message in
          var mutableMessage = message
          try mutableMessage.saveMessage(db)
        }

        // Set last messages
        let chats_ = result.chats.map { chat in
          let chat = Chat(from: chat)

          return chat
        }
        try chats_.forEach { chat in
          try chat.save(db, onConflict: .replace)
        }

        // Save dialogs
        let dialogs = result.dialogs.map { dialog in
          Dialog(from: dialog)
        }
        try dialogs.forEach { dialog in
          try dialog.save(db, onConflict: .replace)
        }
      }

      log.debug("saved dialogs")
    } catch {
      log.error("Failed to get dialogs", error: error)
      throw error
    }
  }

  public func getChatHistory(
    peerUserId: Int64?,
    peerThreadId: Int64?,
    peerId: Peer?
  ) async throws {
    let finalPeerUserId: Int64?
    let finalPeerThreadId: Int64?
    var peerId_: Peer

    if let peerId {
      switch peerId {
        case let .user(id):
          finalPeerUserId = id
          finalPeerThreadId = nil
        case let .thread(id):
          finalPeerUserId = nil
          finalPeerThreadId = id
      }

      peerId_ = peerId
    } else {
      finalPeerUserId = peerUserId
      finalPeerThreadId = peerThreadId

      if let peerUserId {
        peerId_ = .user(id: peerUserId)
      } else if let peerThreadId {
        peerId_ = .thread(id: peerThreadId)
      } else {
        Log.shared.error("getChatHistory: peerId is nil")
        return
      }
    }

    log.debug(
      "getChatHistory with peerUserId: \(String(describing: finalPeerUserId)), peerThreadId: \(String(describing: finalPeerThreadId))"
    )

    let result = try await ApiClient.shared.getChatHistory(
      peerUserId: finalPeerUserId,
      peerThreadId: finalPeerThreadId
    )

    try await database.dbWriter.write { db in
      for apiMessage in result.messages {
        do {
          let _ = try apiMessage.saveFullMessage(db, publishChanges: false)
        } catch {
          Task {
            await self.log.error("failed to save message  from: \(apiMessage)", error: error)
          }
        }
      }
    }

    // Publish
    // Reload messages
    Task { @MainActor in
      MessagesPublisher.shared.messagesReload(peer: peerId_, animated: true)
    }
  }

  public func addReaction(messageId: Int64, chatId: Int64, emoji: String) async throws {
    let result = try await ApiClient.shared.addReaction(
      messageId: messageId, chatId: chatId, emoji: emoji
    )

    try await database.dbWriter.write { db in
      let reaction = Reaction(from: result.reaction)
      try reaction.save(db, onConflict: .replace)
    }
  }

  public func updateStatus(online: Bool) async throws {
//    log.debug("updateStatus")
//    let _ = try await ApiClient.shared.updateStatus(online: online)
  }

  public func updateDialog(
    peerId: Peer,
    pinned: Bool? = nil,
    draft: String? = nil,
    archived: Bool? = nil
  ) async throws {
    try await database.dbWriter.write { db in
      var dialog = try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId))

      if let pinned {
        dialog?.pinned = pinned
      }
      if let draft {
        dialog?.draft = draft
      }
      if let archived {
        dialog?.archived = archived
      }

      try dialog?.save(db, onConflict: .replace)
    }

    let updatedDialog = try await database.reader.read { db in
      try Dialog.fetchOne(db, id: Dialog.getDialogId(peerId: peerId))
    }
    guard let updatedDialog else {
      log.error("Failed to update dialog")
      return
    }

    _ = try await ApiClient.shared.updateDialog(
      peerId: peerId,
      pinned: pinned,
      archived: archived == nil ? updatedDialog.archived : archived
    )
  }

  public func getSpace(spaceId: Int64) async throws {
    let result = try await ApiClient.shared.getSpace(spaceId: spaceId)
    try await database.dbWriter.write { db in
      let space = Space(from: result.space)
      try space.save(db, onConflict: .replace)

      for member in result.members {
        let member = Member(from: member)
        try member.save(db, onConflict: .ignore)
      }

      for dialog in result.dialogs {
        let dialog = Dialog(from: dialog)

        try dialog.save(db, onConflict: .replace)
      }

      for chat in result.chats {
        let chat = Chat(from: chat)
        try chat.save(db, onConflict: .replace)
      }
    }
  }

  public func addMember(spaceId: Int64, userId: Int64) async throws {
    let result = try await ApiClient.shared.addMember(spaceId: spaceId, userId: userId)
    try await database.dbWriter.write { db in
      let member = Member(from: result.member)
      try member.save(db, onConflict: .replace)
    }
  }

  public func deleteMessage(
    messageId: Int64, chatId: Int64, peerId: Peer
  ) async throws {
    print("deleteMessage", messageId, chatId, peerId)
    let _ = try await ApiClient.shared.deleteMessage(messageId: messageId, chatId: chatId, peerId: peerId)

    try await database.dbWriter.write { db in

      if var chat = try Chat.fetchOne(db, id: chatId) {
        if chat.lastMsgId == messageId {
          let previousMessage = try Message
            .filter(Column("chatId") == chatId)
            .order(Column("date").desc)
            .limit(1, offset: 1)
            .fetchOne(db)

          chat.lastMsgId = previousMessage?.messageId
          try chat.save(db)
        }
      }

      try Message
        .filter(Column("messageId") == messageId)
        .filter(Column("chatId") == chatId)
        .deleteAll(db)
    }

    Task { @MainActor in
      MessagesPublisher.shared.messagesDeleted(messageIds: [messageId], peer: peerId)
    }
  }
}
