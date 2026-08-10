import AppKit
import GRDB
import InlineKit
import InlineMacUI
import InlineSearch
import InlineUI
import Logger
import Observation
import SwiftUI
import os.signpost

enum QuickSearchLayout {
  static let defaultWidth: CGFloat = 510
  static let maximumWidth: CGFloat = 510
  static let rowHeight: CGFloat = Theme.sidebarItemHeight
  static let rowSpacing: CGFloat = 1
  static let rowInnerPadding: CGFloat = 4
  static let sectionHeaderHeight: CGFloat = 22
  static let sectionSpacing: CGFloat = 8
  static let searchBarHeight: CGFloat = 36
  static let contentHorizontalPadding: CGFloat = 10
  static let contentVerticalPadding: CGFloat = 10
  static let searchHeaderVerticalPadding: CGFloat = 6
  static let searchHeaderHeight: CGFloat = searchBarHeight + (searchHeaderVerticalPadding * 2)
  static let listContentHorizontalInset: CGFloat = contentHorizontalPadding
  static let listContentTopInset: CGFloat = contentVerticalPadding
  static let listContentBottomInset: CGFloat = contentVerticalPadding
  static let separatorHeight: CGFloat = 1
  static let searchBarTextInset: CGFloat = 6
  static let cornerRadius: CGFloat = 14
  static let iconSize: CGFloat = 24
  static let iconContainerSize: CGFloat = 28
  static let iconTextSpacing: CGFloat = Theme.sidebarIconSpacing
  static let itemTextSpacing: CGFloat = 6
}

fileprivate enum QuickSearchLocalItem: Identifiable, Hashable {
  case chat(InlineSearchChatResult)
  case space(Space)
  case command(QuickSearchCommand)
  case registeredCommand(CommandBarItem)
  case createThread(title: String, spaceId: Int64, spaceName: String?)
  case message(LocalMessageSearchResult)

  var id: String {
    switch self {
      case let .chat(result):
        result.id
      case let .space(space):
        "space-\(space.id)"
      case let .command(command):
        "command-\(command.id)"
      case let .registeredCommand(item):
        "registered-command-\(item.id)"
      case let .createThread(title, spaceId, _):
        "create-thread-\(spaceId)-\(title.lowercased())"
      case let .message(result):
        result.id
    }
  }
}

fileprivate struct QuickSearchLocalSection: Identifiable, Hashable {
  enum Kind: String, Hashable {
    case suggestions
    case chats
    case spaces
    case commands

    var title: String {
      switch self {
        case .suggestions: "Suggestions"
        case .chats: "Chats"
        case .spaces: "Spaces"
        case .commands: "Commands"
      }
    }
  }

  let kind: Kind
  let items: [QuickSearchLocalItem]

  var id: Kind { kind }
}

fileprivate struct QuickSearchRenderSnapshot {
  static let empty = QuickSearchRenderSnapshot(
    query: "",
    localSections: [],
    localResults: [],
    messageResults: [],
    globalResults: [],
    isLoading: false,
    errorDescription: nil
  )

  let query: String
  let localSections: [QuickSearchLocalSection]
  let localResults: [QuickSearchLocalItem]
  let messageResults: [QuickSearchLocalItem]
  let globalResults: [GlobalSearchResult]
  let isLoading: Bool
  let errorDescription: String?

  var resultIDs: [String] {
    localResults.map(\.id) +
      messageResults.map(\.id) +
      globalResults.map { "global-\($0.id)" }
  }

}

fileprivate struct QuickSearchCommandContext: Equatable {
  var activePeer: Peer?
  var selectedSpaceId: Int64?
  var hasSelectedMessage: Bool

  init(activePeer: Peer? = nil, selectedSpaceId: Int64? = nil, hasSelectedMessage: Bool = false) {
    self.activePeer = activePeer
    self.selectedSpaceId = selectedSpaceId
    self.hasSelectedMessage = hasSelectedMessage
  }

  var hasOpenChat: Bool {
    activePeer != nil
  }

  var hasOpenThread: Bool {
    activePeer?.isThread == true
  }

  var hasSelectedSpace: Bool {
    selectedSpaceId != nil
  }
}

fileprivate enum QuickSearchCommandCondition: Hashable {
  case always
  case chatOpen
  case threadOpen
  case spaceSelected
  case messageSelected

  func isSatisfied(by context: QuickSearchCommandContext) -> Bool {
    switch self {
      case .always:
        true
      case .chatOpen:
        context.hasOpenChat
      case .threadOpen:
        context.hasOpenThread
      case .spaceSelected:
        context.hasSelectedSpace
      case .messageSelected:
        context.hasSelectedMessage
    }
  }
}

fileprivate enum QuickSearchCommand: String, CaseIterable, Identifiable, Hashable {
  case settings
#if SPARKLE
  case checkForUpdates
#endif
  case backHome
  case newThread
  case newSpace

  var id: String {
    rawValue
  }

  var title: String {
    switch self {
      case .settings:
        "Settings"
#if SPARKLE
      case .checkForUpdates:
        "Check for Updates…"
#endif
      case .backHome:
        "Back to Home"
      case .newThread:
        "New thread"
      case .newSpace:
        "New space"
    }
  }

  var typeLabel: String {
    "Command"
  }

  var symbol: String {
    switch self {
      case .settings:
        "gearshape"
#if SPARKLE
      case .checkForUpdates:
        "arrow.triangle.2.circlepath"
#endif
      case .backHome:
        "house"
      case .newThread:
        "bubble.left.and.bubble.right.fill"
      case .newSpace:
        "square.stack.3d.up.fill"
    }
  }

  var keywords: [String] {
    switch self {
      case .settings:
        ["prefs", "preferences", "settings", "config", "configuration"]
#if SPARKLE
      case .checkForUpdates:
        ["check", "update", "updates", "upgrade", "version", "sparkle"]
#endif
      case .backHome:
        ["home", "back", "workspace", "space", "main"]
      case .newThread:
        ["new", "thread", "chat", "message", "conversation"]
      case .newSpace:
        ["new", "space", "workspace", "team"]
    }
  }

  var condition: QuickSearchCommandCondition {
    switch self {
      case .settings, .newThread, .newSpace:
        .always
#if SPARKLE
      case .checkForUpdates:
        .always
#endif
      case .backHome:
        .spaceSelected
    }
  }

  func isAvailable(in context: QuickSearchCommandContext) -> Bool {
    condition.isSatisfied(by: context)
  }

  func isLikelyIntent(for query: String) -> Bool {
    let tokens = Self.tokens(from: query)
    guard tokens.isEmpty == false else { return false }

    func hasAny(_ values: Set<String>) -> Bool {
      tokens.contains { token in
        if values.contains(token) {
          return true
        }
        guard token.count >= 2 else { return false }
        return values.contains { $0.hasPrefix(token) }
      }
    }

    switch self {
      case .settings:
        return hasAny(["settings", "setting", "prefs", "pref", "preferences", "config", "configuration"])
#if SPARKLE
      case .checkForUpdates:
        return hasAny(["check", "update", "updates", "upgrade", "version", "sparkle"])
#endif
      case .backHome:
        return hasAny(["back", "home"])
      case .newThread:
        if hasAny(["new", "create", "compose"]) {
          return true
        }
        return tokens.contains("start") && hasAny(["thread", "chat", "message", "conversation"])
      case .newSpace:
        return hasAny(["new", "create"])
    }
  }

  private static func tokens(from query: String) -> Set<String> {
    var values = Set<String>()
    var current = ""
    let normalized = query
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .lowercased()

    for scalar in normalized.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        current.unicodeScalars.append(scalar)
      } else if current.isEmpty == false {
        values.insert(current)
        current = ""
      }
    }

    if current.isEmpty == false {
      values.insert(current)
    }
    return values
  }
}

