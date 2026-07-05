import Foundation
import InlineKit
import Observation

@MainActor
@Observable
public final class InlineSearchViewModel {
  public private(set) var query = ""
  public private(set) var chats: [InlineSearchChatResult] = []
  public private(set) var messages: [LocalMessageSearchResult] = []
  public private(set) var globalUsers: [InlineSearchGlobalUserResult] = []
  public private(set) var hasMoreMessages = false
  public private(set) var isSearchingLocal = false
  public private(set) var isSearchingGlobal = false
  public private(set) var isLoadingMoreMessages = false
  public private(set) var errorText: String?

  public var isSearching: Bool {
    isSearchingLocal || isSearchingGlobal || isLoadingMoreMessages
  }

  public var hasResults: Bool {
    chats.isEmpty == false || messages.isEmpty == false || globalUsers.isEmpty == false
  }

  @ObservationIgnored private let engine: InlineSearchEngine
  @ObservationIgnored private let limits: InlineSearchLimits
  @ObservationIgnored private var scope: InlineSearchScope
  @ObservationIgnored private var searchToken: UInt64 = 0
  @ObservationIgnored private var localTask: Task<Void, Never>?
  @ObservationIgnored private var globalTask: Task<Void, Never>?
  @ObservationIgnored private var moreMessagesTask: Task<Void, Never>?
  @ObservationIgnored private var localErrorText: String?
  @ObservationIgnored private var globalErrorText: String?

  public init(
    db: AppDatabase,
    scope: InlineSearchScope = InlineSearchScope(),
    limits: InlineSearchLimits = InlineSearchLimits(),
    globalClient: any InlineGlobalUserSearching = InlineApiGlobalUserSearchClient()
  ) {
    self.scope = scope
    self.limits = limits
    engine = InlineSearchEngine(db: db, globalClient: globalClient)
  }

  deinit {
    localTask?.cancel()
    globalTask?.cancel()
    moreMessagesTask?.cancel()
  }

  public func search(_ query: String, scope newScope: InlineSearchScope? = nil) {
    if let newScope {
      scope = newScope
    }

    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard self.query != trimmed || newScope != nil else { return }

    self.query = trimmed
    searchToken &+= 1
    let token = searchToken

    localTask?.cancel()
    globalTask?.cancel()
    moreMessagesTask?.cancel()
    isLoadingMoreMessages = false
    errorText = nil
    localErrorText = nil
    globalErrorText = nil

    guard InlineSearchRanker.prepare(trimmed) != nil else {
      clearResults()
      return
    }

    isSearchingLocal = true
    isSearchingGlobal = scope.includeGlobalUsers && InlineSearchRanker.compact(trimmed).count >= 2

    let searchScope = scope
    localTask = Task { [engine, limits] in
      let payload = await engine.searchLocal(query: trimmed, scope: searchScope, limits: limits)
      guard !Task.isCancelled else { return }
      guard searchToken == token else { return }

      chats = payload.chats
      messages = payload.messages
      hasMoreMessages = payload.hasMoreMessages
      isSearchingLocal = false
      localErrorText = payload.errorText
      updateErrorText()
      dedupeGlobalUsers()
    }

    guard isSearchingGlobal else {
      globalUsers = []
      return
    }

    globalTask = Task { [engine, limits] in
      if limits.globalDebounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: limits.globalDebounceNanoseconds)
      }
      guard !Task.isCancelled else { return }

      do {
        let users = try await engine.searchGlobalUsers(
          query: trimmed,
          scope: searchScope,
          limit: limits.globalUserLimit
        )
        guard !Task.isCancelled else { return }
        guard searchToken == token else { return }

        globalUsers = users
        dedupeGlobalUsers()
        isSearchingGlobal = false
        globalErrorText = nil
        updateErrorText()
      } catch {
        guard !Task.isCancelled else { return }
        guard searchToken == token else { return }

        globalUsers = []
        isSearchingGlobal = false
        globalErrorText = "Global users: \(error.localizedDescription)"
        updateErrorText()
      }
    }
  }

  public func updateScope(_ scope: InlineSearchScope) {
    guard self.scope != scope else { return }
    search(query, scope: scope)
  }

  public func loadMoreMessages() {
    guard hasMoreMessages else { return }
    guard isLoadingMoreMessages == false else { return }
    guard LocalMessageSearch.isSearchable(query) else { return }

    moreMessagesTask?.cancel()
    isLoadingMoreMessages = true
    localErrorText = nil
    updateErrorText()

    let token = searchToken
    let searchQuery = query
    let offset = messages.count
    let searchScope = scope

    moreMessagesTask = Task { [engine, limits] in
      let page = await engine.searchMoreMessages(
        query: searchQuery,
        scope: searchScope,
        offset: offset,
        limit: limits.messageBatchSize
      )

      guard !Task.isCancelled else { return }
      guard searchToken == token else { return }

      appendMessages(page.results)
      hasMoreMessages = page.hasMore
      isLoadingMoreMessages = false
      localErrorText = page.errorText
      updateErrorText()
    }
  }

  public func clear() {
    searchToken &+= 1
    query = ""
    localTask?.cancel()
    globalTask?.cancel()
    moreMessagesTask?.cancel()
    clearResults()
  }

  private func clearResults() {
    chats = []
    messages = []
    globalUsers = []
    hasMoreMessages = false
    isSearchingLocal = false
    isSearchingGlobal = false
    isLoadingMoreMessages = false
    localErrorText = nil
    globalErrorText = nil
    errorText = nil
  }

  private func appendMessages(_ newMessages: [LocalMessageSearchResult]) {
    guard newMessages.isEmpty == false else { return }

    var seen = Set(messages.map(\.id))
    let unique = newMessages.filter { seen.insert($0.id).inserted }
    guard unique.isEmpty == false else { return }

    messages.append(contentsOf: unique)
  }

  private func dedupeGlobalUsers() {
    let localUserIds = Set(chats.compactMap { result -> Int64? in
      if case let .user(id) = result.peer {
        return id
      }
      return nil
    })

    guard localUserIds.isEmpty == false else { return }
    globalUsers = globalUsers.filter { !localUserIds.contains($0.id) }
  }

  private func updateErrorText() {
    let values = [localErrorText, globalErrorText]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
    errorText = values.isEmpty ? nil : values.joined(separator: "\n")
  }
}
