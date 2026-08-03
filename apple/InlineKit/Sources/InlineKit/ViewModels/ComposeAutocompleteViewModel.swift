import Combine
import Foundation
import GRDB
import Logger

public enum ComposeAutocompleteKind: String, Hashable, Sendable {
  case mention
  case command
  case thread
  case emoji
}

public enum ComposeAutocompleteLoadState: Equatable, Sendable {
  case idle
  case loading
  case failed
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
    case mention(MentionCompletionItem)
    case command(PeerBotCommandSuggestion)
    case thread(chatId: Int64, spaceId: Int64?, title: String)
    case emoji(value: String, shortcode: String)
  }

  public let id: String
  public let kind: ComposeAutocompleteKind
  public let title: String
  public let subtitle: String?
  public let symbol: String?
  public let emoji: String?
  public let avatarUserInfo: UserInfo?
  public let payload: Payload

  public init(
    id: String,
    kind: ComposeAutocompleteKind,
    title: String,
    subtitle: String? = nil,
    symbol: String? = nil,
    emoji: String? = nil,
    avatarUserInfo: UserInfo? = nil,
    payload: Payload
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.emoji = emoji
    self.avatarUserInfo = avatarUserInfo
    self.payload = payload
  }
}

public typealias ComposeMentionAutocompleteItemsProvider = @MainActor (
  _ query: String,
  _ limit: Int
) -> [ComposeAutocompleteItem]

public typealias ComposeCommandAutocompleteItemsProvider = @MainActor (
  _ query: String,
  _ limit: Int
) -> [ComposeAutocompleteItem]

public typealias ComposeEmojiAutocompleteItemsProvider = @MainActor (
  _ query: String,
  _ limit: Int
) -> [ComposeAutocompleteItem]

public typealias ComposeThreadRecentChatIdsProvider = @MainActor (
  _ limit: Int
) -> [Int64]

@MainActor
public final class ComposeAutocompleteViewModel: ObservableObject {
  @Published public private(set) var match: ComposeAutocompleteMatch?
  @Published public private(set) var items: [ComposeAutocompleteItem] = []
  @Published public private(set) var selectedIndex = 0
  @Published public private(set) var loadState: ComposeAutocompleteLoadState = .idle

  private let log = Log.scoped("ComposeAutocompleteViewModel")
  private let db: AppDatabase
  private let limit: Int
  private let recentThreadChatIds: ComposeThreadRecentChatIdsProvider
  private let mentionItems: ComposeMentionAutocompleteItemsProvider
  private let commandItems: ComposeCommandAutocompleteItemsProvider
  private let emojiItems: ComposeEmojiAutocompleteItemsProvider
  private var spaceId: Int64?
  private var loadTask: Task<Void, Never>?
  private var loadToken = UUID()
  private var suppressedMatch: ComposeAutocompleteMatch?
  private let recentThreadLimit = 5

  public init(
    db: AppDatabase = .shared,
    spaceId: Int64? = nil,
    limit: Int = 8,
    recentThreadChatIds: @escaping ComposeThreadRecentChatIdsProvider = { _ in [] },
    mentionItems: @escaping ComposeMentionAutocompleteItemsProvider = { _, _ in [] },
    commandItems: @escaping ComposeCommandAutocompleteItemsProvider = { _, _ in [] },
    emojiItems: @escaping ComposeEmojiAutocompleteItemsProvider = { _, _ in [] }
  ) {
    self.db = db
    self.spaceId = spaceId
    self.limit = limit
    self.recentThreadChatIds = recentThreadChatIds
    self.mentionItems = mentionItems
    self.commandItems = commandItems
    self.emojiItems = emojiItems
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
    if let match, match == suppressedMatch {
      loadTask?.cancel()
      loadToken = UUID()
      self.match = nil
      items = []
      selectedIndex = 0
      loadState = .idle
      return
    }

    if match != suppressedMatch {
      suppressedMatch = nil
    }

    guard self.match != match else { return }
    loadTask?.cancel()
    loadToken = UUID()
    items = []
    selectedIndex = 0
    loadState = .idle
    self.match = match
    reloadItems()
  }

  public func hide(suppressCurrentMatch: Bool = false) {
    if suppressCurrentMatch {
      suppressedMatch = match
    } else {
      suppressedMatch = nil
    }

    loadTask?.cancel()
    loadToken = UUID()
    match = nil
    items = []
    selectedIndex = 0
    loadState = .idle
  }

  public func selectNext() {
    guard items.isEmpty == false else { return }
    selectedIndex = (selectedIndex + 1) % items.count
  }

  public func selectPrevious() {
    guard items.isEmpty == false else { return }
    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : items.count - 1
  }

  public func reloadCurrentMatch() {
    reloadItems()
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
      loadState = .idle
      return
    }

