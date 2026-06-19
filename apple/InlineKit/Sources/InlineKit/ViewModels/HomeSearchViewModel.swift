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

    let compactQuery = Self.compactSearchText(trimmedQuery)
    guard compactQuery.isEmpty == false else {
      results = []
      isSearching = false
      return
    }

    isSearching = true

    Task {
      do {
        let normalizedQuery = Self.normalizedSearchText(trimmedQuery)
        let usernameQuery = normalizedQuery.hasPrefix("@") ? String(normalizedQuery.dropFirst()) : normalizedQuery
        let queryPattern = "%\(normalizedQuery)%"
        let compactPattern = "%\(compactQuery)%"
        let usernamePrefixPattern = usernameQuery.isEmpty ? "\u{0}" : "\(usernameQuery)%"
        let chats = try await db.reader.read { db in
          let threads = try Chat
            .filter(
              sql: """
              type = ? AND (
                LOWER(COALESCE(title, '')) LIKE ?
                OR LOWER(REPLACE(COALESCE(title, ''), ' ', '')) LIKE ?
              )
              """,
              arguments: [ChatType.thread.rawValue, queryPattern, compactPattern]
            )
            .including(optional: Chat.space)
            .asRequest(of: ThreadInfo.self)
            .fetchAll(db)

          let users = try User
            .filter(
              sql: """
              LOWER(COALESCE(firstName, '')) LIKE ?
              OR LOWER(COALESCE(lastName, '')) LIKE ?
              OR LOWER(TRIM(COALESCE(firstName, '') || ' ' || COALESCE(lastName, ''))) LIKE ?
              OR LOWER(COALESCE(firstName, '') || COALESCE(lastName, '')) LIKE ?
              OR LOWER(COALESCE(username, '')) LIKE ?
              OR LOWER(COALESCE(email, '')) LIKE ?
              """,
              arguments: [
                queryPattern,
                queryPattern,
                queryPattern,
                compactPattern,
                usernamePrefixPattern,
                usernamePrefixPattern
              ]
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

  private static func normalizedSearchText(_ text: String) -> String {
    text
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func compactSearchText(_ text: String) -> String {
    let normalized = normalizedSearchText(text)
    return String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0)
    }))
  }
}