@MainActor
@Observable
final class QuickSearchViewModel {
  private(set) var query: String = ""
  private(set) var selectedResultID: String?
  var focusToken: UUID = .init()
  fileprivate private(set) var renderSnapshot = QuickSearchRenderSnapshot.empty

  @ObservationIgnored private var localSections: [QuickSearchLocalSection] = []
  @ObservationIgnored private var localResults: [QuickSearchLocalItem] = []
  @ObservationIgnored private var messageResults: [QuickSearchLocalItem] = []
  @ObservationIgnored private var renderedGlobalResults: [GlobalSearchResult] = []

  @ObservationIgnored private let catalogService: CommandBarCatalogService
  @ObservationIgnored private let usageStore = QuickSearchUsageStore.shared
  @ObservationIgnored private let dependencies: AppDependencies
  @ObservationIgnored private weak var nav3: Nav3?
  @ObservationIgnored private weak var commandRegistry: CommandBarRegistry?
  @ObservationIgnored private var openSettings: (() -> Void)?
  @ObservationIgnored private var catalogProjection = InlineSearchChatProjection.empty
  @ObservationIgnored private var spaceResults: [Space] = []
  @ObservationIgnored private var commandContext = QuickSearchCommandContext()
  @ObservationIgnored private var activeSearchQuery = ""
  @ObservationIgnored private var searchGeneration: UInt64 = 0
  @ObservationIgnored private var localProjectionTask: Task<Void, Never>?
  @ObservationIgnored private var messageSearchTask: Task<Void, Never>?
  @ObservationIgnored private var globalSearchTask: Task<Void, Never>?
  @ObservationIgnored private var localProjectionToken: UInt64 = 0
  @ObservationIgnored private var catalogPrewarmTask: Task<Void, Never>?
  @ObservationIgnored private var catalogInvalidationTask: Task<Void, Never>?
  @ObservationIgnored private var catalogRefreshTask: Task<Void, Never>?
  @ObservationIgnored private var appliedCatalogRevision: UInt64 = 0
  @ObservationIgnored private var isPresented = false
  @ObservationIgnored private var rawGlobalResults: [GlobalSearchResult] = []
  @ObservationIgnored private let performanceLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  @ObservationIgnored private var activeLocalProjectionSignpost: OSSignpostID?
  private var isLocalSearchPending = false
  private var isMessageSearching = false
  private var isGlobalSearching = false
  private var searchError: Error?

  init(dependencies: AppDependencies) {
    self.dependencies = dependencies
    catalogService = dependencies.commandBarCatalog
    bindCommandContext()
    rebuildLocalResults()
    selectedResultID = nil
    runLocalProjection(query: "")
    prewarmCatalog()
  }

  deinit {
    localProjectionTask?.cancel()
    messageSearchTask?.cancel()
    globalSearchTask?.cancel()
    catalogPrewarmTask?.cancel()
    catalogInvalidationTask?.cancel()
    catalogRefreshTask?.cancel()
  }

  func attach(
    nav3: Nav3,
    commandRegistry: CommandBarRegistry?,
    openSettings: @escaping () -> Void
  ) {
    if self.nav3 !== nav3 {
      self.nav3 = nav3
      bindCommandContext()
    }
    if self.commandRegistry !== commandRegistry {
      self.commandRegistry = commandRegistry
      bindCommandRegistry()
    }
    self.openSettings = openSettings
  }

  var isLoading: Bool {
    isLocalSearchPending ||
      isMessageSearching ||
      isGlobalSearching
  }

  var error: Error? {
    searchError
  }

  var selectedIndex: Int {
    guard let selectedResultID,
          let index = renderSnapshot.resultIDs.firstIndex(of: selectedResultID)
    else {
      return -1
    }
    return index
  }

  func updateQuery(_ value: String) {
    let singleLineValue = Self.singleLineQuery(value)
    guard query != singleLineValue else { return }
    selectedResultID = renderSnapshot.resultIDs.first
    query = singleLineValue
    performSearch()
  }

  func performSearch() {
    let searchQuery = trimmedQuery
    searchGeneration &+= 1
    let generation = searchGeneration

    cancelEnrichmentTasks()
    activeSearchQuery = searchQuery
    catalogProjection = .empty
    spaceResults = []
    messageResults = []
    rawGlobalResults = []
    renderedGlobalResults = []
    searchError = nil
    runLocalProjection(query: searchQuery)

    guard InlineSearchMatcher.prepare(searchQuery) != nil else { return }
    searchMessages(query: searchQuery, generation: generation)
    searchGlobalUsers(query: searchQuery, generation: generation)
  }

  func requestFocus() {
    focusToken = UUID()
  }

  func setPresented(_ presented: Bool) {
    guard isPresented != presented else { return }
    isPresented = presented

    if presented {
      observeCatalogInvalidations()
    } else {
      catalogInvalidationTask?.cancel()
      catalogInvalidationTask = nil
      catalogRefreshTask?.cancel()
      catalogRefreshTask = nil
    }
  }

  func reset() {
    query = ""
    selectedResultID = nil
    performSearch()
  }

  func clampSelection() {
    let resultIDs = renderSnapshot.resultIDs
    guard resultIDs.isEmpty == false else {
      selectedResultID = nil
      return
    }
    if let selectedResultID, resultIDs.contains(selectedResultID) {
      return
    }
    selectedResultID = resultIDs[0]
  }

  func moveSelection(isForward: Bool) {
    let resultIDs = renderSnapshot.resultIDs
    guard resultIDs.isEmpty == false else { return }
    let currentIndex = selectedResultID.flatMap { resultIDs.firstIndex(of: $0) } ?? 0
    let nextIndex = isForward ? min(currentIndex + 1, resultIDs.count - 1) : max(currentIndex - 1, 0)
    selectedResultID = resultIDs[nextIndex]
  }

