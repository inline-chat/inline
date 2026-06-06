import Foundation
import GRDB
import RealtimeV2

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
  public enum Error: Swift.Error {
    case missingCurrentUser
  }

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
      .filter(Chat.Columns.parentMessageId == nil)
      .filter(sql: "title = ? COLLATE NOCASE", arguments: StatementArguments([trimmedTitle]))
      .order(Chat.Columns.date.desc)
      .limit(1)
      .fetchAll(db)

    guard let chat = chats.first else { return nil }

    return .thread(id: chat.id)
  }

  public static func resolveOrCreate(
    _ target: ThreadLinkTarget,
    currentUserId: Int64?,
    database: AppDatabase = .shared,
    realtimeV2: RealtimeV2 = Api.realtime
  ) async throws -> Peer? {
    if let peer = try await resolve(target, database: database) {
      return peer
    }

    guard case let .title(spaceId, title) = target else {
      return nil
    }

    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard spaceId > 0, !trimmedTitle.isEmpty else {
      return nil
    }

    guard currentUserId != nil else {
      throw Error.missingCurrentUser
    }

    // TODO: Match the created thread's visibility to the parent thread once link context is available.
    let chatId = try await realtimeV2.createThreadLocally(
      title: trimmedTitle,
      emoji: nil,
      isPublic: true,
      spaceId: spaceId,
      participants: []
    )
    let peer: Peer = .thread(id: chatId)

    await realtimeV2.sendQueued(
      .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
    )

    return peer
  }
}
