import Combine
import Foundation
import GRDB
import Logger

public struct SpaceChatItem: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable,
  Identifiable
{
  public var dialog: Dialog
  // Useful for threads
  public var chat: Chat? // made optional as when optimistic, this is fake, maybe will change
  // Only for private chats
  public var userInfo: UserInfo?
  public var user: User? {
    userInfo?.user
  }

  // Last message
  public var message: Message?
  public var from: UserInfo?
  public var translations: [Translation] = []
  public var photoInfo: PhotoInfo?
  // ------ GETTERS ----------
  // Peer user
  public var peerId: Peer {
    dialog.peerId
  }

  public var title: String? {
    if let user {
      user.fullName
    } else {
      chat?.humanReadableTitle
    }
  }

  public var id: Int64 {
    dialog.id
  }

  public init(
    dialog: Dialog,
    chat: Chat? = nil,
    userInfo: UserInfo? = nil,
    message: Message? = nil,
    from: UserInfo? = nil,
    translations: [Translation] = [],
    photoInfo: PhotoInfo? = nil
  ) {
    self.dialog = dialog
    self.chat = chat
    self.userInfo = userInfo
    self.message = message
    self.from = from
    self.translations = translations
    self.photoInfo = photoInfo
  }
}

public struct FullMemberItem: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable,
  Identifiable
{
  public var member: Member
  public var userInfo: UserInfo

  public var id: Int64 {
    member.id
  }
}

// Used for space home sidebar
public final class FullSpaceViewModel: ObservableObject {
  /// The spaces to display.
  @Published public private(set) var space: Space?
  @Published public private(set) var memberChats: [SpaceChatItem] = []
  @Published public private(set) var chats: [SpaceChatItem] = []
  @Published public private(set) var members: [FullMemberItem] = []

  public var filteredMemberChats: [SpaceChatItem] {
    memberChats
  }

  public var filteredChats: [SpaceChatItem] {
    chats
  }

  private var spaceSancellable: AnyCancellable?
  private var membersSancellable: AnyCancellable?
  private var membersChatsSancellable: AnyCancellable?
  private var chatsSancellable: AnyCancellable?

  private var db: AppDatabase
  private var spaceId: Int64
  public init(db: AppDatabase, spaceId: Int64) {
    self.db = db
    self.spaceId = spaceId
    fetchSpace()
    fetchMembersChats()
    fetchChats()
    fetchMembers()
  }

  func fetchSpace() {
    let spaceId = spaceId
    db.warnIfInMemoryDatabaseForObservation("FullSpaceViewModel.space")
    spaceSancellable =
      ValueObservation
        .tracking { db in
          try Space.fetchOne(db, id: spaceId)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in
            Log.shared.error("failed to fetch space in space view model. error: \(error)")
          },
          receiveValue: { [weak self] space in
            self?.space = space
          }
        )
  }

  public func fetchMembersChats() {
    let spaceId = spaceId
    db.warnIfInMemoryDatabaseForObservation("FullSpaceViewModel.memberChats")
    membersChatsSancellable =
      ValueObservation
        .tracking { db in
          try Member
            .spaceChatItemRequest()
            .filter(Column("spaceId") == spaceId)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in
            Log.shared.error("failed to fetch members in space view model. error: \(error)")
          },
          receiveValue: { [weak self] members in
            // Log.shared.debug("got list of members chats \(members)")
            self?.memberChats = members
//              .filter { chat in
//              // For now, filter chats with users who are pending setup
//              chat.userInfo?.user.pendingSetup != true
//            }
          }
        )
  }

  public func fetchMembers() {
    let spaceId = spaceId
    db.warnIfInMemoryDatabaseForObservation("FullSpaceViewModel.members")
    membersSancellable =
      ValueObservation
        .tracking { db in
          try Member
            .fullMemberQuery()
            .filter(Column("spaceId") == spaceId)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { _ in /* ignore error */ },
          receiveValue: { [weak self] members in
            // Log.shared.debug("got list of members \(members)")
            self?.members = members
          }
        )
  }

  func fetchChats() {
    let spaceId = spaceId
    db.warnIfInMemoryDatabaseForObservation("FullSpaceViewModel.chats")
    chatsSancellable =
      ValueObservation
        .tracking { db in
          try Dialog
            .spaceChatItemQuery()
            .filter(Column("spaceId") == spaceId)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in
            Log.shared.error("failed to fetch chats in space view model. error: \(error)")
          },
          receiveValue: { [weak self] chats in
            guard let self else { return }
            self.chats = sortChats(chats)
          }
        )
  }

  private func sortChats(_ chats: [SpaceChatItem]) -> [SpaceChatItem] {
    chats.sorted { item1, item2 in
      // First sort by pinned status
      let pinned1 = item1.dialog.pinned ?? false
      let pinned2 = item2.dialog.pinned ?? false
      if pinned1 != pinned2 { return pinned1 }

      // Then sort by date
      let date1 = item1.message?.date ?? item1.chat?.date ?? Date.distantPast
      let date2 = item2.message?.date ?? item2.chat?.date ?? Date.distantPast
      return date1 > date2
    }
  }
}