  func activateSelection() -> Bool {
    guard renderSnapshot.query == activeSearchQuery else { return false }
    let locals = renderSnapshot.localResults
    let messages = renderSnapshot.messageResults
    let globals = renderSnapshot.globalResults
    let total = locals.count + messages.count + globals.count

    guard total > 0, selectedResultID != nil else { return false }
    let index = selectedIndex
    guard index >= 0 else { return false }
    if index < locals.count {
      selectLocal(locals[index])
    } else if index < locals.count + messages.count {
      let index = index - locals.count
      if messages.indices.contains(index) {
        selectLocal(messages[index])
      }
    } else {
      let index = index - locals.count - messages.count
      if globals.indices.contains(index) {
        if case let .users(user) = globals[index] {
          selectRemote(user)
        }
      }
    }
    return true
  }

  @discardableResult
  fileprivate func selectLocal(_ result: QuickSearchLocalItem) -> Bool {
    guard renderSnapshot.query == activeSearchQuery,
          renderSnapshot.localResults.contains(where: { $0.id == result.id }) ||
          renderSnapshot.messageResults.contains(where: { $0.id == result.id })
    else { return false }

    switch result {
      case let .chat(chatResult):
        recordSelection(peer: chatResult.peer)
        Task { @MainActor in
          if let nav2 = dependencies.nav2 {
            await nav2.openChat(
              peer: chatResult.peer,
              space: chatResult.snapshot.item.space
            )
          } else {
            dependencies.requestOpenChat(peer: chatResult.peer)
          }
          openInSidebar(peer: chatResult.peer)
        }
      case let .space(space):
        if let nav2 = dependencies.nav2 {
          nav2.openSpace(space)
        } else {
          nav3?.selectSpace(space.id)
        }
      case let .command(command):
        runCommand(command)
      case let .registeredCommand(item):
        commandRegistry?.perform(item.id)
      case let .createThread(title, spaceId, _):
        NewThreadAction.start(dependencies: dependencies, spaceId: spaceId, title: title)
      case let .message(result):
        recordSelection(peer: result.peer)
        openMessageResult(result)
    }
    return true
  }

  @discardableResult
  func selectRemote(_ user: ApiUser) -> Bool {
    guard renderSnapshot.query == activeSearchQuery,
          renderSnapshot.globalResults.contains(where: { $0.id == user.id })
    else { return false }

    recordSelection(peer: .user(id: user.id))
    Task { @MainActor in
      do {
        let hasDialog = await hasExistingDialog(userId: user.id)
        if hasDialog == false {
          try await dependencies.data.createPrivateChatWithOptimistic(user: user)
        }
        if let nav2 = dependencies.nav2 {
          await nav2.openChat(peer: .user(id: user.id))
        } else {
          dependencies.requestOpenChat(peer: .user(id: user.id))
        }
        openInSidebar(peer: .user(id: user.id))
      } catch {
        Log.shared.error("Failed to open a private chat with \(user.anyName)", error: error)
        dependencies.overlay.showError(message: "Failed to open a private chat with \(user.anyName)")
      }
    }
    return true
  }

  private func hasExistingDialog(userId: Int64) async -> Bool {
    do {
      let dialog = try await dependencies.database.reader.read { db in
        try Dialog.fetchOne(db, id: Dialog.getDialogId(peerUserId: userId))
      }
      return dialog != nil
    } catch {
      Log.shared.error("Failed to check dialog for user \(userId)", error: error)
      return false
    }
  }

  private func openInSidebar(peer: Peer) {
    Task(priority: .userInitiated) { [realtimeV2 = dependencies.realtimeV2] in
      do {
        _ = try await realtimeV2.send(.updateDialogOpen(peerId: peer, open: true))
      } catch {
        Log.shared.error("Failed to open chat in sidebar \(peer.toString())", error: error)
      }
    }
  }

  private func prewarmCatalog() {
    catalogPrewarmTask?.cancel()
    catalogPrewarmTask = Task { [weak self, catalogService] in
      let revision = await catalogService.start()
      guard Task.isCancelled == false, let self else { return }
      appliedCatalogRevision = revision
      runLocalProjection(query: activeSearchQuery)
    }
  }

  private func observeCatalogInvalidations() {
    catalogInvalidationTask?.cancel()
    catalogInvalidationTask = Task { [weak self, catalogService] in
      let invalidations = await catalogService.invalidations()
      var isInitialRevision = true
      for await _ in invalidations {
        guard Task.isCancelled == false, let self, isPresented else { return }
        scheduleCatalogRefresh(
          debounce: isInitialRevision == false,
          alwaysProject: isInitialRevision
        )
        isInitialRevision = false
      }
    }
  }

  private func scheduleCatalogRefresh(debounce: Bool, alwaysProject: Bool) {
    catalogRefreshTask?.cancel()
    catalogRefreshTask = Task { [weak self, catalogService] in
      if debounce {
        do {
          try await Task.sleep(nanoseconds: 80_000_000)
        } catch {
          return
        }
      }

      let revision = await catalogService.start()
      guard Task.isCancelled == false, let self, isPresented else { return }
      let revisionChanged = appliedCatalogRevision != revision
      appliedCatalogRevision = revision
      if revisionChanged || alwaysProject {
        runLocalProjection(query: activeSearchQuery)
      }
    }
  }

