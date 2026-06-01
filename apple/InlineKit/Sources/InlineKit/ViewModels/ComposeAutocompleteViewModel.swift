import Combine
import Foundation
import GRDB
import Logger

public enum ComposeAutocompleteKind: String, Hashable, Sendable {
  case thread
}

public struct ComposeAutocompleteMatch: Hashable {
  public let kind: ComposeAutocompleteKind
  public let range: NSRange
  public let query: String

  public init(kind: ComposeAutocompleteKind, range: NSRange, query: String) {
    self.kind = kind
    self.range = range
    self.query = query
  }
}

public struct ComposeAutocompleteItem: Identifiable, Hashable, Sendable {
  public enum Payload: Hashable, Sendable {
    case thread(chatId: Int64, spaceId: Int64?, title: String)
  }

  public let id: String
  public let kind: ComposeAutocompleteKind
  public let title: String
  public let subtitle: String?
  public let symbol: String?
  public let emoji: String?
  public let payload: Payload

  public init(
    id: String,
    kind: ComposeAutocompleteKind,
    title: String,
    subtitle: String? = nil,
    symbol: String? = nil,
    emoji: String? = nil,
    payload: Payload
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.emoji = emoji
    self.payload = payload
  }
}

@MainActor
public final class ComposeAutocompleteViewModel: ObservableObject {
  @Published public private(set) var match: ComposeAutocompleteMatch?
  @Published public private(set) var items: [ComposeAutocompleteItem] = []
  @Published public private(set) var selectedIndex = 0

  private let log = Log.scoped("ComposeAutocompleteViewModel")
  private let db: AppDatabase
  private let limit: Int
  private var spaceId: Int64?
  private var loadTask: Task<Void, Never>?
  private var loadToken = UUID()

  public init(db: AppDatabase = .shared, spaceId: Int64? = nil, limit: Int = 8) {
    self.db = db
    self.spaceId = spaceId
    self.limit = limit
  }

  deinit {
    loadTask?.cancel()
  }

  public var isVisible: Bool {
    match != nil && !items.isEmpty
  }

  public var selectedItem: ComposeAutocompleteItem? {
    guard items.indices.contains(selectedIndex) else { return nil }
    return items[selectedIndex]
  }

  public func configure(spaceId: Int64?) {
    guard self.spaceId != spaceId else { return }
    self.spaceId = spaceId
    reloadItems()
  }

  public func update(match: ComposeAutocompleteMatch?) {
    guard self.match != match else { return }
    self.match = match
    selectedIndex = 0
    reloadItems()
  }

  public func hide() {
    loadTask?.cancel()
    loadToken = UUID()
    match = nil
    items = []
    selectedIndex = 0
  }

  public func selectNext() {
    guard items.isEmpty == false else { return }
    selectedIndex = min(selectedIndex + 1, items.count - 1)
  }

  public func selectPrevious() {
    guard items.isEmpty == false else { return }
    selectedIndex = max(selectedIndex - 1, 0)
  }

  public func item(at index: Int) -> ComposeAutocompleteItem? {
    guard items.indices.contains(index) else { return nil }
    return items[index]
  }

  private func reloadItems() {
    loadTask?.cancel()
    loadToken = UUID()

    guard let match else {
      items = []
      selectedIndex = 0
      return
    }

    switch match.kind {
      case .thread:
        loadThreadItems(query: match.query)
    }
  }

  private func loadThreadItems(query: String) {
    guard let spaceId, spaceId > 0 else {
      items = []
      selectedIndex = 0
      return
    }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let token = UUID()
    loadToken = token

    loadTask = Task { [db, limit] in
      do {
        let chats = try await db.reader.read { db in
          var request = Chat
            .filter(Chat.Columns.type == ChatType.thread.rawValue)
            .filter(Chat.Columns.spaceId == spaceId)
            .filter(Chat.Columns.parentMessageId == nil)

          if !trimmedQuery.isEmpty {
            request = request.filter(Chat.Columns.title.like("%\(trimmedQuery)%"))
          }

          return try request
            .order(Chat.Columns.date.desc)
            .limit(limit)
            .fetchAll(db)
        }

        let items = chats.compactMap { chat -> ComposeAutocompleteItem? in
          guard let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty
          else {
            return nil
          }

          return ComposeAutocompleteItem(
            id: "thread-\(chat.id)",
            kind: .thread,
            title: title,
            subtitle: "Thread",
            symbol: "bubble.left",
            emoji: chat.emoji,
            payload: .thread(chatId: chat.id, spaceId: chat.spaceId, title: title)
          )
        }

        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = items
          self.selectedIndex = items.isEmpty ? 0 : min(self.selectedIndex, items.count - 1)
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = []
          self.selectedIndex = 0
          self.log.error("Failed to load thread autocomplete items", error: error)
        }
      }
    }
  }
}
