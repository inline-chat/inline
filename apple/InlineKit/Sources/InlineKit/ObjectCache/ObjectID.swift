import GRDB
@_exported import InlineObjectCache

/// Identifies one record the cache can hold.
public enum ObjectID: Hashable, Sendable {
  case user(Int64)
  case chat(Int64)
  case space(Int64)
  case message(chatId: Int64, messageId: Int64)
}

/// Tunable bounds for `ObjectCache`. Adjust here; nothing else encodes these numbers.
enum ObjectCacheLimits {
  /// Records per kind that are re-read after every write to that kind's tables,
  /// most recently used first. Higher keeps more records fresh without being
  /// asked, at the cost of a larger batch read per write. Records past this limit
  /// are marked stale and re-read when next requested.
  ///
  /// Messages get a small number because the message table is written constantly.
  static func tracked(_ kind: ObjectKind) -> Int {
    switch kind {
      case .user: 512
      case .chat: 512
      case .space: 128
      case .message: 64
    }
  }

  /// Records of all kinds kept in memory. Past this, the least recently used are
  /// dropped until `memory * evictionKeepRatio` remain.
  static let memory = 4_096

  /// Share of `memory` kept by one eviction pass. Lower evicts less often but in bigger steps.
  static let evictionKeepRatio = 0.75
}

enum ObjectKind: CaseIterable, Sendable {
  case user
  case chat
  case space
  case message

  /// Tables whose writes can change a record of this kind.
  var tables: [String] {
    switch self {
      case .user: [User.databaseTableName, File.databaseTableName]
      case .chat: [Chat.databaseTableName]
      case .space: [Space.databaseTableName]
      case .message: [Message.databaseTableName]
    }
  }
}

public enum ObjectRecord: Equatable, Sendable {
  case user(UserInfo)
  case chat(Chat)
  case space(Space)
  case message(Message)
}

public typealias ObjectSnapshot = ObjectStoreSnapshot<ObjectID, ObjectRecord>

public extension ObjectStoreSnapshot<ObjectID, ObjectRecord> {
  func user(_ id: Int64) -> UserInfo? {
    guard case let .user(value) = record(.user(id)) else { return nil }
    return value
  }

  func chat(_ id: Int64) -> Chat? {
    guard case let .chat(value) = record(.chat(id)) else { return nil }
    return value
  }

  func space(_ id: Int64) -> Space? {
    guard case let .space(value) = record(.space(id)) else { return nil }
    return value
  }

  func message(chatId: Int64, messageId: Int64) -> Message? {
    guard case let .message(value) = record(.message(chatId: chatId, messageId: messageId)) else { return nil }
    return value
  }
}

/// Reads cache records from the app database, one batched query per kind.
struct DatabaseObjectSource: ObjectSource {
  let database: AppDatabase

  func kind(of id: ObjectID) -> ObjectKind {
    switch id {
      case .user: .user
      case .chat: .chat
      case .space: .space
      case .message: .message
    }
  }

  func readNow(_ ids: [ObjectID]) throws -> [ObjectID: ObjectRecord] {
    try database.reader.read { db in try Self.fetch(db, ids) }
  }

  func read(_ ids: [ObjectID]) async throws -> [ObjectID: ObjectRecord] {
    try await database.reader.read { db in try Self.fetch(db, ids) }
  }

  static func fetch(_ db: Database, _ ids: [ObjectID]) throws -> [ObjectID: ObjectRecord] {
    var userIDs: [Int64] = []
    var chatIDs: [Int64] = []
    var spaceIDs: [Int64] = []
    var messageIDsByChat: [Int64: [Int64]] = [:]
    for id in ids {
      switch id {
        case let .user(id): userIDs.append(id)
        case let .chat(id): chatIDs.append(id)
        case let .space(id): spaceIDs.append(id)
        case let .message(chatId, messageId): messageIDsByChat[chatId, default: []].append(messageId)
      }
    }

    var records: [ObjectID: ObjectRecord] = [:]
    if !userIDs.isEmpty {
      let users = try User
        .filter(ids: userIDs)
        .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
        .asRequest(of: UserInfo.self)
        .fetchAll(db)
      for user in users {
        records[.user(user.id)] = .user(user)
      }
    }
    if !chatIDs.isEmpty {
      for chat in try Chat.fetchAll(db, ids: chatIDs) {
        records[.chat(chat.id)] = .chat(chat)
      }
    }
    if !spaceIDs.isEmpty {
      for space in try Space.fetchAll(db, ids: spaceIDs) {
        records[.space(space.id)] = .space(space)
      }
    }
    // One seek per message in the (chatId, messageId) index.
    for (chatId, messageIDs) in messageIDsByChat {
      let messages = try Message
        .filter(Message.Columns.chatId == chatId && messageIDs.contains(Message.Columns.messageId))
        .fetchAll(db)
      for message in messages {
        records[.message(chatId: chatId, messageId: message.messageId)] = .message(message)
      }
    }
    return records
  }
}
