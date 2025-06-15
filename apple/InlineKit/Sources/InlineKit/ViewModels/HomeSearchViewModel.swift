import Auth
import Combine
import GRDB
import Logger
import SwiftUI

public struct ThreadInfo: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable,
  Identifiable
{
  public var chat: Chat
  public var space: Space?

  public var id: Int64 {
    chat.id
  }

  public init(chat: Chat, space: Space) {
    self.chat = chat
    self.space = space
  }
}

public enum HomeSearchResultItem: Identifiable, Sendable, Hashable, Equatable {
  public var id: Int64 {
    switch self {
      case let .thread(threadInfo):
        threadInfo.id
      case let .user(user):
        user.id
    }
  }

  public var title: String? {
    switch self {
      case let .thread(threadInfo):
        threadInfo.chat.title
      case let .user(user):
        user.displayName
    }
  }

  case thread(ThreadInfo)
  case user(User)
}

@MainActor
public final class HomeSearchViewModel: ObservableObject {
  @Published public private(set) var results: [HomeSearchResultItem] = []

  private var db: AppDatabase

  public init(db: AppDatabase) {
    self.db = db
  }

  public func search(query: String) async {
    guard !query.isEmpty else {
      results = []
      return
    }

    do {
      let chats = try await db.reader.read { db in
        let threads = try Chat
          .filter {
            $0.title.like("%\(query)%") &&
              $0.type == ChatType.thread.rawValue
          }
          .including(optional: Chat.space)
          .asRequest(of: ThreadInfo.self)
          .fetchAll(db)

        let users = try User
          .filter {
            $0.firstName.like("%\(query)%") ||
              $0.lastName.like("%\(query)%") ||
              $0.email == query ||
              $0.username == query
          }
          .fetchAll(db)

        return threads.map { HomeSearchResultItem.thread($0) } +
          users.map { HomeSearchResultItem.user($0) }
      }

      results = chats.sorted(by: { $0.title ?? "" < $1.title ?? "" })
    } catch {
      Log.shared.error("Failed to search home items: \(error)")
    }
  }
}
