import Combine
import GRDB
import InlineKit
import Logger

@MainActor
final class ChatsViewModel: ObservableObject {
  enum Source: Equatable, Hashable {
    case home
    case space(id: Int64)
  }

  enum SortStrategy: Equatable {
    case lastActivity
    case creationDate
  }

  struct Items: Equatable {
    let active: [ChatListItem]
    let archived: [ChatListItem]
  }

  @Published private(set) var items: Items = .init(active: [], archived: [])

  private let source: Source
  private let db: AppDatabase
  private let log = Log.scoped("ChatsViewModel")

  private var threadItems: [ChatListItem] = []
  private var contactItems: [ChatListItem] = []
  private var sortStrategy: SortStrategy = .lastActivity

  private var cancellables = Set<AnyCancellable>()
  private var threadsCancellable: AnyCancellable?
  private var contactsCancellable: AnyCancellable?

  init(source: Source, db: AppDatabase) {
    self.source = source
    self.db = db

    start()
  }

  var isSpaceSource: Bool {
    if case .space = source { return true }
    return false
  }

  var spaceId: Int64? {
    if case let .space(id) = source { return id }
    return nil
  }

  private func start() {
    switch source {
      case .home:
        bindHomeChats()
        contactItems = []
        updateItems()
      case let .space(id):
        bindSpaceChats(spaceId: id)
        bindSpaceContacts(spaceId: id)
    }
  }

  private func bindHomeChats() {
    db.warnIfInMemoryDatabaseForObservation("ChatsViewModel.homeChats")
    threadsCancellable =
      ValueObservation
        .tracking { db in
          try HomeChatItem
            .all()
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .receive(on: DispatchQueue.main)
        .sink(
          receiveCompletion: { completion in
            switch completion {
              case .finished:
                break
              case let .failure(error):
                self.log.error("Home observation failed: \(error.localizedDescription)")
            }
          },
          receiveValue: { [weak self] chats in
            guard let self else { return }
            // Home shows chats without a space.
            let spaceScoped = chats.filter { $0.space == nil }
            let filtered = HomeViewModel.filterEmptyChats(spaceScoped)
            threadItems = filtered.map(ChatListItem.init(chatItem:))
            updateItems()
          }
        )
  }

  private func bindSpaceChats(spaceId: Int64) {
    db.warnIfInMemoryDatabaseForObservation("ChatsViewModel.spaceChats")
    threadsCancellable =
      ValueObservation
        .tracking { db in
          try Dialog
            .spaceChatItemQuery()
            .filter(Column("spaceId") == spaceId)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .receive(on: DispatchQueue.main)
        .sink(
          receiveCompletion: { _ in },
          receiveValue: { [weak self] chats in
            guard let self else { return }
            threadItems = chats.map(ChatListItem.init(spaceChatItem:))
            updateItems()
          }
        )
  }

  private func bindSpaceContacts(spaceId: Int64) {
    db.warnIfInMemoryDatabaseForObservation("ChatsViewModel.spaceContacts")
    contactsCancellable =
      ValueObservation
        .tracking { db in
          return try Dialog
            .spaceChatItemQueryForUser()
            .filter(
              sql: "dialog.peerUserId IN (SELECT userId FROM member WHERE spaceId = ?)",
              arguments: StatementArguments([spaceId])
            )
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .receive(on: DispatchQueue.main)
        .sink(
          receiveCompletion: { _ in },
          receiveValue: { [weak self] (items: [SpaceChatItem]) in
            guard let self else { return }
            contactItems = items.map(ChatListItem.init(spaceContactItem:))
            updateItems()
          }
        )
  }

  func setSortStrategy(_ strategy: SortStrategy) {
    guard sortStrategy != strategy else { return }
    sortStrategy = strategy
    updateItems()
  }

  private func updateItems() {
    let combined = mergeUniqueItems(threadItems + contactItems)
    let sorted = sortItems(combined)
    let active = sorted.filter { ($0.dialog?.archived ?? false) == false }
    let archived = sorted.filter { $0.dialog?.archived == true }
    items = Items(active: active, archived: archived)
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
      let date1 = sortDate(for: lhs)
      let date2 = sortDate(for: rhs)
      return date1 > date2
    }
  }

  private func sortDate(for item: ChatListItem) -> Date {
    switch sortStrategy {
      case .lastActivity:
        return item.lastMessage?.message.date
          ?? item.chat?.date
          ?? item.member?.date
          ?? Date.distantPast
      case .creationDate:
        return item.chat?.date
          ?? item.member?.date
          ?? item.lastMessage?.message.date
          ?? Date.distantPast
    }
  }
}
