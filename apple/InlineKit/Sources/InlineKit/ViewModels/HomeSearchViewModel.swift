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
  @Published public private(set) var isSearching: Bool = false

  private var db: AppDatabase
  private var searchToken = UUID()

  public init(db: AppDatabase) {
    self.db = db
  }

  public func search(query: String) {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    searchToken = UUID()
    let token = searchToken

    guard !trimmedQuery.isEmpty else {
      results = []
      isSearching = false
      return
    }

    isSearching = true

    Task {
      do {
        let queryPattern = "%\(trimmedQuery)%"
        let chats = try await db.reader.read { db in
          let threads = try Chat
            .filter {
              $0.title.like("%\(trimmedQuery)%") &&
                $0.type == ChatType.thread.rawValue
            }
            .including(optional: Chat.space)
            .asRequest(of: ThreadInfo.self)
            .fetchAll(db)

          let users = try User
            .filter(
              sql: "firstName LIKE ? OR lastName LIKE ? OR email = ? OR username = ?",
              arguments: [queryPattern, queryPattern, trimmedQuery, trimmedQuery]
            )
            .fetchAll(db)

          return threads.map { HomeSearchResultItem.thread($0) } +
            users.map { HomeSearchResultItem.user($0) }
        }

        guard searchToken == token else { return }
        results = chats.sorted(by: { $0.title ?? "" < $1.title ?? "" })
        isSearching = false
      } catch {
        Log.shared.error("Failed to search home items: \(error)")
        guard searchToken == token else { return }
        isSearching = false
      }
    }
  }
}