  private func bindCommandRegistry() {
    withObservationTracking { [weak self] in
      _ = self?.commandRegistry?.items
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.rebuildLocalResults()
        self?.bindCommandRegistry()
      }
    }
  }

  private var commandResults: [QuickSearchCommand] {
    guard let preparedQuery = InlineSearchMatcher.prepare(activeSearchQuery) else {
      return QuickSearchCommand.allCases.filter { $0.isAvailable(in: commandContext) }
    }
    let context = commandContext
    return QuickSearchCommand.allCases
      .filter { $0.isAvailable(in: context) }
      .compactMap { command -> RankedCommand? in
        guard command.isLikelyIntent(for: activeSearchQuery) else { return nil }
        guard let match = InlineSearchMatcher.match(
          query: preparedQuery,
          fields: commandSearchFields(for: command)
        ) else { return nil }
        return RankedCommand(command: command, match: match)
      }
      .sorted { lhs, rhs in
        if lhs.match != rhs.match {
          return InlineSearchMatch.isBetter(lhs.match, than: rhs.match)
        }
        let titleComparison = lhs.command.title.localizedCaseInsensitiveCompare(rhs.command.title)
        if titleComparison != .orderedSame {
          return titleComparison == .orderedAscending
        }
        return lhs.command.rawValue < rhs.command.rawValue
      }
      .map(\.command)
  }

  private var registeredCommandResults: [CommandBarItem] {
    guard let preparedQuery = InlineSearchMatcher.prepare(activeSearchQuery) else {
      return registeredCommandItems.sorted(by: registeredCommandPrecedes)
    }
    return registeredCommandItems
      .compactMap { item -> RankedRegisteredCommand? in
        guard let match = InlineSearchMatcher.match(
          query: preparedQuery,
          fields: commandSearchFields(for: item)
        ) else { return nil }
        return RankedRegisteredCommand(item: item, match: match)
      }
      .sorted { lhs, rhs in
        if lhs.match != rhs.match {
          return InlineSearchMatch.isBetter(lhs.match, than: rhs.match)
        }
        return registeredCommandPrecedes(lhs.item, rhs.item)
      }
      .map(\.item)
  }

  private var registeredCommandItems: [CommandBarItem] {
    commandRegistry?.items.filter(\.isEnabled) ?? []
  }

  private var createThreadResult: QuickSearchLocalItem? {
    let trimmedQuery = activeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedQuery.isEmpty == false else { return nil }
    guard let spaceContext = activeSpaceContext else { return nil }
    guard isSearchComplete else { return nil }
    guard hasAnySearchResults == false else { return nil }
    return .createThread(title: trimmedQuery, spaceId: spaceContext.id, spaceName: spaceContext.name)
  }

  private var hasAnySearchResults: Bool {
    if catalogProjection.chats.isEmpty == false { return true }
    if messageResults.isEmpty == false { return true }
    if spaceResults.isEmpty == false { return true }
    if renderedGlobalResults.isEmpty == false { return true }
    if commandResults.isEmpty == false { return true }
    if registeredCommandResults.isEmpty == false { return true }
    return false
  }

  private var isSearchComplete: Bool {
    isLocalSearchPending == false &&
      isMessageSearching == false &&
      isGlobalSearching == false &&
      error == nil
  }

  private var activeSpaceContext: (id: Int64, name: String?)? {
    guard let spaceId = commandContext.selectedSpaceId else { return nil }
    return (id: spaceId, name: nil)
  }

  private var messageSearchOptions: LocalMessageSearchOptions {
    LocalMessageSearchOptions(
      spaceId: commandContext.selectedSpaceId,
      limit: 20,
      includeArchived: true,
      sort: .newest
    )
  }

  private func openMessageResult(_ result: LocalMessageSearchResult) {
    let peer = result.peer
    let messageId = result.messageId

    Task { @MainActor in
      if let nav2 = dependencies.nav2 {
        if nav2.currentRoute.selectedPeer == peer {
          ChatsManager
            .get(for: peer, chatId: result.chatId)
            .scrollTo(msgId: messageId, reason: .search)
        } else {
          nav2.requestOpenChat(
            peer: peer,
            targetMessageId: messageId,
            database: dependencies.database
          )
        }
      } else if nav3?.currentRoute.selectedPeer == peer {
        ChatsManager
          .get(for: peer, chatId: result.chatId)
          .scrollTo(msgId: messageId, reason: .search)
      } else {
        dependencies.requestOpenChat(peer: peer, targetMessageId: messageId)
      }
      openInSidebar(peer: peer)
    }
  }

  private func searchMessages(query: String, generation: UInt64) {
    guard LocalMessageSearch.isSearchable(query) else { return }
    isMessageSearching = true
    let options = messageSearchOptions
    messageSearchTask = Task { [weak self, database = dependencies.database] in
      try? await Task.sleep(for: .milliseconds(120))
      guard Task.isCancelled == false else { return }
      do {
        let results = try await LocalMessageSearch.search(db: database, query: query, options: options)
        guard Task.isCancelled == false, let self, self.searchGeneration == generation else { return }
        self.messageResults = results.map { .message($0) }
        self.isMessageSearching = false
        self.rebuildLocalResults()
      } catch {
        Log.shared.error("Failed local command-bar message search", error: error)
        guard Task.isCancelled == false, let self, self.searchGeneration == generation else { return }
        self.searchError = error
        self.isMessageSearching = false
        self.rebuildLocalResults()
      }
    }
  }

  private func searchGlobalUsers(query: String, generation: UInt64) {
    guard let preparedQuery = InlineSearchMatcher.prepare(query), preparedQuery.compact.count >= 2 else { return }
    isGlobalSearching = true
    globalSearchTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(250))
      guard Task.isCancelled == false else { return }
      do {
        let users = try await ApiClient.shared.searchContacts(query: query).users
        let rankedUsers = await Task.detached(priority: .userInitiated) {
          Self.rankGlobalUsers(users, query: preparedQuery)
        }.value
        guard Task.isCancelled == false, let self, self.searchGeneration == generation else { return }
        self.rawGlobalResults = rankedUsers.map { .users($0) }
        self.isGlobalSearching = false
        self.rebuildLocalResults()
      } catch {
        guard Task.isCancelled == false, let self, self.searchGeneration == generation else { return }
        self.searchError = error
        self.isGlobalSearching = false
        self.rebuildLocalResults()
      }
    }
  }

  private func cancelEnrichmentTasks() {
    localProjectionTask?.cancel()
    messageSearchTask?.cancel()
    globalSearchTask?.cancel()
    endLocalProjectionSignpost(reason: "cancelled")
    localProjectionToken &+= 1
    isLocalSearchPending = false
    isMessageSearching = false
    isGlobalSearching = false
  }

  private func runLocalProjection(query: String) {
    localProjectionTask?.cancel()
    endLocalProjectionSignpost(reason: "superseded")
    localProjectionToken &+= 1
    let token = localProjectionToken
    isLocalSearchPending = true
    beginLocalProjectionSignpost(query: query)

    localProjectionTask = Task { [weak self, catalogService, usageStore] in
      let usage = await usageStore.rankingSignals(for: query)
      guard Task.isCancelled == false, let self else { return }
      let projection = await catalogService.project(CommandBarCatalogService.ProjectionRequest(
        query: query,
        usage: usage,
        currentPeer: commandContext.activePeer,
        contextSpaceId: commandContext.selectedSpaceId,
        scope: InlineSearchScope(includeArchived: true),
        suggestionLimit: 5,
        chatLimit: InlineSearchMatcher.prepare(query) == nil ? 5 : 20,
        includeSpaces: supportsSpaceSelection
      ))
      guard Task.isCancelled == false, localProjectionToken == token else { return }
      catalogProjection = projection.chats
      spaceResults = projection.spaces
      isLocalSearchPending = false
      endLocalProjectionSignpost(reason: "published")
      rebuildLocalResults()
    }
  }

  private func beginLocalProjectionSignpost(query: String) {
    let signpostID = OSSignpostID(log: performanceLog)
    activeLocalProjectionSignpost = signpostID
    os_signpost(
      .begin,
      log: performanceLog,
      name: "CommandBarLocalProjection",
      signpostID: signpostID,
      "query_length=%{public}ld",
      query.utf8.count
    )
  }

  private func endLocalProjectionSignpost(reason: String) {
    guard let signpostID = activeLocalProjectionSignpost else { return }
    os_signpost(
      .end,
      log: performanceLog,
      name: "CommandBarLocalProjection",
      signpostID: signpostID,
      "%{public}s",
      reason
    )
    activeLocalProjectionSignpost = nil
  }

  private func rebuildLocalResults() {
    updateRenderedGlobalResults()

    var sections: [QuickSearchLocalSection] = []
    let suggestions = catalogProjection.suggestions.map(QuickSearchLocalItem.chat)
    let chats = catalogProjection.chats.map(QuickSearchLocalItem.chat)
    if suggestions.isEmpty == false {
      sections.append(QuickSearchLocalSection(kind: .suggestions, items: suggestions))
    }
    if chats.isEmpty == false {
      sections.append(QuickSearchLocalSection(kind: .chats, items: chats))
    }

    if InlineSearchMatcher.prepare(activeSearchQuery) != nil,
       supportsSpaceSelection,
       spaceResults.isEmpty == false {
      sections.append(QuickSearchLocalSection(kind: .spaces, items: spaceResults.map(QuickSearchLocalItem.space)))
    }

    var commands = commandResults.map(QuickSearchLocalItem.command)
    commands.append(contentsOf: registeredCommandResults.map(QuickSearchLocalItem.registeredCommand))
    if let createThreadResult {
      commands.append(createThreadResult)
    }
    if commands.isEmpty == false {
      sections.append(QuickSearchLocalSection(kind: .commands, items: commands))
    }

    localSections = sections
    localResults = sections.flatMap(\.items)
    guard isLocalSearchPending == false else { return }
    publishRenderSnapshot()
  }

  private func publishRenderSnapshot() {
    let shouldResetSelection = renderSnapshot.query != activeSearchQuery
    renderSnapshot = QuickSearchRenderSnapshot(
      query: activeSearchQuery,
      localSections: localSections,
      localResults: localResults,
      messageResults: messageResults,
      globalResults: renderedGlobalResults,
      isLoading: isLoading,
      errorDescription: searchError?.localizedDescription
    )
    if shouldResetSelection {
      selectedResultID = renderSnapshot.resultIDs.first
    } else {
      clampSelection()
    }
  }

  private func updateRenderedGlobalResults() {
    let localUserIDs = Set(
      (catalogProjection.suggestions + catalogProjection.chats).compactMap { result -> Int64? in
        guard case let .user(id) = result.peer else { return nil }
        return id
      }
    )
    renderedGlobalResults = rawGlobalResults.filter { result in
      switch result {
        case let .users(user):
          return localUserIDs.contains(user.id) == false
      }
    }
  }

  private func recordSelection(peer: Peer) {
    let selectionQuery = activeSearchQuery
    guard InlineSearchMatcher.prepare(selectionQuery) != nil else { return }
    Task { [usageStore] in
      await usageStore.recordSelection(of: peer, query: selectionQuery)
    }
  }

  private func registeredCommandPrecedes(_ lhs: CommandBarItem, _ rhs: CommandBarItem) -> Bool {
    if lhs.priority != rhs.priority {
      return lhs.priority > rhs.priority
    }
    let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
    if titleComparison != .orderedSame {
      return titleComparison == .orderedAscending
    }
    return lhs.id < rhs.id
  }

  private nonisolated static func rankGlobalUsers(
    _ users: [ApiUser],
    query: InlineSearchPreparedQuery
  ) -> [ApiUser] {
    users
      .compactMap { user -> RankedGlobalUser? in
        let fullName = [user.firstName, user.lastName]
          .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { $0.isEmpty == false }
          .joined(separator: " ")
        guard let match = InlineSearchMatcher.match(
          query: query,
          fields: [
            InlineSearchField(user.anyName, priority: 500),
            InlineSearchField(fullName, priority: 450),
            InlineSearchField(user.username.map { "@\($0)" }, priority: 600),
            InlineSearchField(user.username, priority: 550),
            InlineSearchField(user.email, priority: 300),
          ]
        ) else { return nil }
        return RankedGlobalUser(user: user, match: match)
      }
      .sorted { lhs, rhs in
        if lhs.match != rhs.match {
          return InlineSearchMatch.isBetter(lhs.match, than: rhs.match)
        }
        let order = lhs.user.anyName.localizedCaseInsensitiveCompare(rhs.user.anyName)
        if order != .orderedSame {
          return order == .orderedAscending
        }
        return lhs.user.id < rhs.user.id
      }
      .prefix(20)
      .map(\.user)
  }

  private func runCommand(_ command: QuickSearchCommand) {
    switch command {
      case .settings:
        if let openSettings {
          openSettings()
        } else {
          dependencies.appBridge.openSettings(dependencies: dependencies)
        }
#if SPARKLE
      case .checkForUpdates:
        dependencies.updates.performPrimaryAction()
#endif
      case .backHome:
        if let nav2 = dependencies.nav2,
           let homeIndex = nav2.tabs.firstIndex(of: .home) {
          nav2.setActiveTab(index: homeIndex)
        } else {
          nav3?.selectHome()
        }
      case .newThread:
        if let nav2 = dependencies.nav2 {
          NewThreadAction.start(dependencies: dependencies, spaceId: nav2.activeSpaceId)
        } else {
          nav3?.open(.newChat(spaceId: commandContext.selectedSpaceId))
        }
      case .newSpace:
        if let nav2 = dependencies.nav2 {
          nav2.navigate(to: .createSpace)
        } else {
          nav3?.open(.createSpace)
        }
    }
  }

  private func bindCommandContext() {
    withObservationTracking { [weak self] in
      guard let self else { return }
      let context: QuickSearchCommandContext
      if let nav2 = dependencies.nav2 {
        let activePeer: Peer?
        switch nav2.currentRoute {
        case let .chat(peer), let .chatInfo(peer):
          activePeer = peer
        default:
          activePeer = nil
        }

        context = QuickSearchCommandContext(
          activePeer: activePeer,
          selectedSpaceId: nav2.activeSpaceId,
          hasSelectedMessage: false
        )
      } else {
        context = QuickSearchCommandContext(
          activePeer: nav3?.currentReplyThreadPeer ?? nav3?.currentRoute.selectedPeer,
          selectedSpaceId: nav3?.selectedSpaceId,
          hasSelectedMessage: false
        )
      }
      if commandContext != context {
        commandContext = context
        runLocalProjection(query: activeSearchQuery)
        rebuildLocalResults()
      }
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.bindCommandContext()
      }
    }
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private nonisolated static func singleLineQuery(_ value: String) -> String {
    value.components(separatedBy: .newlines).joined(separator: " ")
  }

  private var supportsSpaceSelection: Bool {
    dependencies.nav2 != nil || nav3 != nil
  }

  private func commandSearchFields(for command: QuickSearchCommand) -> [InlineSearchField] {
    var fields = [InlineSearchField(command.title, priority: 620)]
    fields.append(contentsOf: command.keywords.map { InlineSearchField($0, priority: 420) })
    fields.append(InlineSearchField(([command.title] + command.keywords).joined(separator: " "), priority: 260))
    return fields
  }

  private func commandSearchFields(for item: CommandBarItem) -> [InlineSearchField] {
    var fields = [InlineSearchField(item.title, priority: 640 + item.priority)]
    fields.append(contentsOf: item.keywords.map { InlineSearchField($0, priority: 420) })
    fields.append(InlineSearchField(([item.title] + item.keywords).joined(separator: " "), priority: 260))
    return fields
  }

  private struct RankedCommand {
    let command: QuickSearchCommand
    let match: InlineSearchMatch
  }

  private struct RankedRegisteredCommand {
    let item: CommandBarItem
    let match: InlineSearchMatch
  }

  private struct RankedGlobalUser {
    let user: ApiUser
    let match: InlineSearchMatch
  }
}

