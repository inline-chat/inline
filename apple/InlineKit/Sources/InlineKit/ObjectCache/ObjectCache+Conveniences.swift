import Combine
import InlineObjectCache

/// One-record forms of the core calls. They add no behavior of their own.
public extension ObjectCache {
  func cached(_ id: ObjectID) -> ObjectSnapshot {
    cached([id])
  }

  func get(_ id: ObjectID) -> ObjectSnapshot {
    get([id])
  }

  @discardableResult
  func load(_ id: ObjectID) async -> ObjectSnapshot {
    await load([id])
  }

  func warm(_ id: ObjectID) {
    warm([id])
  }

  @discardableResult
  func ensure(_ id: ObjectID) async -> ObjectSnapshot {
    await ensure([id])
  }

  func getCachedUser(id: Int64) -> UserInfo? {
    cached(.user(id)).user(id)
  }

  func getCachedChat(id: Int64) -> Chat? {
    cached(.chat(id)).chat(id)
  }

  func getCachedSpace(id: Int64) -> Space? {
    cached(.space(id)).space(id)
  }

  func getUser(id: Int64) -> UserInfo? {
    get(.user(id)).user(id)
  }

  func getChat(id: Int64) -> Chat? {
    get(.chat(id)).chat(id)
  }

  func getSpace(id: Int64) -> Space? {
    get(.space(id)).space(id)
  }

  func loadUser(id: Int64) async -> UserInfo? {
    await load(.user(id)).user(id)
  }

  func loadChat(id: Int64) async -> Chat? {
    await load(.chat(id)).chat(id)
  }

  func loadSpace(id: Int64) async -> Space? {
    await load(.space(id)).space(id)
  }

  /// Emits the user when it loads or changes. Subscribing starts a load if needed
  /// and never reads synchronously; call `getUser` when the first frame needs a value.
  func getUserPublisher(id: Int64) -> PassthroughSubject<UserInfo?, Never> {
    warm(.user(id))
    if let publisher = userPublishers[id] { return publisher }
    let publisher = PassthroughSubject<UserInfo?, Never>()
    userPublishers[id] = publisher
    return publisher
  }

  /// Emits the chat when it loads or changes. Subscribing starts a load if needed
  /// and never reads synchronously; call `getChat` when the first frame needs a value.
  func getChatPublisher(id: Int64) -> PassthroughSubject<Chat?, Never> {
    warm(.chat(id))
    if let publisher = chatPublishers[id] { return publisher }
    let publisher = PassthroughSubject<Chat?, Never>()
    chatPublishers[id] = publisher
    return publisher
  }
}
