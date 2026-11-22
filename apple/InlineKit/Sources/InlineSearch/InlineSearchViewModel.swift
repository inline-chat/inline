import Foundation
import InlineKit
import Logger
import Observation

@MainActor
@Observable
public final class InlineSearchViewModel {
  public private(set) var query = ""
  public private(set) var chats: [InlineSearchChatResult] = []
  public private(set) var messages: [InlineSearchMessageResult] = []
  public private(set) var globalUsers: [InlineSearchGlobalUserResult] = []
  public private(set) var hasMoreMessages = false
  public private(set) var isSearchingLocal = false
  public private(set) var isSearchingGlobal = false
  public private(set) var isSearchingCloudMessages = false
  public private(set) var isLoadingMoreMessages = false
  /// The account-wide search couldn't be reached, so messages are this device's only.
  public private(set) var cloudMessagesUnavailable = false
  /// Some history isn't indexed yet, so older matches can be missing.
  public private(set) var messagesIndexIncomplete = false
  public private(set) var errorText: String?

  public var isSearching: Bool {
    isSearchingLocal || isSearchingGlobal || isSearchingCloudMessages || isLoadingMoreMessages
  }

  public var hasResults: Bool {
    chats.isEmpty == false || messages.isEmpty == false || globalUsers.isEmpty == false
  }

  @ObservationIgnored private let engine: InlineSearchEngine
  @ObservationIgnored private let cloudClient: (any InlineCloudMessageSearching)?
  @ObservationIgnored private let limits: InlineSearchLimits
  @ObservationIgnored private var scope: InlineSearchScope
  @ObservationIgnored private var searchToken: UInt64 = 0
  // Internal read access lets integration tests await actual completion,
  // including stale requests, without adding sleeps or replacing the engine.
  @ObservationIgnored private(set) var localTask: Task<Void, Never>?
  @ObservationIgnored private(set) var globalTask: Task<Void, Never>?
  @ObservationIgnored private(set) var cloudTask: Task<Void, Never>?
  @ObservationIgnored private(set) var moreMessagesTask: Task<Void, Never>?
  @ObservationIgnored private var localErrorText: String?
  @ObservationIgnored private var globalErrorText: String?
  @ObservationIgnored private var localMessages: [LocalMessageSearchResult] = []
  @ObservationIgnored private var localHasMoreMessages = false
  /// Nil until the server answers this query; local results show meanwhile.
  @ObservationIgnored private var cloudMessages: [CloudMessageSearchResult]?
  @ObservationIgnored private var cloudCursor: String?
  @ObservationIgnored private let log = Log.scoped("InlineSearchViewModel")

  /// `cloudClient` adds account-wide message hits; without one, messages are local only.
  public init(
    db: AppDatabase,
    scope: InlineSearchScope = InlineSearchScope(),
    limits: InlineSearchLimits = InlineSearchLimits(),
    globalClient: any InlineGlobalUserSearching = InlineApiGlobalUserSearchClient(),
    cloudClient: (any InlineCloudMessageSearching)? = nil
  ) {
    self.scope = scope
    self.limits = limits
    self.cloudClient = cloudClient
    engine = InlineSearchEngine(db: db, globalClient: globalClient)
  }

