import Combine
import Foundation
import GRDB
import Logger

/// In memory cache for common nodes to not refetch
@MainActor
public class ObjectCache {
  public static let shared = ObjectCache()

  private init() {}

  private var log = Log.scoped("ObjectCache", enableTracing: false)
  private var db = AppDatabase.shared
  private var observingUsers: Set<Int64> = []
  private var observingChats: Set<Int64> = []
  private var observingSpaces: Set<Int64> = []
  private var users: [Int64: UserInfo] = [:]
  private var chats: [Int64: Chat] = [:]
  private var spaces: [Int64: Space] = [:]
  private var dbCancellables: [AnyDatabaseCancellable] = []
  private var userPublishers: [Int64: PassthroughSubject<UserInfo?, Never>] = [:]
  private var chatPublishers: [Int64: PassthroughSubject<Chat?, Never>] = [:]

  public func getUser(id userId: Int64) -> UserInfo? {
    if observingUsers.contains(userId) == false {
      // fill in the cache
      observeUser(id: userId)
    }

    let user = users[userId]

    log.trace("User \(userId) returned: \(user?.user.fullName ?? "nil")")
    return user
  }

  public func getUserPublisher(id userId: Int64) -> PassthroughSubject<UserInfo?, Never> {
    if userPublishers[userId] == nil {
      userPublishers[userId] = PassthroughSubject<UserInfo?, Never>()
      // fill in the cache
      let _ = getUser(id: userId)
    }

    return userPublishers[userId]!
  }

  public func getChat(id: Int64) -> Chat? {
    if chats[id] == nil, observingChats.contains(id) == false {
      // fill in the cache
      observeChat(id: id)
    }

    return chats[id]
  }

  public func getChatPublisher(id chatId: Int64) -> PassthroughSubject<Chat?, Never> {
    if chatPublishers[chatId] == nil {
      chatPublishers[chatId] = PassthroughSubject<Chat?, Never>()
      let _ = getChat(id: chatId)
    }

    return chatPublishers[chatId]!
  }

  public func getSpace(id: Int64) -> Space? {
    if spaces[id] == nil, observingSpaces.contains(id) == false {
      // fill in the cache
      observeSpace(id: id)
    }

    return spaces[id]
  }
}

// User
public extension ObjectCache {
  func observeUser(id userId: Int64) {
    guard observingUsers.contains(userId) == false else { return }
    log.trace("Observing user \(userId)")
    observingUsers.insert(userId)
#if DEBUG
    db.warnIfInMemoryDatabaseForObservation("ObjectCache.user")
#endif
    let cancellable = ValueObservation.tracking { db in
      try User
        .filter(id: userId)
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchOne(db)
    }
    .start(in: db.reader, scheduling: .immediate, onError: { [weak self] error in
      Log.shared.error("Failed to observe user \(userId): \(error)")
      self?.observingUsers.remove(userId)
    }, onChange: { [weak self] user in
      if let user {
        self?.log.trace("User \(userId) updated")
        self?.users[userId] = user
      } else {
        self?.log.trace("User \(userId) not found")
        self?.users[userId] = nil
      }

      self?.userPublishers[userId]?.send(user)
    })
    dbCancellables.append(cancellable)
  }
}

// Chats
public extension ObjectCache {
  func observeChat(id chatId: Int64) {
    guard observingChats.contains(chatId) == false else { return }
    log.trace("Observing chat \(chatId)")
    observingChats.insert(chatId)
#if DEBUG
    db.warnIfInMemoryDatabaseForObservation("ObjectCache.chat")
#endif
    let cancellable = ValueObservation.tracking { db in
      try Chat
        .filter(id: chatId)
        .fetchOne(db)
    }
    .start(in: db.reader, scheduling: .immediate, onError: { [weak self] error in
      Log.shared.error("Failed to observe chat \(chatId): \(error)")
      self?.observingChats.remove(chatId)
    }, onChange: { [weak self] chat in
      if let chat {
        self?.log.trace("Chat \(chatId) updated")
        self?.chats[chatId] = chat
      } else {
        self?.log.trace("Chat \(chatId) not found")
        self?.chats[chatId] = nil
      }

      self?.chatPublishers[chatId]?.send(chat)
    })
    dbCancellables.append(cancellable)
  }
}

// Spaces
public extension ObjectCache {
  func observeSpace(id spaceId: Int64) {
    guard observingSpaces.contains(spaceId) == false else { return }
    log.trace("Observing space \(spaceId)")
    observingSpaces.insert(spaceId)
#if DEBUG
    db.warnIfInMemoryDatabaseForObservation("ObjectCache.space")
#endif
    let cancellable = ValueObservation.tracking { db in
      try Space
        .filter(id: spaceId)
        .fetchOne(db)
    }
    .start(in: db.reader, scheduling: .immediate, onError: { [weak self] error in
      Log.shared.error("Failed to observe space \(spaceId): \(error)")
      self?.observingSpaces.remove(spaceId)
    }, onChange: { [weak self] space in
      if let space {
        self?.log.trace("Space \(spaceId) updated")
        self?.spaces[spaceId] = space
      } else {
        self?.log.trace("Space \(spaceId) not found")
        self?.spaces[spaceId] = nil
      }
    })
    dbCancellables.append(cancellable)
  }
}