struct QuickSearchOverlayView: View {
  let viewModel: QuickSearchViewModel
  let onDismiss: () -> Void

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let snapshot = viewModel.renderSnapshot
    let shape = RoundedRectangle(cornerRadius: QuickSearchLayout.cornerRadius, style: .continuous)
    let content = VStack(spacing: 0) {
      searchHeader
      Divider()
        .frame(height: QuickSearchLayout.separatorHeight)
      QuickSearchResultsView(
        localSections: snapshot.localSections,
        localResults: snapshot.localResults,
        messageResults: snapshot.messageResults,
        globalResults: snapshot.globalResults,
        selectedIndex: viewModel.selectedIndex,
        isLoading: snapshot.isLoading,
        errorDescription: snapshot.errorDescription,
        query: snapshot.query,
        scrollQuery: viewModel.query,
        rowHeight: QuickSearchLayout.rowHeight,
        rowSpacing: QuickSearchLayout.rowSpacing,
        rowInnerPadding: QuickSearchLayout.rowInnerPadding,
        sectionHeaderHeight: QuickSearchLayout.sectionHeaderHeight,
        sectionSpacing: QuickSearchLayout.sectionSpacing,
        onSelectLocal: { result in
          if viewModel.selectLocal(result) {
            onDismiss()
          }
        },
        onSelectRemote: { user in
          if viewModel.selectRemote(user) {
            onDismiss()
          }
        }
      )
      .frame(maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)

    Group {
      if #available(macOS 26.0, *) {
        content
          .background(shape.fill(tint))
          .glassEffect(.regular, in: shape)
      } else {
        content
          .background(VisualEffectView(material: .popover, blendingMode: .withinWindow))
          .background(shape.fill(tint))
          .compositingGroup()
          .clipShape(shape)
      }
    }
  }

  private var searchHeader: some View {
    QuickSearchSingleLineField(
      text: Binding(
        get: { viewModel.query },
        set: { viewModel.updateQuery($0) }
      ),
      placeholder: "Search chats, members, and messages",
      focusToken: viewModel.focusToken,
      onSubmit: {
        if viewModel.activateSelection() {
          onDismiss()
        }
      }
    )
    .frame(maxWidth: .infinity, minHeight: QuickSearchLayout.searchBarHeight, alignment: .leading)
    .padding(.horizontal, QuickSearchLayout.searchBarTextInset)
    .padding(.horizontal, QuickSearchLayout.contentHorizontalPadding)
    .padding(.vertical, QuickSearchLayout.searchHeaderVerticalPadding)
    .frame(height: QuickSearchLayout.searchHeaderHeight)
  }

  private var tint: Color {
    let opacity = colorScheme == .dark ? 0.14 : 0.16
    return colorScheme == .dark ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
  }
}

