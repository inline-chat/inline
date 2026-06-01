import Foundation
import GRDB

public enum ThreadLinkTarget: Hashable, Sendable {
  case chatId(Int64)
  case title(spaceId: Int64, title: String)

  public var directPeer: Peer? {
    switch self {
      case let .chatId(chatId):
        .thread(id: chatId)
      case .title:
        nil
    }
  }
}

public enum ThreadLinkResolver {
  public static func resolve(
    _ target: ThreadLinkTarget,
    database: AppDatabase = .shared
  ) async throws -> Peer? {
    try await database.reader.read { db in
      try resolve(target, db: db)
    }
  }

  public static func resolve(_ target: ThreadLinkTarget, db: Database) throws -> Peer? {
    if let peer = target.directPeer {
      return peer
    }

    guard case let .title(spaceId, title) = target else {
      return nil
    }

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return nil
    }

    let chats = try Chat
      .filter(Chat.Columns.type == ChatType.thread.rawValue)
      .filter(Chat.Columns.spaceId == spaceId)
      .filter(Chat.Columns.title == trimmedTitle)
      .order(Chat.Columns.date.desc)
      .limit(2)
      .fetchAll(db)

    guard chats.count == 1, let chat = chats.first else {
      return nil
    }

    return .thread(id: chat.id)
  }
}
