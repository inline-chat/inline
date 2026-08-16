import Combine
import Foundation
import Logger

public enum ComposeAutocompleteKind: String, Hashable, Sendable {
  case mention
  case command
  case thread
  case threadNumber
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
    case inlineCommand(InlineCommandDefinition)
    case thread(chatId: Int64, spaceId: Int64?, title: String)
    case externalResource(ExternalResourceReference)
    case emoji(value: String, shortcode: String)
  }

  public let id: String
  public let kind: ComposeAutocompleteKind
  public let title: String
  public let subtitle: String?
  public let symbol: String?
  public let emoji: String?
  public let avatarUserInfo: UserInfo?
  public let showsAppIcon: Bool
  public let threadReference: ThreadReference?
  public let payload: Payload

  public init(
    id: String,
    kind: ComposeAutocompleteKind,
    title: String,
    subtitle: String? = nil,
    symbol: String? = nil,
    emoji: String? = nil,
    avatarUserInfo: UserInfo? = nil,
    showsAppIcon: Bool = false,
    threadReference: ThreadReference? = nil,
    payload: Payload
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.emoji = emoji
    self.avatarUserInfo = avatarUserInfo
    self.showsAppIcon = showsAppIcon
    self.threadReference = threadReference
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

public typealias ComposeExternalResourceItemsProvider = @MainActor (
  _ query: String,
  _ limit: Int
) async throws -> [ExternalResourceReference]

@MainActor
public final class ComposeAutocompleteViewModel: ObservableObject {
  private enum ReferenceSource: String, Sendable {
    case all
    case inline
    case notion
    case linear

    var includesInline: Bool {
      self == .all || self == .inline
    }

    var includesNotion: Bool {
      self == .all || self == .notion
    }
  }

  private struct ReferenceQuery: Sendable {
    let source: ReferenceSource
    let query: String

    var searchesNotion: Bool {
      source.includesNotion && (source == .notion || !query.isEmpty)
    }
  }

  private struct CachedExternalResources {
    let resources: [ExternalResourceReference]
    let expiresAt: Date
  }

  private struct ThreadCandidate {
    let chatId: Int64
    let chat: Chat
    let snapshot: HomeChatListItemSnapshot
  }

  @Published public private(set) var match: ComposeAutocompleteMatch?
  @Published public private(set) var items: [ComposeAutocompleteItem] = []
  @Published public private(set) var selectedIndex = 0
  @Published public private(set) var loadState: ComposeAutocompleteLoadState = .idle

  private let log = Log.scoped("ComposeAutocompleteViewModel", enableTracing: true)
  private let db: AppDatabase
  private let limit: Int
  private let recentThreadChatIds: ComposeThreadRecentChatIdsProvider
  private let mentionItems: ComposeMentionAutocompleteItemsProvider
  private let commandItems: ComposeCommandAutocompleteItemsProvider
  private let emojiItems: ComposeEmojiAutocompleteItemsProvider
  private let externalResourceItems: ComposeExternalResourceItemsProvider
  private var spaceId: Int64?
  private var loadTask: Task<Void, Never>?
  private var loadToken = UUID()
  private var suppressedMatch: ComposeAutocompleteMatch?
  private let recentThreadLimit = 6
  private let searchedThreadLimit = 5
  private let externalResourceLimit = 6
  private let externalResourceCacheLimit = 20
  private let externalResourceCacheTTL: TimeInterval = 30
  private var externalResourceCache: [String: CachedExternalResources] = [:]
  private var externalResourceCacheOrder: [String] = []

  public init(
    db: AppDatabase = .shared,
    spaceId: Int64? = nil,
    limit: Int = 8,
    recentThreadChatIds: @escaping ComposeThreadRecentChatIdsProvider = { _ in [] },
    mentionItems: @escaping ComposeMentionAutocompleteItemsProvider = { _, _ in [] },
    commandItems: @escaping ComposeCommandAutocompleteItemsProvider = { _, _ in [] },
    emojiItems: @escaping ComposeEmojiAutocompleteItemsProvider = { _, _ in [] },
    externalResourceItems: @escaping ComposeExternalResourceItemsProvider = { _, _ in [] }
  ) {
    self.db = db
    self.spaceId = spaceId
    self.limit = limit
    self.recentThreadChatIds = recentThreadChatIds
    self.mentionItems = mentionItems
    self.commandItems = commandItems
    self.emojiItems = emojiItems
    self.externalResourceItems = externalResourceItems
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
    externalResourceCache.removeAll(keepingCapacity: true)
    externalResourceCacheOrder.removeAll(keepingCapacity: true)
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
      loadThreadItems(query: match.query, kind: .thread)
    case .threadNumber:
      loadThreadItems(query: match.query, kind: .threadNumber)
    case .emoji:
      loadSynchronousItems(emojiItems(match.query, limit))
    }
  }

  private func loadSynchronousItems(_ items: [ComposeAutocompleteItem]) {
    loadState = .idle
    self.items = items
    selectedIndex = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
  }

  private func loadThreadItems(query: String, kind: ComposeAutocompleteKind) {
    let referenceQuery = kind == .threadNumber
      ? ReferenceQuery(source: .inline, query: query)
      : Self.referenceQuery(from: query)
    log.debug(
      "event=reference_scope source=\(referenceQuery.source.rawValue) " +
        "query_length=\(referenceQuery.query.utf16.count) " +
        "includes_inline=\(referenceQuery.source.includesInline) " +
        "searches_notion=\(referenceQuery.searchesNotion) " +
        "recent=\(referenceQuery.query.isEmpty)"
    )

    if referenceQuery.source == .linear {
      log.debug("event=reference_scope_unavailable source=linear adapter_available=false")
      loadSynchronousItems([])
      return
    }

    if referenceQuery.query.isEmpty, referenceQuery.source != .notion {
      loadRecentThreadItems()
      return
    }

    let normalizedQuery = Self.normalizedExternalResourceQuery(referenceQuery.query)
    let cachedResources: [ExternalResourceReference]?
    if referenceQuery.searchesNotion {
      cachedResources = cachedExternalResources(for: normalizedQuery)
    } else {
      cachedResources = []
    }
    if referenceQuery.searchesNotion, let cachedResources {
      log.trace(
        "event=external_resource_cache_hit provider=notion " +
          "query_length=\(referenceQuery.query.utf16.count) " +
          "result_count=\(cachedResources.count)"
      )
    }
    let preferredChatIds = referenceQuery.source.includesInline
      ? recentThreadChatIds(recentThreadLimit)
      : []
    let token = UUID()
    loadToken = token
    loadState = .loading
    let logger = log

    loadTask = Task { [db, limit, searchedThreadLimit, externalResourceLimit, externalResourceItems, logger] in
      do {
        // Avoid issuing a local database search for every intermediate keystroke.
        // The presentation layer keeps the current menu stable during this short debounce.
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        let threadItems: [ComposeAutocompleteItem]
        if referenceQuery.source.includesInline {
          let snapshots = try await db.fetchCommandBarChatCatalogSnapshots()
          threadItems = Self.threadItems(
            from: snapshots,
            preferredChatIds: preferredChatIds,
            query: referenceQuery.query,
            limit: min(searchedThreadLimit, limit),
            kind: kind
          )
        } else {
          threadItems = []
        }

        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.items = Self.referenceItems(
            threads: threadItems,
            externalResources: Self.externalResources(
              cachedResources ?? [],
              for: referenceQuery.source
            ),
            limit: limit
          )
          self.selectedIndex = self.items.isEmpty ? 0 : min(self.selectedIndex, self.items.count - 1)
          self.loadState = cachedResources == nil && self.items.isEmpty ? .loading : .idle
          logger.trace(
            "event=reference_local_phase source=\(referenceQuery.source.rawValue) " +
              "thread_count=\(threadItems.count) " +
              "visible_count=\(self.items.count)"
          )
        }

        guard kind == .thread, cachedResources == nil else { return }

        // Give local results priority and avoid a provider request for every
        // intermediate keystroke while the user is still typing.
        try await Task.sleep(for: .milliseconds(140))
        try Task.checkCancellation()
        logger.debug(
          "event=external_resource_request provider=notion " +
            "query_length=\(referenceQuery.query.utf16.count) " +
            "recent=\(referenceQuery.query.isEmpty) limit=\(externalResourceLimit)"
        )
        let resources = try await externalResourceItems(referenceQuery.query, externalResourceLimit)
        let scopedResources = Self.externalResources(resources, for: referenceQuery.source)

        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.cacheExternalResources(resources, for: normalizedQuery)
          self.items = Self.referenceItems(
            threads: threadItems,
            externalResources: scopedResources,
            limit: limit
          )
          self.selectedIndex = self.items.isEmpty ? 0 : min(self.selectedIndex, self.items.count - 1)
          self.loadState = .idle
          logger.debug(
            "event=external_resource_published provider=notion " +
              "resource_count=\(resources.count) scoped_count=\(scopedResources.count) " +
              "thread_count=\(threadItems.count) " +
              "visible_count=\(self.items.count)"
          )
        }
      } catch is CancellationError {
        logger.trace("event=external_resource_cancelled source=\(referenceQuery.source.rawValue)")
        return
      } catch {
        await MainActor.run { [weak self] in
          guard let self, self.loadToken == token else { return }
          self.loadState = self.items.isEmpty ? .failed : .idle
          self.log.error("Failed to load reference autocomplete items", error: error)
        }
      }
    }
  }

  private func loadRecentThreadItems() {
    let preferredChatIds = recentThreadChatIds(recentThreadLimit)

    let token = UUID()
    loadToken = token
    loadState = .loading

    loadTask = Task { [db, limit, recentThreadLimit] in
      do {
        let snapshots = try await db.fetchCommandBarChatCatalogSnapshots()
        let items = Self.threadItems(
          from: snapshots,
          preferredChatIds: preferredChatIds,
          query: nil,
          limit: min(recentThreadLimit, limit),
          kind: .thread
        )

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

  private static func threadItems(
    from snapshots: [HomeChatListItemSnapshot],
    preferredChatIds: [Int64],
    query: String?,
    limit: Int,
    kind: ComposeAutocompleteKind
  ) -> [ComposeAutocompleteItem] {
    guard limit > 0 else { return [] }

    let normalizedQuery = query.map(HomeChatListItemSnapshot.normalizedSearchText) ?? ""
    let compactQuery = compactWhitespace(normalizedQuery)
    var candidates = snapshots.compactMap { snapshot -> ThreadCandidate? in
      guard !snapshot.archived,
            let chatId = snapshot.peerId.asThreadId(),
            let chat = snapshot.item.chat,
            chat.type == .thread,
            kind != .threadNumber || chat.threadReference != nil,
            !snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        return nil
      }

      if kind == .threadNumber {
        guard let number = chat.number,
              String(number).hasPrefix(normalizedQuery)
        else {
          return nil
        }
      } else if !normalizedQuery.isEmpty {
        let searchText = snapshot.searchText
        guard searchText.contains(normalizedQuery)
          || compactWhitespace(searchText).contains(compactQuery)
        else {
          return nil
        }
      }

      return ThreadCandidate(chatId: chatId, chat: chat, snapshot: snapshot)
    }

    var preferredRank: [Int64: Int] = [:]
    for (index, chatId) in preferredChatIds.enumerated() where preferredRank[chatId] == nil {
      preferredRank[chatId] = index
    }

    candidates.sort { lhs, rhs in
      if kind == .threadNumber, !normalizedQuery.isEmpty {
        let lhsIsExact = lhs.chat.number.map(String.init) == normalizedQuery
        let rhsIsExact = rhs.chat.number.map(String.init) == normalizedQuery
        if lhsIsExact != rhsIsExact { return lhsIsExact }
      }

      switch (preferredRank[lhs.chatId], preferredRank[rhs.chatId]) {
      case let (lhsRank?, rhsRank?) where lhsRank != rhsRank:
        return lhsRank < rhsRank
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        break
      }

      let lhsDate = lhs.snapshot.item.dialog.openedDate ?? lhs.snapshot.sortDate
      let rhsDate = rhs.snapshot.item.dialog.openedDate ?? rhs.snapshot.sortDate
      if lhsDate != rhsDate { return lhsDate > rhsDate }
      if lhs.snapshot.sortDate != rhs.snapshot.sortDate {
        return lhs.snapshot.sortDate > rhs.snapshot.sortDate
      }
      return lhs.chatId > rhs.chatId
    }

    return candidates.prefix(limit).map { candidate in
      let snapshot = candidate.snapshot
      let chat = candidate.chat
      let title = snapshot.title
      let spaceId = snapshot.item.dialog.spaceId ?? chat.spaceId
      let subtitle = [
        snapshot.parentTitle ?? snapshot.spaceTitle ?? "Thread",
        chat.threadReferenceLabel,
      ]
      .compactMap { $0 }
      .joined(separator: " • ")
      return ComposeAutocompleteItem(
        id: "thread-\(candidate.chatId)",
        kind: kind,
        title: title,
        subtitle: subtitle,
        emoji: chat.emoji,
        threadReference: chat.threadReference,
        payload: .thread(chatId: candidate.chatId, spaceId: spaceId, title: title)
      )
    }
  }

  private static func compactWhitespace(_ value: String) -> String {
    let scalars = value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
    return String(String.UnicodeScalarView(scalars))
  }

  private func cacheExternalResources(_ resources: [ExternalResourceReference], for key: String) {
    externalResourceCache[key] = CachedExternalResources(
      resources: resources,
      expiresAt: Date().addingTimeInterval(externalResourceCacheTTL)
    )
    externalResourceCacheOrder.removeAll { $0 == key }
    externalResourceCacheOrder.append(key)

    while externalResourceCacheOrder.count > externalResourceCacheLimit {
      let oldestKey = externalResourceCacheOrder.removeFirst()
      externalResourceCache.removeValue(forKey: oldestKey)
    }
  }

  private func cachedExternalResources(for key: String) -> [ExternalResourceReference]? {
    guard let entry = externalResourceCache[key] else { return nil }
    guard entry.expiresAt > Date() else {
      externalResourceCache.removeValue(forKey: key)
      externalResourceCacheOrder.removeAll { $0 == key }
      return nil
    }
    externalResourceCacheOrder.removeAll { $0 == key }
    externalResourceCacheOrder.append(key)
    return entry.resources
  }

  private static func referenceItems(
    threads: [ComposeAutocompleteItem],
    externalResources: [ExternalResourceReference],
    limit: Int
  ) -> [ComposeAutocompleteItem] {
    let resources = externalResources.map { resource in
      ComposeAutocompleteItem(
        id: "external-\(resource.provider.rawValue)-\(resource.id)",
        kind: .thread,
        title: resource.title,
        subtitle: resource.subtitle,
        symbol: "doc.text",
        emoji: resource.emoji,
        payload: .externalResource(resource)
      )
    }
    return Array((threads + resources).prefix(limit))
  }

  private static func externalResources(
    _ resources: [ExternalResourceReference],
    for source: ReferenceSource
  ) -> [ExternalResourceReference] {
    source == .notion
      ? resources.filter { $0.provider == .notion }
      : resources
  }

  private static func normalizedExternalResourceQuery(_ value: String) -> String {
    value
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .lowercased()
  }

  private static func referenceQuery(from value: String) -> ReferenceQuery {
    let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let hashtagQuery = trimmedValue.dropFirst()
    if trimmedValue.first == "#", !hashtagQuery.isEmpty, hashtagQuery.allSatisfy(\.isNumber) {
      return ReferenceQuery(source: .inline, query: trimmedValue)
    }

    guard let slashIndex = trimmedValue.firstIndex(of: "/") else {
      return ReferenceQuery(source: .all, query: trimmedValue)
    }

    let prefix = trimmedValue[..<slashIndex]
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let queryStart = trimmedValue.index(after: slashIndex)
    let scopedQuery = trimmedValue[queryStart...]
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch prefix {
    case "inline":
      return ReferenceQuery(source: .inline, query: scopedQuery)
    case "notion":
      return ReferenceQuery(source: .notion, query: scopedQuery)
    case "linear":
      return ReferenceQuery(source: .linear, query: scopedQuery)
    default:
      return ReferenceQuery(source: .all, query: trimmedValue)
    }
  }

}
