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

  @Published private(set) var threads: [ChatListItem] = []
  @Published private(set) var contacts: [ChatListItem] = []
  @Published private(set) var archivedChats: [ChatListItem] = []
  @Published private(set) var archivedContacts: [ChatListItem] = []

  private let source: Source
  private let db: AppDatabase
  private let log = Log.scoped("SidebarDebug")

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
        contacts = []
        archivedContacts = []
      case let .space(id):
        bindSpaceChats(spaceId: id)
        bindSpaceContacts(spaceId: id)
    }
  }

  private func bindHomeChats() {
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
                self.log.error("[SidebarDebug] home observation failed: \(error.localizedDescription)")
            }
          },
          receiveValue: { [weak self] chats in
            guard let self else { return }
            // Home shows non-archived chats without a space. Treat nil archived as not archived.
            let spaceScoped = chats.filter { $0.space == nil }
            let sorted = HomeViewModel.sortChats(spaceScoped)
            let archived = sorted.filter { $0.dialog.archived == true }
            let active = sorted.filter { ($0.dialog.archived ?? false) == false }
            self.threads = active.map(ChatListItem.init(chatItem:))
            self.archivedChats = archived.map(ChatListItem.init(chatItem:))
            log.debug("[SidebarDebug] home chats total=\(chats.count) spaceNil=\(spaceScoped.count) active=\(active.count) archived=\(archived.count)")
          }
        )
  }

  private func bindSpaceChats(spaceId: Int64) {
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
            let sorted = self.sortSpaceChatItems(chats)
            let archived = sorted.filter { $0.dialog.archived == true }
            let active = sorted.filter { $0.dialog.archived != true }
            self.threads = active.map(ChatListItem.init(spaceChatItem:))
            self.archivedChats = archived.map(ChatListItem.init(spaceChatItem:))
          }
        )
  }

  private func bindSpaceContacts(spaceId: Int64) {
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
            let sorted = self.sortSpaceChatItems(items)
            let active = sorted.filter { $0.dialog.archived != true }
            let archived = sorted.filter { $0.dialog.archived == true }
            self.contacts = active.map(ChatListItem.init(spaceContactItem:))
            self.archivedContacts = archived.map(ChatListItem.init(spaceContactItem:))
          }
        )
  }

  private func sortSpaceChatItems(_ chats: [SpaceChatItem]) -> [SpaceChatItem] {
    chats.sorted { lhs, rhs in
      let pinned1 = lhs.dialog.pinned ?? false
      let pinned2 = rhs.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }
      let date1 = lhs.message?.date ?? lhs.chat?.date ?? Date.distantPast
      let date2 = rhs.message?.date ?? rhs.chat?.date ?? Date.distantPast
      return date1 > date2
    }
  }
}
