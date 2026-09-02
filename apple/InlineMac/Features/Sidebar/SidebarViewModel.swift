import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation
import OSLog
import Translation

@MainActor
@Observable
final class SidebarViewModel {
  enum ContentMode: Equatable {
    case chatList
    case inbox
  }

  struct Item: Equatable, Identifiable {
    let id: ChatListItem.Identifier
    let peerId: Peer
    let chatId: Int64
    let parentChatId: Int64?
    let spaceId: Int64?
    let title: String
    let parentTitle: String?
    let preview: String
    let unread: Bool
    let unreadCount: Int
    let unreadMark: Bool
    let prominentUnreadDot: Bool
    let pinned: Bool
    let archived: Bool
    let open: Bool
    let order: String?
    let pinnedOrder: String?
    let folderID: Int64?
    let lastActivityAt: Date
    let identity: ChatListIdentityDescriptor?
    let chatType: ChatType?
    let chatCreatedBy: Int64?
    let chatIsPublic: Bool?

    init(snapshot: ChatListItemSnapshot, kind: ChatListItem.Kind = .thread) {
      id = ChatListItem.Identifier(kind: kind, rawValue: snapshot.dialogID)
      peerId = snapshot.peer
      chatId = snapshot.chatID
      parentChatId = snapshot.parentChatID
      spaceId = snapshot.spaceID
      title = snapshot.title
      parentTitle = snapshot.parentTitle
      let showsTranslation = TranslationState.shared.isTranslationEnabled(for: snapshot.peer)
      let text = (showsTranslation ? snapshot.translatedPreviewText : nil)
        ?? snapshot.previewText
        ?? ""
      if let sender = snapshot.previewSenderName, sender.isEmpty == false, text.isEmpty == false {
        preview = "\(sender): \(text)"
      } else {
        preview = text
      }
      unreadCount = snapshot.unreadCount
      unreadMark = snapshot.unreadMark
      unread = snapshot.isUnread
      prominentUnreadDot = snapshot.isProminent
      pinned = snapshot.isPinned
      archived = snapshot.isArchived
      open = snapshot.isOpen
      order = snapshot.order
      pinnedOrder = snapshot.pinnedOrder
      folderID = snapshot.folderID
      lastActivityAt = snapshot.lastUpdatedAt ?? .distantPast
      identity = snapshot.identity
      chatType = snapshot.chatType
      chatCreatedBy = snapshot.chatCreatedBy
      chatIsPublic = snapshot.chatIsPublic
    }
  }

  struct Folder: Equatable, Identifiable {
    let id: Int64
    let title: String?
    let emoji: String?
    let order: String
    let pinnedOrder: String?

    var isPinned: Bool { pinnedOrder != nil }

    init(_ folder: DialogFolder) {
      id = folder.id
      title = folder.title
      emoji = folder.emoji
      order = folder.order
      pinnedOrder = folder.pinnedOrder
    }
  }

  private struct SourceSnapshot: Equatable {
    let chats: [ChatListItemSnapshot]
    let folders: [Folder]
  }

  var activeItems: [Item] = []
  var archivedItems: [Item] = []
  var temporaryItems: [Item] = []
  var folders: [Folder] = []
  var isChatProjectionReady = false
  var hasResolvedSpaces = false
  var spaces: [Space] = []
  var errorText: String?