private struct QuickSearchSingleLineField: NSViewRepresentable {
  @Binding var text: String

  let placeholder: String
  let focusToken: UUID
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onSubmit: onSubmit)
  }

  func makeNSView(context: Context) -> NSTextField {
    let field = NSTextField()
    field.delegate = context.coordinator
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 15, weight: .medium)
    field.textColor = .labelColor
    field.placeholderAttributedString = NSAttributedString(
      string: placeholder,
      attributes: [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
    )
    field.usesSingleLineMode = true
    field.maximumNumberOfLines = 1
    field.lineBreakMode = .byTruncatingTail
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    return field
  }

  func updateNSView(_ field: NSTextField, context: Context) {
    context.coordinator.text = $text
    context.coordinator.onSubmit = onSubmit

    if field.stringValue != text {
      field.stringValue = text
    }

    guard context.coordinator.focusToken != focusToken else { return }
    context.coordinator.focusToken = focusToken
    DispatchQueue.main.async { [weak field] in
      guard let field, let window = field.window else { return }
      window.makeFirstResponder(field)
      field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.utf16.count, length: 0)
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var onSubmit: () -> Void
    var focusToken: UUID?

    init(text: Binding<String>, onSubmit: @escaping () -> Void) {
      self.text = text
      self.onSubmit = onSubmit
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      let singleLineValue = field.stringValue.components(separatedBy: .newlines).joined(separator: " ")
      if field.stringValue != singleLineValue {
        field.stringValue = singleLineValue
        field.currentEditor()?.string = singleLineValue
        field.currentEditor()?.selectedRange = NSRange(location: singleLineValue.utf16.count, length: 0)
      }
      if text.wrappedValue != singleLineValue {
        text.wrappedValue = singleLineValue
      }
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
          onSubmit()
          return true
        default:
          return false
      }
    }
  }
}

private struct QuickSearchResultsView: View {
  private static let topAnchorID = "quick-search-scroll-top"

  let localSections: [QuickSearchLocalSection]
  let localResults: [QuickSearchLocalItem]
  let messageResults: [QuickSearchLocalItem]
  let globalResults: [GlobalSearchResult]
  let selectedIndex: Int
  let isLoading: Bool
  let errorDescription: String?
  let query: String
  let scrollQuery: String
  let rowHeight: CGFloat
  let rowSpacing: CGFloat
  let rowInnerPadding: CGFloat
  let sectionHeaderHeight: CGFloat
  let sectionSpacing: CGFloat
  let onSelectLocal: (QuickSearchLocalItem) -> Void
  let onSelectRemote: (ApiUser) -> Void

