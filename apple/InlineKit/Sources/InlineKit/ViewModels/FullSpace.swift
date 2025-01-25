import Combine
import GRDB

public struct SpaceChatItem: Codable, FetchableRecord, PersistableRecord, Sendable, Hashable,
  Identifiable
{
  public var dialog: Dialog
  // Useful for threads
  public var chat: Chat? // made optional as when optimistic, this is fake, maybe will change
  // Only for private chats
  public var user: User?
  // Last message
  public var message: Message?

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

  private var spaceSancellable: AnyCancellable?
  private var membersSancellable: AnyCancellable?
  private var chatsSancellable: AnyCancellable?

  private var db: AppDatabase
  private var spaceId: Int64
  public init(db: AppDatabase, spaceId: Int64) {
    self.db = db
    self.spaceId = spaceId
    fetchSpace()
    fetchMembers()
    fetchChats()
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
          receiveCompletion: { _ in /* ignore error */ },
          receiveValue: { [weak self] space in
            self?.space = space
          }
        )
  }

  func fetchMembers() {
    let spaceId = spaceId
    membersSancellable =
      ValueObservation
        .tracking { db in
          try Member.filter(Column("spaceId") == spaceId)
            .including(
              optional: Member.user
                .including(
                  optional: User.chat
                    .including(optional: Chat.lastMessage)
                )
                .including(optional: User.dialog)
            )
            .asRequest(of: SpaceChatItem.self)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { _ in },
          receiveValue: { [weak self] members in
            self?.memberChats = members
          }
        )
  }

  func fetchChats() {
    let spaceId = spaceId
    chatsSancellable =
      ValueObservation
        .tracking { db in
          try Dialog.filter(Column("spaceId") == spaceId)
            .including(
              optional: Dialog.peerThread
                .including(optional: Chat.lastMessage)
            )
            .including(
              optional: Dialog.peerUser
                .including(optional: User.chat)
            )
            .asRequest(of: SpaceChatItem.self)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in
            Log.shared.error("error: \(error)")
          },
          receiveValue: { [weak self] chats in
            self?.chats = chats
          }
        )
  }
}
