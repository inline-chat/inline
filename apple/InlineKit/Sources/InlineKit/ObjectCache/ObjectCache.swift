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
  private var users: [Int64: UserInfo] = [:]
  private var chats: [Int64: Chat] = [:]
  private var cancellables: Set<AnyCancellable> = []
  private var userPublishers: [Int64: PassthroughSubject<UserInfo?, Never>] = [:]

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
    if chats[id] == nil {
      // fill in the cache
      observeChat(id: id)
    }

    return chats[id]
  }
}

// User
public extension ObjectCache {
  func observeUser(id userId: Int64) {
    log.trace("Observing user \(userId)")
    observingUsers.insert(userId)
    ValueObservation.tracking { db in
      try User
        .filter(id: userId)
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchOne(db)
    }
    .publisher(in: db.dbWriter, scheduling: .immediate)
    .sink(
      receiveCompletion: { completion in
        if case let .failure(error) = completion {
          Log.shared.error("Failed to observe user \(userId): \(error)")
        }
      },
      receiveValue: { [weak self] user in
        if let user {
          self?.log.trace("User \(userId) updated")
          self?.users[userId] = user
        } else {
          self?.log.trace("User \(userId) not found")
          self?.users[userId] = nil
        }

        // update publishers
        self?.userPublishers[userId]?.send(user)
      }
    ).store(in: &cancellables)
  }
}

// Chats
public extension ObjectCache {
  func observeChat(id chatId: Int64) {
    log.trace("Observing chat \(chatId)")
    ValueObservation.tracking { db in
      try Chat
        .filter(id: chatId)
        .fetchOne(db)
    }
    .publisher(in: db.dbWriter, scheduling: .immediate)
    .sink(
      receiveCompletion: { completion in
        if case let .failure(error) = completion {
          Log.shared.error("Failed to observe chat \(chatId): \(error)")
        }
      },
      receiveValue: { [weak self] user in
        if let user {
          self?.log.trace("Chat \(chatId) updated")
          self?.chats[chatId] = user
        } else {
          self?.log.trace("Chat \(chatId) not found")
          self?.chats[chatId] = nil
        }
      }
    ).store(in: &cancellables)
  }
}