  @State private var fullyVisibleRowIDs: Set<String> = []

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    let hasAnyResults = !localResults.isEmpty || !messageResults.isEmpty || !globalResults.isEmpty
    let rows = visibleRows(
      localSections: localSections,
      messageResults: messageResults,
      globalResults: globalResults
    )
    let scrollState = QuickSearchScrollState(
      query: scrollQuery,
      selectedIndex: selectedIndex,
      selectedRowID: rows.first(where: { $0.resultIndex == selectedIndex })?.id
    )

    ScrollViewReader { proxy in
      ScrollView(.vertical) {
        LazyVStack(alignment: .leading, spacing: rowSpacing) {
          if hasAnyResults {
            ForEach(rows) { row in
              QuickSearchResultRowView(
                row: row,
                selectedIndex: selectedIndex,
                rowHeight: rowHeight,
                rowInnerPadding: rowInnerPadding,
                sectionHeaderHeight: sectionHeaderHeight,
                onSelectLocal: onSelectLocal,
                onSelectRemote: onSelectRemote
              )
              .onScrollVisibilityChange(threshold: 0.99) { isFullyVisible in
                updateVisibility(of: row.id, isFullyVisible: isFullyVisible)
              }
            }
          } else if isLoading {
            QuickSearchLoadingRow(rowHeight: rowHeight, rowInnerPadding: rowInnerPadding)
          } else if let errorDescription {
            QuickSearchEmptyRow(
              text: "Failed to load: \(errorDescription)",
              rowHeight: rowHeight,
              rowInnerPadding: rowInnerPadding
            )
          } else if !trimmedQuery.isEmpty {
            QuickSearchEmptyRow(text: "No results found", rowHeight: rowHeight, rowInnerPadding: rowInnerPadding)
          }
        }
        .id(Self.topAnchorID)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentMargins(
        .horizontal,
        QuickSearchLayout.listContentHorizontalInset,
        for: .scrollContent
      )
      .contentMargins(
        .top,
        QuickSearchLayout.listContentTopInset,
        for: .scrollContent
      )
      .contentMargins(
        .bottom,
        QuickSearchLayout.listContentBottomInset,
        for: .scrollContent
      )
      .scrollIndicators(.hidden, axes: .horizontal)
      .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      .scrollBounceBehavior(.basedOnSize, axes: .vertical)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onAppear {
        scrollToTop(proxy: proxy)
      }
      .onChange(of: scrollState) { oldState, newState in
        updateScrollPosition(from: oldState, to: newState, proxy: proxy)
      }
    }
  }

  private func visibleRows(
    localSections: [QuickSearchLocalSection],
    messageResults: [QuickSearchLocalItem],
    globalResults: [GlobalSearchResult]
  ) -> [QuickSearchVisibleRow] {
    var rows: [QuickSearchVisibleRow] = []
    var resultIndex = 0

    for section in localSections {
      rows.append(.header(
        id: section.kind.rawValue,
        title: section.kind.title,
        topPadding: rows.isEmpty ? 0 : sectionSpacing
      ))
      for result in section.items {
        rows.append(.local(index: resultIndex, item: result))
        resultIndex += 1
      }
    }

    if messageResults.isEmpty == false {
      rows.append(.header(
        id: "messages",
        title: "Messages",
        topPadding: rows.isEmpty ? 0 : sectionSpacing
      ))
      for (index, result) in messageResults.enumerated() {
        rows.append(.local(index: resultIndex + index, item: result))
      }
      resultIndex += messageResults.count
    }

    if globalResults.isEmpty == false {
      rows.append(.header(
        id: "global",
        title: "Global Search",
        topPadding: rows.isEmpty ? 0 : sectionSpacing
      ))
      for (index, result) in globalResults.enumerated() {
        rows.append(.global(index: resultIndex + index, result: result))
      }
    }

    return rows
  }

  private func updateVisibility(of rowID: String, isFullyVisible: Bool) {
    if isFullyVisible {
      fullyVisibleRowIDs.insert(rowID)
    } else {
      fullyVisibleRowIDs.remove(rowID)
    }
  }

  private func updateScrollPosition(
    from oldState: QuickSearchScrollState,
    to newState: QuickSearchScrollState,
    proxy: ScrollViewProxy
  ) {
    if oldState.query != newState.query {
      fullyVisibleRowIDs.removeAll(keepingCapacity: true)
      scrollToTop(proxy: proxy)
      return
    }

    guard oldState.selectedIndex != newState.selectedIndex,
          let selectedRowID = newState.selectedRowID,
          !fullyVisibleRowIDs.contains(selectedRowID)
    else { return }

    scroll(
      proxy: proxy,
      to: selectedRowID,
      anchor: newState.selectedIndex > oldState.selectedIndex ? .bottom : .top
    )
  }

  private func scrollToTop(proxy: ScrollViewProxy) {
    scroll(proxy: proxy, to: Self.topAnchorID, anchor: .top)
  }

  private func scroll(proxy: ScrollViewProxy, to id: String, anchor: UnitPoint) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      proxy.scrollTo(id, anchor: anchor)
    }
  }
}

private struct QuickSearchScrollState: Equatable {
  let query: String
  let selectedIndex: Int
  let selectedRowID: String?
}

private struct QuickSearchVisibleRow: Identifiable {
  enum Content {
    case header(title: String, topPadding: CGFloat)
    case local(QuickSearchLocalItem)
    case global(GlobalSearchResult)
  }

  let id: String
  let resultIndex: Int?
  let content: Content

  static func header(id: String, title: String, topPadding: CGFloat) -> QuickSearchVisibleRow {
    QuickSearchVisibleRow(
      id: "quick-search-header-\(id)",
      resultIndex: nil,
      content: .header(title: title, topPadding: topPadding)
    )
  }

  static func local(index: Int, item: QuickSearchLocalItem) -> QuickSearchVisibleRow {
    QuickSearchVisibleRow(
      id: "quick-search-local-\(item.id)",
      resultIndex: index,
      content: .local(item)
    )
  }

  static func global(index: Int, result: GlobalSearchResult) -> QuickSearchVisibleRow {
    QuickSearchVisibleRow(
      id: "quick-search-global-\(result.id)",
      resultIndex: index,
      content: .global(result)
    )
  }
}

private struct QuickSearchResultRowView: View {
  let row: QuickSearchVisibleRow
  let selectedIndex: Int
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat
  let sectionHeaderHeight: CGFloat
  let onSelectLocal: (QuickSearchLocalItem) -> Void
  let onSelectRemote: (ApiUser) -> Void

