import Combine
import Foundation
import GRDB
import InlineKit
import Logger
import Observation

@MainActor
@Observable
final class SidebarViewModel {
  struct Item: Equatable, Identifiable {
    let id: ChatListItem.Identifier
    let peerId: Peer
    let chatId: Int64
    let spaceId: Int64?
    let title: String
    let preview: String
    let unread: Bool
    let pinned: Bool
    let archived: Bool
    let peer: ChatIcon.PeerType?

    init?(listItem: ChatListItem) {
      guard let peerId = listItem.peerId else { return nil }

      id = listItem.id
      self.peerId = peerId
      chatId = listItem.chat?.id ?? 0
      spaceId = listItem.spaceId
      let isCurrentUser = listItem.user?.user.isCurrentUser() == true
      title = isCurrentUser ? "Saved Messages" : listItem.displayTitle
      preview = listItem.sidebarBasePreviewText
      unread = listItem.hasUnread
      pinned = listItem.dialog?.pinned == true
      archived = listItem.dialog?.archived == true

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
  var errorText: String?

  @ObservationIgnored private let log = Log.scoped("SidebarViewModel")
  @ObservationIgnored private let db: AppDatabase
  @ObservationIgnored private var source: Source?
  @ObservationIgnored private var threadItems: [ChatListItem] = []
  @ObservationIgnored private var contactItems: [ChatListItem] = []
  @ObservationIgnored private var threadsCancellable: AnyCancellable?
  @ObservationIgnored private var contactsCancellable: AnyCancellable?
  @ObservationIgnored private var spacesCancellable: AnyCancellable?
  @ObservationIgnored private var started = false

  private enum Source: Equatable {
    case home
    case space(Int64)
  }

  init(
    db: AppDatabase,
    startsObserving: Bool = true,
    selectedSpaceId: Int64? = nil
  ) {
    self.db = db
    if startsObserving {
      start(selectedSpaceId: selectedSpaceId)
    }
  }

  func start(selectedSpaceId: Int64?) {
    if started == false {
      started = true
      observeSpaces()
    }

    if let selectedSpaceId {
      bindSource(.space(selectedSpaceId))
    } else {
      bindSource(.home)
    }
  }

  func selectHome() {
    start(selectedSpaceId: nil)
  }

  func selectSpace(_ spaceId: Int64) {
    start(selectedSpaceId: spaceId)
  }

  func space(id: Int64?) -> Space? {
    guard let id else { return nil }
    return spaces.first { $0.id == id }
  }

  func hasSpace(id: Int64) -> Bool {
    spaces.contains { $0.id == id }
  }

  private func bindSource(_ source: Source) {
    guard self.source != source else { return }
    self.source = source
    threadsCancellable?.cancel()
    contactsCancellable?.cancel()
    threadsCancellable = nil
    contactsCancellable = nil

    threadItems = []
    contactItems = []
    activeItems = []
    archivedItems = []
    errorText = nil

    switch source {
      case .home:
        bindHomeChats()
      case let .space(spaceId):
        bindSpaceChats(spaceId)
        bindSpaceContacts(spaceId)
    }
  }

  private func bindHomeChats() {
    #if DEBUG
    db.warnIfInMemoryDatabaseForObservation("SidebarViewModel.chats")
    #endif

    threadsCancellable = ValueObservation
      .tracking { db in
        try HomeChatItem.all().fetchAll(db)
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
          let filtered = HomeViewModel.filterEmptyChats(chats)
          threadItems = filtered.map(ChatListItem.init(chatItem:))
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
        try Dialog
          .sidebarSpaceChatItemQuery(spaceId: spaceId)
          .fetchAll(db)
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
          threadItems = chats.map(ChatListItem.init(spaceChatItem:))
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
        try Dialog
          .spaceChatItemQueryForUser()
          .filter(
            sql: "dialog.peerUserId IN (SELECT userId FROM member WHERE spaceId = ?)",
            arguments: StatementArguments([spaceId])
          )
          .fetchAll(db)
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
          contactItems = contacts.map(ChatListItem.init(spaceContactItem:))
          refreshItems()
        }
      )
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
    let items = sortItems(mergeUniqueItems(threadItems + contactItems))

    activeItems = items
      .filter { $0.dialog?.archived != true }
      .compactMap(Item.init(listItem:))

    archivedItems = items
      .filter { $0.dialog?.archived == true }
      .compactMap(Item.init(listItem:))
  }

  private func mergeUniqueItems(_ items: [ChatListItem]) -> [ChatListItem] {
    var seen = Set<ChatListItem.Identifier>()
    return items.filter { item in
      seen.insert(item.id).inserted
    }
  }

  private func sortItems(_ items: [ChatListItem]) -> [ChatListItem] {
    items.sorted { lhs, rhs in
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

  private func stableOrder(_ lhs: ChatListItem, _ rhs: ChatListItem) -> Bool {
    if lhs.id.rawValue != rhs.id.rawValue {
      return lhs.id.rawValue > rhs.id.rawValue
    }
    return lhs.id.kind.rawValue > rhs.id.kind.rawValue
  }

  private func sortDate(for item: ChatListItem) -> Date {
    item.lastMessage?.message.date
      ?? item.chat?.date
      ?? item.member?.date
      ?? Date.distantPast
  }
}