  deinit {
    localTask?.cancel()
    globalTask?.cancel()
    cloudTask?.cancel()
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
    cloudTask?.cancel()
    moreMessagesTask?.cancel()
    isLoadingMoreMessages = false
    errorText = nil
    localErrorText = nil
    globalErrorText = nil
    cloudMessages = nil
    cloudCursor = nil
    cloudMessagesUnavailable = false
    messagesIndexIncomplete = false

    guard InlineSearchRanker.prepare(trimmed) != nil else {
      clearResults()
      return
    }

    isSearchingLocal = true
    isSearchingGlobal = scope.includeGlobalUsers && InlineSearchRanker.compact(trimmed).count >= 2
    isSearchingCloudMessages = cloudClient != nil && LocalMessageSearch.isSearchable(trimmed)

    let searchScope = scope
    localTask = Task { [engine, limits] in
      let payload = await engine.searchLocal(query: trimmed, scope: searchScope, limits: limits)
      guard !Task.isCancelled else { return }
      guard searchToken == token else { return }

      chats = payload.chats
      localMessages = payload.messages
      localHasMoreMessages = payload.hasMoreMessages
      publishMessages()
      isSearchingLocal = false
      localErrorText = payload.errorText
      updateErrorText()
      dedupeGlobalUsers()
    }

    searchCloudMessages(query: trimmed, scope: searchScope, token: token)

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

  public func refresh() {
    guard query.isEmpty == false else { return }
    search(query, scope: scope)
  }

  public func loadMoreMessages() {
    guard isSearchingLocal == false else { return }
    guard hasMoreMessages else { return }
    guard isLoadingMoreMessages == false else { return }
    guard LocalMessageSearch.isSearchable(query) else { return }

    moreMessagesTask?.cancel()
    isLoadingMoreMessages = true
    localErrorText = nil
    updateErrorText()

    let token = searchToken
    let searchQuery = query
    let searchScope = scope

    // Once the server has answered, it pages; local hits stay as the first page found them.
    if cloudMessages != nil, let cursor = cloudCursor, let cloudClient {
      moreMessagesTask = Task {
        do {
          let page = try await cloudClient.searchMessages(
            query: searchQuery,
            scope: searchScope.cloudMessageScope,
            cursor: cursor
          )
          guard !Task.isCancelled, searchToken == token else { return }
          cloudMessages = (cloudMessages ?? []) + page.results
          cloudCursor = page.nextCursor
          messagesIndexIncomplete = messagesIndexIncomplete || page.indexIncomplete
        } catch {
          guard !Task.isCancelled, searchToken == token else { return }
          log.error("Couldn't load more account-wide message results", error: error)
          cloudCursor = nil
        }
        publishMessages()
        isLoadingMoreMessages = false
      }
      return
    }

    let offset = localMessages.count
    moreMessagesTask = Task { [engine, limits] in
      let page = await engine.searchMoreMessages(
        query: searchQuery,
        scope: searchScope,
        offset: offset,
        limit: limits.messageBatchSize
      )

      guard !Task.isCancelled else { return }
      guard searchToken == token else { return }

      appendLocalMessages(page.results)
      localHasMoreMessages = page.hasMore
      publishMessages()
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
    cloudTask?.cancel()
    moreMessagesTask?.cancel()
    clearResults()
  }

  private func searchCloudMessages(query: String, scope: InlineSearchScope, token: UInt64) {
    guard isSearchingCloudMessages, let cloudClient else { return }
    cloudTask = Task { [limits] in
      // Waits out typing; the server also drops an older query from this session.
      if limits.globalDebounceNanoseconds > 0 {
        try? await Task.sleep(nanoseconds: limits.globalDebounceNanoseconds)
      }
      guard !Task.isCancelled else { return }
      do {
        let page = try await cloudClient.searchMessages(
          query: query,
          scope: scope.cloudMessageScope,
          cursor: nil
        )
        guard !Task.isCancelled, searchToken == token else { return }
        cloudMessages = page.results
        cloudCursor = page.nextCursor
        messagesIndexIncomplete = page.indexIncomplete
      } catch {
        guard !Task.isCancelled, searchToken == token else { return }
        log.error("Account-wide message search failed; showing this device's messages", error: error)
        cloudMessagesUnavailable = true
      }
      publishMessages()
      isSearchingCloudMessages = false
    }
  }

  private func publishMessages() {
    messages = InlineSearchMessageResult.merge(
      cloud: cloudMessages,
      local: localMessages,
      cloudHasMore: cloudCursor != nil,
      indexIncomplete: messagesIndexIncomplete
    )
    hasMoreMessages = cloudMessages != nil ? cloudCursor != nil : localHasMoreMessages
  }

  private func clearResults() {
    chats = []
    messages = []
    globalUsers = []
    localMessages = []
    localHasMoreMessages = false
    cloudMessages = nil
    cloudCursor = nil
    hasMoreMessages = false
    isSearchingLocal = false
    isSearchingGlobal = false
    isSearchingCloudMessages = false
    isLoadingMoreMessages = false
    cloudMessagesUnavailable = false
    messagesIndexIncomplete = false
    localErrorText = nil
    globalErrorText = nil
    errorText = nil
  }

  private func appendLocalMessages(_ newMessages: [LocalMessageSearchResult]) {
    guard newMessages.isEmpty == false else { return }

    var seen = Set(localMessages.map(\.id))
    let unique = newMessages.filter { seen.insert($0.id).inserted }
    guard unique.isEmpty == false else { return }

    localMessages.append(contentsOf: unique)
  }

  private func dedupeGlobalUsers() {
    // Retained chat rows belong to the previous query until local search finishes.
    guard isSearchingLocal == false else { return }
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
