import Combine
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
  // ------ GETTERS ----------
  // Peer user
  public var peerId: Peer {
    if let user {
      Peer(userId: user.id)
    } else if let chat {
      Peer(threadId: chat.id)
    } else {
      fatalError("No peer found for space chat item")
    }
  }

  public var title: String? {
    if let user {
      user.fullName
    } else {
      chat?.title ?? nil
    }
  }

  public var id: Int64 {
    dialog.id
  }
}

// Used for space home sidebar
public final class FullSpaceViewModel: ObservableObject {
  /// The spaces to display.
  @Published public private(set) var space: Space?
  @Published public private(set) var memberChats: [SpaceChatItem] = []
  @Published public private(set) var chats: [SpaceChatItem] = []
  @Published public private(set) var members: [Member] = []

  public var filteredMemberChats: [SpaceChatItem] {
    memberChats.filter { $0.dialog.archived == nil || $0.dialog.archived == false }
  }

  public var filteredChats: [SpaceChatItem] {
    chats.filter { $0.dialog.archived == nil || $0.dialog.archived == false }
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
            Log.shared.debug("got list of members chats \(members)")
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
    membersSancellable =
      ValueObservation
        .tracking { db in
          try Member
            .filter(Column("spaceId") == spaceId)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { _ in /* ignore error */ },
          receiveValue: { [weak self] members in
            Log.shared.debug("got list of members \(members)")
            self?.members = members
          }
        )
  }

  func fetchChats() {
    let spaceId = spaceId
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
            self?.chats = chats
          }
        )
  }
}
