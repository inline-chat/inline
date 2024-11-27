import Foundation
import GRDB

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
  private var log = Log.scoped("DataManager")

  public init(database: AppDatabase) {
    self.database = database
  }

  public static let shared = DataManager(database: AppDatabase.shared)

  public func fetchMe() async throws -> User {
    log.debug("fetchMe")
    do {
      let result = try await ApiClient.shared.getMe()
      print("fetchMe result: \(result)")
      let user = User(from: result.user)
      try await database.dbWriter.write { db in
        try user.save(db)
        print("User saved: \(user)")
      }
      print("currentUserId: \(Auth.shared.getCurrentUserId() ?? Int64.min)")
      return user
    } catch {
      Log.shared.error("Error fetching user", error: error)
      throw error
    }
  }

  public func createSpace(name: String) async throws -> Space {
    log.debug("createSpace")
    do {
      let result = try await ApiClient.shared.createSpace(name: name)
      print("Create space result: \(result)")
      let space = Space(from: result.space)
      try await database.dbWriter.write { db in
        try space.save(db)

        let member = Member(from: result.member)
        try member.save(db)

        // Create main thread (default)
        for chat in result.chats {
          let thread = Chat(from: chat)
          try thread.save(db)
        }
        for dialog in result.dialogs {
          let dialog = Dialog(from: dialog)
          try dialog.save(db)
        }
      }

      // Return for navigating to space using id
      return space
    } catch {
      Log.shared.error("Failed to create space", error: error)
      throw error
    }
  }

  public func createThread(spaceId: Int64, title: String?) async throws -> Int64? {
    log.debug("createThread")
    do {
      return try await database.dbWriter.write { db in

        // TODO: API call to create thread

        // Create the chat
        let thread = Chat(
          date: Date.now,
          type: .thread,
          title: title,
          spaceId: spaceId
        )
        try thread.save(db)

        return thread.id
      }
    } catch {
      Log.shared.error("Failed to create thread", error: error)
      throw error
    }
  }

  public func createPrivateChat(userId: Int64) async throws -> Peer {
    log.debug("createPrivateChat")
    do {
      let result = try await ApiClient.shared.createPrivateChat(userId: userId)
      print("Result \(result)")
      try await database.dbWriter.write { db in
        let chat = Chat(from: result.chat)
        try chat.save(db)
        let dialog = Dialog(from: result.dialog)
        try dialog.save(db)
        let user = User(from: result.user)
        try user.save(db)
        print("Saved!!!!")
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

      let user = User(from: user)
      try user.save(db, onConflict: .ignore)
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
          let user = User(from: result.user)
          try user.save(db, onConflict: .replace)
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

  public func deleteSpace(spaceId: Int64) async throws {
    log.debug("deleteSpace")
    do {
      //            Use for user ID
      //            guard let currentUserId = Auth.shared.getCurrentUserId() else {
      //                throw DataManagerError.notAuthorized
      //            }

      let _ = try await ApiClient.shared.deleteSpace(spaceId: spaceId)

      try await database.dbWriter.write { db in
        try Space.deleteOne(db, id: spaceId)

        try Member
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Chat
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)
      }
    } catch {
      Log.shared.error("Failed to delete space", error: error)
      throw error
    }
  }

  public func leaveSpace(spaceId: Int64) async throws {
    log.debug("leaveSpace")
    do {
      let _ = try await ApiClient.shared.leaveSpace(spaceId: spaceId)

      try await database.dbWriter.write { db in
        try Space.deleteOne(db, id: spaceId)

        try Member
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)

        try Chat
          .filter(Column("spaceId") == spaceId)
          .deleteAll(db)
      }
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
        let peerUsers = result.peerUsers.map { User(from: $0) }
        try peerUsers.forEach { user in
          try user.save(db, onConflict: .replace)
        }

        // Then save chats with lastMsgId set to nil
        let chats = result.chats.map { chat in
          var chat = Chat(from: chat)
          // do not set lastMsgId to nil to avoid foreign key constraint
          return chat
        }
        try chats.forEach { chat in
          try chat.save(db, onConflict: .replace)
        }

        // Finally save dialogs
        let dialogs = result.dialogs.map { dialog in
          Dialog(from: dialog)
        }
        try dialogs.forEach { dialog in
          try dialog.save(db, onConflict: .replace)
        }

        return chats
      }

      print("getPrivateChats result: \(chats)")
      return chats
    } catch {
      Log.shared.error("Failed to get private chats", error: error)
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
          chat.lastMsgId = nil  // TODO: fix

          return chat
        }
        try chats.forEach { chat in
          try chat.save(db, onConflict: .replace)
        }

        // Save users
        let users = result.users.map { user in
          User(from: user)
        }
        try users.forEach { user in
          try user.save(db, onConflict: .replace)
        }

        // Save messages
        let messages = result.messages.map { message in
          Message(from: message)
        }
        try messages.forEach { message in
          try message.save(db, onConflict: .replace)
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

  public func sendMessage(
    chatId: Int64, peerUserId: Int64?, peerThreadId: Int64?, text: String, peerId: Peer?,
    randomId: Int64?  // for now nilable
  )
    async throws
  {
    let finalPeerUserId: Int64?
    let finalPeerThreadId: Int64?

    if let peerId = peerId {
      switch peerId {
      case .user(let id):
        finalPeerUserId = id
        finalPeerThreadId = nil
      case .thread(let id):
        finalPeerUserId = nil
        finalPeerThreadId = id
      }
    } else {
      finalPeerUserId = peerUserId
      finalPeerThreadId = peerThreadId
    }

    log.debug(
      "sendMessage with peerUserId: \(String(describing: finalPeerUserId)), peerThreadId: \(String(describing: finalPeerThreadId))"
    )

    let result = try await ApiClient.shared.sendMessage(
      peerUserId: finalPeerUserId,
      peerThreadId: finalPeerThreadId,
      text: text,
      randomId: randomId
    )

    Task { @MainActor in
      // Don't apply local changes if randomId is set which means optimistic update was handled
      if randomId == nil {
        try await database.dbWriter.write { db in
          let message = Message(from: result.message)
          do {
            try message.save(db)
          } catch {
            Log.shared.error("Failed to save message", error: error)
            throw error
          }
        }
      }
    }
  }

  public func getChatHistory(
    peerUserId: Int64?,
    peerThreadId: Int64?,
    peerId: Peer?
  ) async throws -> [Message] {
    let finalPeerUserId: Int64?
    let finalPeerThreadId: Int64?

    if let peerId = peerId {
      switch peerId {
      case .user(let id):
        finalPeerUserId = id
        finalPeerThreadId = nil
      case .thread(let id):
        finalPeerUserId = nil
        finalPeerThreadId = id
      }
    } else {
      finalPeerUserId = peerUserId
      finalPeerThreadId = peerThreadId
    }

    log.debug(
      "sendMessage with peerUserId: \(String(describing: finalPeerUserId)), peerThreadId: \(String(describing: finalPeerThreadId))"
    )

    let result = try await ApiClient.shared.getChatHistory(
      peerUserId: finalPeerUserId,
      peerThreadId: finalPeerThreadId
    )

    print("getChatHistory result: \(result)")
    let messages: [Message] = try await database.dbWriter.write { db in
      let messages = result.messages.map { Message(from: $0) }
      try messages.forEach { message in
        try message.save(db, onConflict: .ignore)
      }
      return messages
    }

    return messages
  }
}