  @ObservationIgnored private let log = Log.scoped("SidebarViewModel")
  private static let diagnostics = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac",
    category: "SidebarFirstFrame"
  )
  private static let signposts = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "chat.inline.InlineMac",
    category: "SidebarFirstFrame"
  )
  @ObservationIgnored private let db: AppDatabase
  @ObservationIgnored private var source: Source?
  @ObservationIgnored private var snapshots: [ChatListItemSnapshot] = []
  @ObservationIgnored private var temporaryPeer: Peer?
  @ObservationIgnored private var chatsCancellable: AnyCancellable?
  @ObservationIgnored private var translationCancellable: AnyCancellable?
  @ObservationIgnored private var translationLanguageCancellable: AnyCancellable?
  @ObservationIgnored private var spacesCancellable: AnyCancellable?
  @ObservationIgnored private var chatsRetryTask: Task<Void, Never>?
  @ObservationIgnored private var chatsRetryAttempt = 0
  @ObservationIgnored private var spacesRetryTask: Task<Void, Never>?
  @ObservationIgnored private var spacesRetryAttempt = 0
  @ObservationIgnored private var includeSpaceChatsInHome = true
  @ObservationIgnored private var sortMode = SidebarSortMode.openedOrder
  @ObservationIgnored private var started = false
  @ObservationIgnored private var chatsObservationGeneration = 0
  @ObservationIgnored private var hasReceivedChatValue = false
  @ObservationIgnored private var sourceBindStartedAt: TimeInterval?

  private enum Source: Equatable {
    case home(ContentMode)
    case space(Int64, ContentMode)

    var spaceId: Int64? {
      switch self {
      case .home:
        nil
      case let .space(spaceId, _):
        spaceId
      }
    }

    var diagnosticCode: String {
      switch self {
      case .home(.inbox):
        "home-inbox"
      case .home(.chatList):
        "home-all"
      case .space(_, .inbox):
        "space-inbox"
      case .space(_, .chatList):
        "space-all"
      }
    }

  }

  init(
    db: AppDatabase,
    startsObserving: Bool = true,
    selectedSpaceId: Int64? = nil,
    mode: ContentMode = .chatList,
    sortMode: SidebarSortMode = .openedOrder,
    temporaryPeer: Peer? = nil
  ) {
    self.db = db
    self.sortMode = sortMode
    self.temporaryPeer = temporaryPeer
    translationCancellable = TranslationState.shared.subject.sink { [weak self] event in
      guard let self else { return }
      let (peer, _) = event
      guard snapshots.contains(where: { $0.peer == peer }) else { return }
      refreshItems()
      if let source {
        observeChats(for: source)
      }
    }
    translationLanguageCancellable = NotificationCenter.default
      .publisher(for: .translationLanguageChanged)
      .sink { [weak self] _ in
        guard let self, let source else { return }
        observeChats(for: source)
      }
    if startsObserving {
      start(selectedSpaceId: selectedSpaceId, mode: mode, sortMode: sortMode)
    }
  }

  func start(
    selectedSpaceId: Int64?,
    mode: ContentMode = .chatList,
    sortMode: SidebarSortMode? = nil
  ) {
    if let sortMode {
      self.sortMode = sortMode
    }
    if started == false {
      started = true
      observeSpaces()
    }

    if let selectedSpaceId {
      bindSource(.space(selectedSpaceId, mode))
    } else {
      bindSource(.home(mode))
    }
  }

  func selectHome(mode: ContentMode = .chatList) {
    start(selectedSpaceId: nil, mode: mode)
  }

  func selectSpace(_ spaceId: Int64, mode: ContentMode = .chatList) {
    start(selectedSpaceId: spaceId, mode: mode)
  }

  func space(id: Int64?) -> Space? {
    guard let id else { return nil }
    return spaces.first { $0.id == id }
  }

  func hasSpace(id: Int64) -> Bool {
    spaces.contains { $0.id == id }
  }

  /// Readiness belongs to a specific source, not merely to whichever source
  /// most recently published. SwiftUI preference changes can render before
  /// their `onChange` handler rebinds the model; reject that mixed old/new
  /// scene until the requested source has produced its first coherent value.
  func isReady(selectedSpaceId: Int64?, mode: ContentMode) -> Bool {
    guard isChatProjectionReady else { return false }
    if let selectedSpaceId {
      return source == .space(selectedSpaceId, mode)
    }
    return source == .home(mode)
  }

  func setIncludeSpaceChatsInHome(_ include: Bool) {
    guard includeSpaceChatsInHome != include else { return }
    includeSpaceChatsInHome = include
    refreshItems()
  }

  func setSortMode(_ sortMode: SidebarSortMode) {
    guard self.sortMode != sortMode else { return }
    self.sortMode = sortMode
    refreshItems()
  }

  /// Selected closed chats are projected from the same snapshot as normal
  /// membership. This keeps first-frame membership under one observation
  /// instead of racing a second full database query.
  func setTemporaryPeer(_ peer: Peer?) {
    guard temporaryPeer != peer else { return }
    temporaryPeer = peer
    refreshItems()
    os_log(
      .info,
      log: Self.diagnostics,
      "component=model event=temporary-peer ready=%{public}d present=%{public}d rows=%{public}d",
      isChatProjectionReady ? 1 : 0,
      peer != nil ? 1 : 0,
      temporaryItems.count
    )
  }

  private func bindSource(_ source: Source) {
    guard self.source != source else { return }
    self.source = source
    chatsCancellable?.cancel()
    chatsCancellable = nil
    chatsRetryTask?.cancel()
    chatsRetryTask = nil
    chatsRetryAttempt = 0

    // Flip readiness before clearing projection values. The collection keeps
    // its last coherent scene until this source's first database value arrives.
    isChatProjectionReady = false
    hasReceivedChatValue = false
    sourceBindStartedAt = ProcessInfo.processInfo.systemUptime
    snapshots = []
    activeItems = []
    archivedItems = []
    temporaryItems = []
    folders = []
    errorText = nil

    os_log(
      .info,
      log: Self.diagnostics,
      "component=model event=source-bind source=%{public}@",
      source.diagnosticCode as NSString
    )

    observeChats(for: source)
  }

  private func observeChats(for source: Source) {
    guard self.source == source else { return }
    chatsCancellable?.cancel()
    chatsCancellable = nil
    chatsRetryTask?.cancel()
    chatsRetryTask = nil
    chatsObservationGeneration &+= 1
    let generation = chatsObservationGeneration
    let startedAt = ProcessInfo.processInfo.systemUptime

    os_log(
      .info,
      log: Self.diagnostics,
      "component=model event=observe-start generation=%{public}d source=%{public}@",
      generation,
      source.diagnosticCode as NSString
    )
    os_signpost(
      .event,
      log: Self.signposts,
      name: "SidebarModelObserveStart",
      "generation=%{public}d",
      generation
    )

    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.chats")
    #endif

    chatsCancellable = ValueObservation
      .tracking { db in
        let chats = try ChatListDatabaseQuery.fetchSnapshots(
          db,
          spaceID: source.spaceId,
          includeSpaceChatsInHome: true,
          translationLanguage: UserLocale.getCurrentLanguage()
        )
        let folders = source.spaceId == nil
          ? try DialogFolder.order(DialogFolder.Columns.order, DialogFolder.Columns.id)
            .fetchAll(db)
            .map(Folder.init)
          : []
        return SourceSnapshot(chats: chats, folders: folders)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .removeDuplicates()
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }
          guard case let .failure(error) = completion,
                self.source == source,
                chatsObservationGeneration == generation
          else { return }
          errorText = activeItems.isEmpty && archivedItems.isEmpty
            ? "Couldn’t load chats. Retrying…"
            : nil
          hasReceivedChatValue = true
          updateChatProjectionReadiness()
          log.error("Sidebar observation failed: \(Self.safeErrorName(error))")
          os_log(
            .error,
            log: Self.diagnostics,
            "component=model event=observe-failed generation=%{public}d source=%{public}@ error=%{public}@",
            generation,
            source.diagnosticCode as NSString,
            Self.safeErrorName(error) as NSString
          )
          os_signpost(
            .event,
            log: Self.signposts,
            name: "SidebarModelObserveFailed",
            "generation=%{public}d",
            generation
          )
          scheduleChatsObservationRetry(for: source)
        },
        receiveValue: { [weak self] sourceSnapshot in
          guard let self,
                self.source == source,
                chatsObservationGeneration == generation
          else { return }
          let previousActive = activeItems
          let previousArchived = archivedItems
          let previousTemporary = temporaryItems
          self.snapshots = sourceSnapshot.chats
          if folders != sourceSnapshot.folders {
            folders = sourceSnapshot.folders
          }
          chatsRetryAttempt = 0
          chatsRetryTask?.cancel()
          chatsRetryTask = nil
          errorText = nil
          refreshItems()
          hasReceivedChatValue = true
          updateChatProjectionReadiness()

          let elapsedMilliseconds = Int(
            ((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000).rounded()
          )
          let openCount = sourceSnapshot.chats.lazy.filter(\.isOpen).count
          let pinnedCount = sourceSnapshot.chats.lazy.filter(\.isPinned).count
          let membershipChanged = previousActive.map(\.id) != activeItems.map(\.id)
            || previousArchived.map(\.id) != archivedItems.map(\.id)
            || previousTemporary.map(\.id) != temporaryItems.map(\.id)
          let contentChanged = previousActive != activeItems
            || previousArchived != archivedItems
            || previousTemporary != temporaryItems
          os_log(
            .info,
            log: Self.diagnostics,
            "component=model event=publish generation=%{public}d source=%{public}@ elapsed-ms=%{public}d snapshots=%{public}d open=%{public}d pinned=%{public}d active=%{public}d archived=%{public}d temporary=%{public}d membership-changed=%{public}d content-changed=%{public}d",
            generation,
            source.diagnosticCode as NSString,
            elapsedMilliseconds,
            sourceSnapshot.chats.count,
            openCount,
            pinnedCount,
            activeItems.count,
            archivedItems.count,
            temporaryItems.count,
            membershipChanged ? 1 : 0,
            contentChanged ? 1 : 0
          )
          os_signpost(
            .event,
            log: Self.signposts,
            name: "SidebarModelPublish",
            "generation=%{public}d snapshots=%{public}d active=%{public}d temporary=%{public}d",
            generation,
            sourceSnapshot.chats.count,
            activeItems.count,
            temporaryItems.count
          )
        }
      )
  }

  private func scheduleChatsObservationRetry(for source: Source) {
    guard chatsRetryTask == nil, self.source == source else { return }
    chatsRetryAttempt &+= 1
    let delay = min(pow(2, Double(min(chatsRetryAttempt - 1, 5))) * 0.25, 8)
    chatsRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard Task.isCancelled == false, let self, self.source == source else { return }
      chatsRetryTask = nil
      observeChats(for: source)
    }
  }

  private func observeSpaces() {
    spacesRetryTask?.cancel()
    spacesRetryTask = nil

    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.spaces")
    #endif

    spacesCancellable = ValueObservation
      .tracking { db in
        try Space
          .catalogActive()
          .including(all: Space.members)
          .order(Space.Columns.id)
          .asRequest(of: HomeSpaceItem.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }

          guard case let .failure(error) = completion else { return }
          log.error("Sidebar spaces observation failed: \(Self.safeErrorName(error))")
          os_log(
            .error,
            log: Self.diagnostics,
            "component=model event=spaces-observe-failed error=%{public}@",
            Self.safeErrorName(error) as NSString
          )
          os_signpost(
            .event,
            log: Self.signposts,
            name: "SidebarSpacesObserveFailed"
          )
          scheduleSpacesObservationRetry()
        },
        receiveValue: { [weak self] spaces in
          guard let self else { return }
          spacesRetryAttempt = 0
          spacesRetryTask?.cancel()
          spacesRetryTask = nil
          applySpaces(spaces)
        }
      )
  }

  private func scheduleSpacesObservationRetry() {
    guard spacesRetryTask == nil else { return }
    spacesRetryAttempt &+= 1
    let delay = min(pow(2, Double(min(spacesRetryAttempt - 1, 5))) * 0.25, 8)
    spacesRetryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard Task.isCancelled == false, let self else { return }
      spacesRetryTask = nil
      observeSpaces()
    }
  }

  private func applySpaces(_ spaces: [HomeSpaceItem]) {
    let nextSpaces = spaces.map(\.space)
    let changed = self.spaces != nextSpaces
    if changed {
      self.spaces = nextSpaces
    }
    if hasResolvedSpaces == false {
      hasResolvedSpaces = true
    }
    updateChatProjectionReadiness()
    os_log(
      .info,
      log: Self.diagnostics,
      "component=model event=spaces-publish count=%{public}d changed=%{public}d",
      nextSpaces.count,
      changed ? 1 : 0
    )
  }

  private func updateChatProjectionReadiness() {
    let nextReady: Bool
    switch source {
    case .home:
      nextReady = hasReceivedChatValue
    case let .space(spaceID, _):
      nextReady = hasReceivedChatValue
        && hasResolvedSpaces
        && spaces.contains(where: { $0.id == spaceID })
    case nil:
      nextReady = false
    }
    if isChatProjectionReady != nextReady {
      isChatProjectionReady = nextReady
      let heldMilliseconds = sourceBindStartedAt.map {
        Int(((ProcessInfo.processInfo.systemUptime - $0) * 1_000).rounded())
      } ?? 0
      os_log(
        .info,
        log: Self.diagnostics,
        "component=model event=readiness ready=%{public}d source=%{public}@ held-ms=%{public}d chat-value=%{public}d spaces-resolved=%{public}d",
        nextReady ? 1 : 0,
        (source?.diagnosticCode ?? "none") as NSString,
        heldMilliseconds,
        hasReceivedChatValue ? 1 : 0,
        hasResolvedSpaces ? 1 : 0
      )
      if nextReady {
        sourceBindStartedAt = nil
        PerformanceTrace.event(
          "SidebarModelReadyForLaunch",
          category: .launch,
          "active=\(activeItems.count) archived=\(archivedItems.count) temporary=\(temporaryItems.count)"
        )
        os_signpost(
          .event,
          log: Self.signposts,
          name: "SidebarModelReady",
          "active=%{public}d archived=%{public}d temporary=%{public}d",
          activeItems.count,
          archivedItems.count,
          temporaryItems.count
        )
      }
    }
  }

  private func refreshItems() {
    let items = sortItems(filterHomeItems(snapshots))
    let kind: ChatListItem.Kind = isHomeSource ? .thread : .contact
    let projectedItems = items.map {
      Item(snapshot: $0, kind: isUserPeer($0.peer) ? kind : .thread)
    }

    if isInboxMode {
      let active = projectedItems.filter { $0.open || $0.pinned }
      let temporary = makeTemporaryItems(from: projectedItems, excluding: active)
      let activeChanged = activeItems != active
      let archivedChanged = archivedItems.isEmpty == false
      let temporaryChanged = temporaryItems != temporary
      if activeChanged {
        activeItems = active
      }
      if archivedChanged {
        archivedItems = []
      }
      if temporaryChanged {
        temporaryItems = temporary
      }
      return
    }

    let active = projectedItems.filter { $0.archived == false }

    let archived = projectedItems.filter(\.archived)

    let activeChanged = activeItems != active
    let archivedChanged = archivedItems != archived
    let temporaryChanged = temporaryItems.isEmpty == false
    if activeChanged {
      activeItems = active
    }
    if archivedChanged {
      archivedItems = archived
    }
    if temporaryChanged {
      temporaryItems = []
    }
  }

  private func makeTemporaryItems(from items: [Item], excluding active: [Item]) -> [Item] {
    guard let temporaryPeer,
          active.contains(where: { $0.peerId == temporaryPeer }) == false,
          let selected = items.first(where: { $0.peerId == temporaryPeer })
    else { return [] }

    var result: [Item] = []
    if let parentChatId = selected.parentChatId,
       let parent = items.first(where: { $0.chatId == parentChatId }),
       active.contains(where: { $0.peerId == parent.peerId }) == false {
      result.append(parent)
    }
    if result.contains(where: { $0.peerId == selected.peerId }) == false {
      result.append(selected)
    }
    return result
  }

  private func filterHomeItems(_ items: [ChatListItemSnapshot]) -> [ChatListItemSnapshot] {
    guard includeSpaceChatsInHome == false else { return items }
    guard isHomeSource else { return items }
    return items.filter { $0.spaceID == nil }
  }

  private func sortItems(_ items: [ChatListItemSnapshot]) -> [ChatListItemSnapshot] {
    if isInboxMode {
      return sortInboxItems(items)
    }

    return items.sorted { lhs, rhs in
      let pinned1 = lhs.isPinned
      let pinned2 = rhs.isPinned
      if pinned1 != pinned2 { return pinned1 }

      if pinned1, pinned2 {
        return ordered(lhs.pinnedOrder, before: rhs.pinnedOrder, lhs: lhs, rhs: rhs)
      }

      let date1 = sortDate(for: lhs)
      let date2 = sortDate(for: rhs)
      if date1 == date2 {
        return stableOrder(lhs, rhs)
      }
      return date1 > date2
    }
  }

  private var isInboxMode: Bool {
    switch source {
    case .home(.inbox), .space(_, .inbox):
      true
    case .home(.chatList), .space(_, .chatList), nil:
      false
    }
  }

  private var isHomeSource: Bool {
    switch source {
    case .home:
      true
    case .space, nil:
      false
    }
  }

  private func sortInboxItems(_ items: [ChatListItemSnapshot]) -> [ChatListItemSnapshot] {
    return items.sorted { lhs, rhs in
      let pinned1 = lhs.isPinned
      let pinned2 = rhs.isPinned
      if pinned1 != pinned2 { return pinned1 }
      if pinned1, pinned2 {
        return ordered(lhs.pinnedOrder, before: rhs.pinnedOrder, lhs: lhs, rhs: rhs)
      }

      switch sortMode {
      case .openedOrder:
        return ordered(lhs.order, before: rhs.order, lhs: lhs, rhs: rhs)
      case .recentActivity:
        let lhsActivity = sortDate(for: lhs)
        let rhsActivity = sortDate(for: rhs)
        if lhsActivity != rhsActivity {
          return lhsActivity > rhsActivity
        }
        return stableOrder(lhs, rhs)
      }
    }
  }

  private func stableOrder(_ lhs: ChatListItemSnapshot, _ rhs: ChatListItemSnapshot) -> Bool {
    lhs.dialogID > rhs.dialogID
  }

  private func ordered(
    _ lhsOrder: String?,
    before rhsOrder: String?,
    lhs: ChatListItemSnapshot,
    rhs: ChatListItemSnapshot
  ) -> Bool {
    switch (lhsOrder, rhsOrder) {
    case let (lhsOrder?, rhsOrder?):
      if lhsOrder != rhsOrder {
        return lhsOrder < rhsOrder
      }
      return stableOrder(lhs, rhs)
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    case (nil, nil):
      return stableOrder(lhs, rhs)
    }
  }

  private func sortDate(for item: ChatListItemSnapshot) -> Date {
    item.lastUpdatedAt ?? .distantPast
  }

  private func isUserPeer(_ peer: Peer) -> Bool {
    if case .user = peer { return true }
    return false
  }

  private nonisolated static func safeErrorName(_ error: Error) -> String {
    if let error = error as? RowDecodingError {
      return safeRowDecodingErrorName(error)
    }
    if let error = error as? DatabaseError {
      return "DatabaseError(\(error.resultCode.rawValue))"
    }
    return String(reflecting: type(of: error))
  }

  /// GRDB's full decoding description includes the entire row. Extract only
  /// schema/type tokens so diagnostics identify the defect without logging
  /// names, message previews, IDs, SQL arguments, or other user data.
  private nonisolated static func safeRowDecodingErrorName(
    _ error: RowDecodingError
  ) -> String {
    let description = error.description
    let expectedType = safeDiagnosticToken(
      between: "could not decode ",
      and: " from database value",
      in: description
    )
    let column = description
      .split(separator: "\n")
      .lazy
      .compactMap { line -> String? in
        let prefix = "column: "
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(prefix) else { return nil }
        return safeDiagnosticToken(String(trimmed.dropFirst(prefix.count)))
      }
      .first
      ?? safeDiagnosticToken(
        after: "column not found: ",
        in: description
      )
    return "RowDecodingError(type=\(expectedType ?? "unknown"),column=\(column ?? "unknown"))"
  }

  private nonisolated static func safeDiagnosticToken(
    between prefix: String,
    and suffix: String,
    in value: String
  ) -> String? {
    guard let start = value.range(of: prefix)?.upperBound,
          let end = value[start...].range(of: suffix)?.lowerBound
    else { return nil }
    return safeDiagnosticToken(String(value[start ..< end]))
  }

  private nonisolated static func safeDiagnosticToken(
    after prefix: String,
    in value: String
  ) -> String? {
    guard let start = value.range(of: prefix)?.upperBound else { return nil }
    let tail = value[start...].prefix { $0 != "\n" }
    return safeDiagnosticToken(String(tail))
  }

  private nonisolated static func safeDiagnosticToken(_ value: String) -> String? {
    let token = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
    guard token.isEmpty == false,
          token.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0)
              || CharacterSet(charactersIn: "._[]?<>-").contains($0)
          })
    else { return nil }
    return String(token.prefix(80))
  }
}
