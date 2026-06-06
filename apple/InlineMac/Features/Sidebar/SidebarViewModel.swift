import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation

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
    let spaceId: Int64?
    let title: String
    let parentTitle: String?
    let preview: String
    let unread: Bool
    let pinned: Bool
    let archived: Bool
    let open: Bool
    let order: String?
    let pinnedOrder: String?
    let peer: ChatIcon.PeerType?

    init?(listItem: ChatListItem) {
      guard let peerId = listItem.peerId else { return nil }

      id = listItem.id
      self.peerId = peerId
      chatId = listItem.chat?.id ?? 0
      spaceId = listItem.spaceId
      let isCurrentUser = listItem.user?.user.isCurrentUser() == true
      title = isCurrentUser ? "Saved Messages" : listItem.displayTitle
      parentTitle = listItem.parentTitle
      preview = listItem.sidebarBasePreviewText
      unread = listItem.hasUnread
      pinned = listItem.dialog?.pinned == true
      archived = listItem.dialog?.archived == true
      open = listItem.dialog?.open == true
      order = listItem.dialog?.order
      pinnedOrder = listItem.dialog?.pinnedOrder

      if let user = listItem.user {
        peer = isCurrentUser ? .savedMessage(user.user) : .user(user)
      } else if let chat = listItem.chat {
        peer = .chat(chat)
      } else {
        peer = nil
      }
    }
  }

  var activeItems: [Item] = []
  var archivedItems: [Item] = []
  var spaces: [Space] = []
  var todayUnreadCount = 0
  var errorText: String?

  @ObservationIgnored private let log = Log.scoped("SidebarViewModel")
  @ObservationIgnored private let db: AppDatabase
  @ObservationIgnored private var source: Source?
  @ObservationIgnored private var threadItems: [ChatListItem] = []
  @ObservationIgnored private var contactItems: [ChatListItem] = []
  @ObservationIgnored private var threadsCancellable: AnyCancellable?
  @ObservationIgnored private var contactsCancellable: AnyCancellable?
  @ObservationIgnored private var spacesCancellable: AnyCancellable?
  @ObservationIgnored private var todayUnreadCountCancellable: AnyCancellable?
  @ObservationIgnored private var includeSpaceChatsInHome = true
  @ObservationIgnored private var started = false

  private enum Source: Equatable {
    case home(ContentMode)
    case space(Int64, ContentMode)

    var isInbox: Bool {
      switch self {
      case .home(.inbox), .space(_, .inbox):
        true
      case .home(.chatList), .space(_, .chatList):
        false
      }
    }

    var spaceId: Int64? {
      switch self {
      case .home:
        nil
      case let .space(spaceId, _):
        spaceId
      }
    }
  }

  init(
    db: AppDatabase,
    startsObserving: Bool = true,
    selectedSpaceId: Int64? = nil,
    mode: ContentMode = .chatList
  ) {
    self.db = db
    if startsObserving {
      start(selectedSpaceId: selectedSpaceId, mode: mode)
    }
  }

  func start(selectedSpaceId: Int64?, mode: ContentMode = .chatList) {
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

  func setIncludeSpaceChatsInHome(_ include: Bool) {
    guard includeSpaceChatsInHome != include else { return }
    includeSpaceChatsInHome = include
    if source?.isInbox == true {
      todayUnreadCountCancellable?.cancel()
      todayUnreadCount = 0
      bindTodayUnreadCount(spaceId: source?.spaceId)
    }
    refreshItems()
  }

  private func bindSource(_ source: Source) {
    guard self.source != source else { return }
    self.source = source
    threadsCancellable?.cancel()
    contactsCancellable?.cancel()
    todayUnreadCountCancellable?.cancel()
    threadsCancellable = nil
    contactsCancellable = nil
    todayUnreadCountCancellable = nil

    threadItems = []
    contactItems = []
    activeItems = []
    archivedItems = []
    todayUnreadCount = 0
    errorText = nil

    if source.isInbox {
      bindTodayUnreadCount(spaceId: source.spaceId)
    }

    switch source {
      case .home(.chatList):
        bindHomeChats()
      case let .space(spaceId, .chatList):
        bindSpaceChats(spaceId)
        bindSpaceContacts(spaceId)
      case .home(.inbox):
        bindInboxItems(spaceId: nil)
      case let .space(spaceId, .inbox):
        bindInboxItems(spaceId: spaceId)
    }
  }

  private func bindInboxItems(spaceId: Int64?) {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.inbox")
    #endif

    threadsCancellable = ValueObservation
      .tracking { db in
        let chats = try HomeChatItem
          .sidebarInbox(spaceId: spaceId)
          .fetchAll(db)
        return try Self.chatListItems(chats, db: db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Sidebar inbox observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] chats in
          guard let self else { return }
          threadItems = chats
          contactItems = []
          refreshItems()
        }
      )
  }

  private func bindTodayUnreadCount(spaceId: Int64?) {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.todayUnreadCount")
    #endif

    let includeSpaceChats = includeSpaceChatsInHome
    todayUnreadCountCancellable = ValueObservation
      .tracking { database in
        try Self.fetchTodayUnreadCount(
          database,
          spaceId: spaceId,
          includeSpaceChatsInHome: includeSpaceChats
        )
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Sidebar all chats unread count observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] count in
          self?.todayUnreadCount = count
        }
      )
  }

  private func bindHomeChats() {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.chats")
    #endif

    threadsCancellable = ValueObservation
      .tracking { db in
        let chats = try HomeChatItem.all().fetchAll(db)
        return try Self.chatListItems(chats, db: db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }

          switch completion {
            case .finished:
              break
            case let .failure(error):
              errorText = error.localizedDescription
              log.error("Sidebar observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] chats in
          guard let self else { return }
          threadItems = chats
          contactItems = []
          refreshItems()
        }
      )
  }

  private func bindSpaceChats(_ spaceId: Int64) {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.spaceChats")
    #endif

    threadsCancellable = ValueObservation
      .tracking { db in
        let chats = try Dialog
          .sidebarSpaceChatItemQuery(spaceId: spaceId)
          .fetchAll(db)
        return try Self.chatListItems(chats, db: db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Sidebar space chats observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] chats in
          guard let self else { return }
          threadItems = chats
          refreshItems()
        }
      )
  }

  private func bindSpaceContacts(_ spaceId: Int64) {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.spaceContacts")
    #endif

    contactsCancellable = ValueObservation
      .tracking { db in
        let contacts = try Dialog.applyingChatListVisibilityFilter(
          Dialog.spaceChatItemQueryForUser()
        )
          .filter(
            sql: "dialog.peerUserId IN (SELECT userId FROM member WHERE spaceId = ?)",
            arguments: StatementArguments([spaceId])
          )
          .fetchAll(db)
        return try Self.chatListItems(contacts, db: db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          if case let .failure(error) = completion {
            self?.log.error("Sidebar space contacts observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] contacts in
          guard let self else { return }
          contactItems = contacts
          refreshItems()
        }
      )
  }

  private nonisolated static func chatListItems(_ chats: [HomeChatItem], db: Database) throws -> [ChatListItem] {
    let filteredChats = HomeViewModel.filterEmptyChats(chats)
    let titles = try ReplyThreadTitleFallback.titlesByChatId(for: filteredChats, db: db)
    let parentTitles = try ReplyThreadTitleFallback.parentTitlesByChatId(for: filteredChats, db: db)
    return filteredChats.map { chat in
      ChatListItem(
        chatItem: chat,
        titleOverride: chat.chat.flatMap { titles[$0.id] },
        parentTitle: chat.chat.flatMap { parentTitles[$0.id] }
      )
    }
  }

  private nonisolated static func chatListItems(_ items: [SpaceChatItem], db: Database) throws -> [ChatListItem] {
    let chats = items.compactMap(\.chat)
    let titles = try ReplyThreadTitleFallback.titlesByChatId(for: chats, db: db)
    let parentTitles = try ReplyThreadTitleFallback.parentTitlesByChatId(for: chats, db: db)

    return items.map { item in
      let titleOverride = item.chat.flatMap { titles[$0.id] }
      let parentTitle = item.chat.flatMap { parentTitles[$0.id] }
      if item.userInfo != nil {
        return ChatListItem(spaceContactItem: item, titleOverride: titleOverride, parentTitle: parentTitle)
      }
      return ChatListItem(spaceChatItem: item, titleOverride: titleOverride, parentTitle: parentTitle)
    }
  }

  private func observeSpaces() {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.spaces")
    #endif

    spacesCancellable = ValueObservation
      .tracking { db in
        try Space
          .including(all: Space.members)
          .order(Space.Columns.id)
          .asRequest(of: HomeSpaceItem.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard let self else { return }

          switch completion {
            case .finished:
              break
            case let .failure(error):
              log.error("Sidebar spaces observation failed: \(error.localizedDescription)")
          }
        },
        receiveValue: { [weak self] spaces in
          self?.applySpaces(spaces)
        }
      )
  }

  private func applySpaces(_ spaces: [HomeSpaceItem]) {
    self.spaces = spaces.map(\.space)
  }

  private func refreshItems() {
    let items = sortItems(filterHomeItems(mergeUniqueItems(threadItems + contactItems)))

    if isInboxMode {
      let active = items.compactMap(Item.init(listItem:))
      activeItems = active
      archivedItems = []
      return
    }

    let active = items
      .filter { $0.dialog?.archived != true }
      .compactMap(Item.init(listItem:))

    let archived = items
      .filter { $0.dialog?.archived == true }
      .compactMap(Item.init(listItem:))

    activeItems = active
    archivedItems = archived
  }

  private func mergeUniqueItems(_ items: [ChatListItem]) -> [ChatListItem] {
    var seen = Set<ChatListItem.Identifier>()
    return items.filter { item in
      seen.insert(item.id).inserted
    }
  }

  private func filterHomeItems(_ items: [ChatListItem]) -> [ChatListItem] {
    guard includeSpaceChatsInHome == false else { return items }
    guard isHomeSource else { return items }
    return items.filter { $0.isSpaceScoped == false }
  }

  private func sortItems(_ items: [ChatListItem]) -> [ChatListItem] {
    if isInboxMode {
      return sortInboxItems(items)
    }

    return items.sorted { lhs, rhs in
      let pinned1 = lhs.dialog?.pinned ?? false
      let pinned2 = rhs.dialog?.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      if pinned1, pinned2 {
        return stableOrder(lhs, rhs)
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

  private func sortInboxItems(_ items: [ChatListItem]) -> [ChatListItem] {
    return items.sorted { lhs, rhs in
      let pinned1 = lhs.dialog?.pinned ?? false
      let pinned2 = rhs.dialog?.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      if pinned1, pinned2 {
        return ordered(lhs.dialog?.pinnedOrder, before: rhs.dialog?.pinnedOrder, lhs: lhs, rhs: rhs)
      }

      return ordered(lhs.dialog?.order, before: rhs.dialog?.order, lhs: lhs, rhs: rhs)
    }
  }

  private nonisolated static func fetchTodayUnreadCount(
    _ db: Database,
    spaceId: Int64?,
    includeSpaceChatsInHome: Bool
  ) throws -> Int {
    let calendar = Calendar.autoupdatingCurrent
    let start = calendar.startOfDay(for: Date())
    let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
    let spaceFilter: String
    var arguments = StatementArguments([start, end])

    if let spaceId {
      spaceFilter = """
      AND COALESCE("dialog"."spaceId", "chat"."spaceId") = ?
      """
      arguments += StatementArguments([spaceId])
    } else if includeSpaceChatsInHome == false {
      spaceFilter = """
      AND COALESCE("dialog"."spaceId", "chat"."spaceId") IS NULL
      """
    } else {
      spaceFilter = ""
    }

    let request = SQLRequest<Int>(
      sql: """
      SELECT COUNT(*)
      FROM "dialog"
      LEFT JOIN "chat" ON "chat"."id" = "dialog"."chatId"
      LEFT JOIN "message"
        ON "message"."chatId" = "chat"."id"
        AND "message"."messageId" = "chat"."lastMsgId"
      WHERE \(Dialog.chatListVisibilitySQL)
      AND ("dialog"."archived" IS NULL OR "dialog"."archived" = 0)
      AND (COALESCE("dialog"."unreadCount", 0) > 0 OR "dialog"."unreadMark" = 1)
      AND COALESCE("message"."date", "chat"."date") >= ?
      AND COALESCE("message"."date", "chat"."date") < ?
      \(spaceFilter)
      """,
      arguments: arguments
    )

    return try request.fetchOne(db) ?? 0
  }

  private func stableOrder(_ lhs: ChatListItem, _ rhs: ChatListItem) -> Bool {
    if lhs.id.rawValue != rhs.id.rawValue {
      return lhs.id.rawValue > rhs.id.rawValue
    }
    return lhs.id.kind.rawValue > rhs.id.kind.rawValue
  }

  private func ordered(_ lhsOrder: String?, before rhsOrder: String?, lhs: ChatListItem, rhs: ChatListItem) -> Bool {
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

  private func sortDate(for item: ChatListItem) -> Date {
    item.lastMessage?.message.date
      ?? item.chat?.date
      ?? item.member?.date
      ?? Date.distantPast
  }
}