  var body: some View {
    VStack(spacing: 0) {
      switch row.content {
        case let .header(title, topPadding):
          QuickSearchSectionHeader(
            title: title,
            height: sectionHeaderHeight,
            rowInnerPadding: rowInnerPadding
          )
          .padding(.top, topPadding)
        case let .local(result):
          QuickSearchRow(
            item: result,
            highlighted: row.resultIndex == selectedIndex,
            rowHeight: rowHeight,
            rowInnerPadding: rowInnerPadding,
            action: { onSelectLocal(result) }
          )
        case let .global(result):
          switch result {
            case let .users(user):
              QuickSearchRow(
                user: user,
                highlighted: row.resultIndex == selectedIndex,
                rowHeight: rowHeight,
                rowInnerPadding: rowInnerPadding,
                action: { onSelectRemote(user) }
              )
          }
      }
    }
  }
}

private struct QuickSearchSectionHeader: View {
  let title: String
  let height: CGFloat
  let rowInnerPadding: CGFloat

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
      .padding(.horizontal, rowInnerPadding)
  }
}

private struct QuickSearchRow: View {
  @State private var isHovered: Bool = false
#if SPARKLE
  @Environment(UpdateController.self) private var updates
#endif

  let item: QuickSearchLocalItem?
  let user: ApiUser?
  let highlighted: Bool
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat
  let action: () -> Void

  init(
    item: QuickSearchLocalItem,
    highlighted: Bool,
    rowHeight: CGFloat,
    rowInnerPadding: CGFloat,
    action: @escaping () -> Void
  ) {
    self.item = item
    user = nil
    self.highlighted = highlighted
    self.rowHeight = rowHeight
    self.rowInnerPadding = rowInnerPadding
    self.action = action
  }

  init(
    user: ApiUser,
    highlighted: Bool,
    rowHeight: CGFloat,
    rowInnerPadding: CGFloat,
    action: @escaping () -> Void
  ) {
    item = nil
    self.user = user
    self.highlighted = highlighted
    self.rowHeight = rowHeight
    self.rowInnerPadding = rowInnerPadding
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(alignment: .center, spacing: QuickSearchLayout.iconTextSpacing) {
        if let item {
          switch item {
            case let .chat(result):
              chatIcon(for: result)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(result.title)
                  .lineLimit(1)
                if let subtitle = result.subtitle, subtitle != result.title {
                  Text(subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(result.peer.isThread ? "Thread" : "User")
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

            case let .space(space):
              SpaceAvatar(space: space, size: QuickSearchLayout.iconSize)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(space.displayName)
                  .lineLimit(1)
                Spacer(minLength: 0)
                Text("Space")
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

            case let .command(command):
              InitialsCircle(name: title(for: command), size: QuickSearchLayout.iconSize, symbol: command.symbol)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(title(for: command))
                  .lineLimit(1)
                Spacer(minLength: 0)
                Text(command.typeLabel)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

            case let .registeredCommand(item):
              InitialsCircle(name: item.title, size: QuickSearchLayout.iconSize, symbol: item.systemImage)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(item.title)
                  .lineLimit(1)
                Spacer(minLength: 0)
                Text(item.typeLabel)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

            case let .createThread(title, _, spaceName):
              InitialsCircle(name: title, size: QuickSearchLayout.iconSize, symbol: "plus.bubble.fill")
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text("Create \"\(title)\"")
                  .lineLimit(1)
                if let spaceName {
                  Text(spaceName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Command")
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }

            case let .message(result):
              messageIcon(for: result)
                .frame(
                  width: QuickSearchLayout.iconContainerSize,
                  height: QuickSearchLayout.iconContainerSize,
                  alignment: .center
                )
              HStack(spacing: QuickSearchLayout.itemTextSpacing) {
                Text(result.title)
                  .lineLimit(1)
                if result.snippet.isEmpty == false {
                  Text(result.snippet)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("Message")
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
          }
        } else if let user {
          UserAvatar(apiUser: user, size: QuickSearchLayout.iconSize)
            .frame(
              width: QuickSearchLayout.iconContainerSize,
              height: QuickSearchLayout.iconContainerSize,
              alignment: .center
            )
          HStack(spacing: QuickSearchLayout.itemTextSpacing) {
            Text(user.firstName ?? user.username ?? "")
              .lineLimit(1)
            if let username = user.username {
              Text("@\(username)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(user.bot == true ? "Bot" : "User")
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: rowHeight)
      .padding(.horizontal, rowInnerPadding)
      .background(
        RoundedRectangle(cornerRadius: Theme.sidebarItemRadius)
          .fill(backgroundColor)
      )
      .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
      .onHover { isHovered = $0 }
    }
    .buttonStyle(.plain)
  }

  private var backgroundColor: Color {
    if highlighted {
      return .primary.opacity(0.1)
    }
    if isHovered {
      return .primary.opacity(0.05)
    }
    return .clear
  }

  private func title(for command: QuickSearchCommand) -> String {
#if SPARKLE
    if command == .checkForUpdates {
      return updates.phase.menuTitle
    }
#endif
    return command.title
  }

  @ViewBuilder
  private func chatIcon(for result: InlineSearchChatResult) -> some View {
    if let userInfo = result.userInfo {
      SidebarChatIcon(peer: .user(userInfo), size: QuickSearchLayout.iconSize)
    } else if let chat = result.chat {
      SidebarChatIcon(peer: .chat(chat), size: QuickSearchLayout.iconSize)
    } else {
      InitialsCircle(name: result.title, size: QuickSearchLayout.iconSize, symbol: "bubble.fill")
    }
  }

  @ViewBuilder
  private func messageIcon(for result: LocalMessageSearchResult) -> some View {
    switch result.peer {
      case .thread:
        if let chat = result.chat {
          SidebarChatIcon(peer: .chat(chat), size: QuickSearchLayout.iconSize)
        } else {
          InitialsCircle(name: result.title, size: QuickSearchLayout.iconSize, symbol: "text.bubble.fill")
        }
      case .user:
        if let user = result.peerUser {
          SidebarChatIcon(
            peer: .user(UserInfo(user: user)),
            size: QuickSearchLayout.iconSize
          )
        } else {
          InitialsCircle(name: result.title, size: QuickSearchLayout.iconSize, symbol: "text.bubble.fill")
        }
    }
  }
}

private struct QuickSearchEmptyRow: View {
  let text: String
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat

  var body: some View {
    HStack(spacing: 0) {
      Text(text)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .frame(height: rowHeight)
    .padding(.horizontal, rowInnerPadding)
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .opacity(0.7)
    .allowsHitTesting(false)
  }
}

private struct QuickSearchLoadingRow: View {
  let rowHeight: CGFloat
  let rowInnerPadding: CGFloat

  var body: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
      Text("Searching…")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .frame(height: rowHeight)
    .padding(.horizontal, rowInnerPadding)
    .contentShape(.interaction, .rect(cornerRadius: Theme.sidebarItemRadius))
    .opacity(0.9)
    .allowsHitTesting(false)
  }
}