    switch match.kind {
    case .mention:
      loadSynchronousItems(mentionItems(match.query, limit))
    case .command:
      loadSynchronousItems(commandItems(match.query, limit))
    case .thread:
      loadThreadItems(query: match.query)
    case .emoji:
      loadSynchronousItems(emojiItems(match.query, limit))
    }
  }

  private func loadSynchronousItems(_ items: [ComposeAutocompleteItem]) {
    loadState = .idle
    self.items = items
    selectedIndex = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
  }

  private func loadThreadItems(query: String) {
    guard !query.isEmpty else {
      loadRecentThreadItems()
      return
    }

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      loadRecentThreadItems()
      return
    }

    let compactQuery = Self.compactWhitespace(trimmedQuery)
    let titlePattern = Self.likePattern(containing: trimmedQuery)
    let compactTitlePattern = Self.likePattern(containing: compactQuery)
    let token = UUID()
    loadToken = token
    loadState = .loading

    loadTask = Task { [db, limit] in
      do {
        // Avoid issuing a local database search for every intermediate keystroke.
        // The presentation layer keeps the current menu stable during this short debounce.
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        let items = try await db.reader.read { db in
          let compactTitleSQL = """
          replace(replace(replace(replace(title, ' ', ''), char(9), ''), char(10), ''), char(13), '')
          """
          let request = Chat
            .filter(Chat.Columns.type == ChatType.thread.rawValue)
            .filter(Chat.Columns.parentMessageId == nil)
            .filter(
              sql: "(title COLLATE NOCASE LIKE ? ESCAPE '\\' OR \(compactTitleSQL) COLLATE NOCASE LIKE ? ESCAPE '\\')",
              arguments: StatementArguments([titlePattern, compactTitlePattern])
            )

          let chats = try request
            .order(Chat.Columns.date.desc)
            .limit(limit)
            .fetchAll(db)

          var spaceNames: [Int64: String] = [:]
          for spaceId in Set(chats.compactMap(\.spaceId)) {
            if let space = try Space.fetchOne(db, id: spaceId) {
              spaceNames[spaceId] = space.displayName
            }
          }

          return chats.compactMap { chat -> ComposeAutocompleteItem? in
            guard let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else {
              return nil
            }

            let subtitle = chat.spaceId.flatMap { spaceNames[$0] } ?? "Thread"
            return ComposeAutocompleteItem(
              id: "thread-\(chat.id)",
              kind: .thread,
              title: title,
              subtitle: subtitle,
              emoji: chat.emoji,
              payload: .thread(chatId: chat.id, spaceId: chat.spaceId, title: title)
            )
          }
        }

        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = items
          self.selectedIndex = items.isEmpty ? 0 : min(self.selectedIndex, items.count - 1)
          self.loadState = .idle
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = []
          self.selectedIndex = 0
          self.loadState = .failed
          self.log.error("Failed to load thread autocomplete items", error: error)
        }
      }
    }
  }

  private func loadRecentThreadItems() {
    let chatIds = recentThreadChatIds(recentThreadLimit)
    guard !chatIds.isEmpty else {
      items = []
      selectedIndex = 0
      loadState = .idle
      return
    }

    let token = UUID()
    loadToken = token
    loadState = .loading

    loadTask = Task { [db] in
      do {
        let items = try await db.reader.read { db in
          var items: [ComposeAutocompleteItem] = []
          var spaceNames: [Int64: String] = [:]

          for chatId in chatIds {
            guard let chat = try Chat.fetchOne(db, id: chatId),
                  chat.type == .thread,
                  chat.parentMessageId == nil,
                  let title = chat.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty
            else {
              continue
            }

            let subtitle: String
            if let spaceId = chat.spaceId {
              if spaceNames[spaceId] == nil, let space = try Space.fetchOne(db, id: spaceId) {
                spaceNames[spaceId] = space.displayName
              }
              subtitle = spaceNames[spaceId] ?? "Thread"
            } else {
              subtitle = "Thread"
            }

            items.append(
              ComposeAutocompleteItem(
                id: "thread-\(chat.id)",
                kind: .thread,
                title: title,
                subtitle: subtitle,
                emoji: chat.emoji,
                payload: .thread(chatId: chat.id, spaceId: chat.spaceId, title: title)
              )
            )
          }

          return items
        }

        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = items
          self.selectedIndex = items.isEmpty ? 0 : min(self.selectedIndex, items.count - 1)
          self.loadState = .idle
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = []
          self.selectedIndex = 0
          self.loadState = .failed
          self.log.error("Failed to load recent thread autocomplete items", error: error)
        }
      }
    }
  }

  private static func compactWhitespace(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
    return String(String.UnicodeScalarView(scalars))
  }

  private static func likePattern(containing value: String) -> String {
    var pattern = "%"
    for character in value {
      if character == "\\" || character == "%" || character == "_" {
        pattern.append("\\")
      }
      pattern.append(character)
    }
    pattern.append("%")
    return pattern
  }
}
