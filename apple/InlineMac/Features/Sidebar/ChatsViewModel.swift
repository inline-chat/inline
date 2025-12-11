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

  private let source: Source
  private let db: AppDatabase
  private let log = Log.scoped("SidebarDebug")

  private var cancellables = Set<AnyCancellable>()
  private var memberUserCancellables = Set<AnyCancellable>()
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
            let filtered = sorted.filter { ($0.dialog.archived ?? false) == false }
            self.threads = filtered.map(ChatListItem.init(chatItem:))
            log.debug("[SidebarDebug] home chats total=\(chats.count) spaceNil=\(spaceScoped.count) visible=\(filtered.count)")
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
            let sorted = chats.sorted { lhs, rhs in
              let pinned1 = lhs.dialog.pinned ?? false
              let pinned2 = rhs.dialog.pinned ?? false
              if pinned1 != pinned2 { return pinned1 }
              let date1 = lhs.message?.date ?? lhs.chat?.date ?? Date.distantPast
              let date2 = rhs.message?.date ?? rhs.chat?.date ?? Date.distantPast
              return date1 > date2
            }
            self.threads = sorted.map(ChatListItem.init(spaceChatItem:))
          }
        )
  }

  private func bindSpaceContacts(spaceId: Int64) {
    contactsCancellable =
      ValueObservation
        .tracking { db in
          try Member
            .fullMemberQuery()
            .filter(Column("spaceId") == spaceId)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .receive(on: DispatchQueue.main)
        .sink(
          receiveCompletion: { _ in },
          receiveValue: { [weak self] members in
            guard let self else { return }
            self.contacts = members.map { ChatListItem(member: $0.member, user: $0.userInfo) }
            self.subscribeToMemberUsers(members.map(\.member))
          }
        )
  }

  private func subscribeToMemberUsers(_ members: [Member]) {
    memberUserCancellables.removeAll()
    for member in members {
      ObjectCache.shared.getUserPublisher(id: member.userId)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
          guard let self else { return }
          Task { @MainActor in
            self.contacts = self.contacts.map { item in
              guard
                item.kind == .contact,
                item.member?.id == member.id
              else { return item }
              let user = ObjectCache.shared.getUser(id: member.userId)
              return ChatListItem(member: member, user: user)
            }
          }
        }
        .store(in: &memberUserCancellables)
    }
  }
}
