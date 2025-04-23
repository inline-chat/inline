import Auth
import Combine
import GRDB
import Logger

public struct HomeSpaceItem: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var space: Space
  public var members: [Member]

  public var id: Int64 {
    space.id
  }

  public init(space: Space, members: [Member]) {
    self.space = space
    self.members = members
  }
}

public struct UserInfo: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable, Identifiable {
  public var user: User
  public var profilePhoto: [File]?
  public var id: Int64 { user.id }

  // coding keys
  public enum CodingKeys: String, CodingKey {
    case user
    case profilePhoto
  }

  public init(user: User, profilePhotos: [File]? = nil) {
    self.user = user
    profilePhoto = profilePhotos
  }

  public static let deleted = Self(user: .deletedInstance, profilePhotos: nil)
  public static let preview = Self(user: .preview, profilePhotos: nil)
}

public struct HomeChatItem: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable,
  Identifiable
{
  public var dialog: Dialog
  public var user: UserInfo
  public var chat: Chat?
  public var message: Message?
  public var from: User?
  public var id: Int64 { user.id }

  public init(dialog: Dialog, user: UserInfo, chat: Chat?, message: Message?, from: User?) {
    self.dialog = dialog
    self.user = user
    self.chat = chat
    self.message = message
    self.from = from
  }

  // Add a static method to create the request
  static func all() -> QueryInterfaceRequest<HomeChatItem> {
    Dialog
      .including(
        required: Dialog.peerUser
          .forKey(CodingKeys.user)
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .including(
        optional: Dialog.peerUserChat
          .forKey(CodingKeys.chat)
          .including(
            optional: Chat.lastMessage
              .forKey(CodingKeys.message)
              .including(
                optional: Message.from
                  .forKey(CodingKeys.from)
              )
          )
      )
      .asRequest(of: HomeChatItem.self)
  }

  // Add a static method to create the request for space chats
  static func spaceChats(spaceId: Int64) -> QueryInterfaceRequest<HomeChatItem> {
    Dialog
      .filter(Column("spaceId") == spaceId)
      .including(
        required: Dialog.peerUser
          .forKey(CodingKeys.user)
          .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      )
      .including(
        optional: Dialog.peerUserChat
          .forKey(CodingKeys.chat)
          .including(
            optional: Chat.lastMessage
              .forKey(CodingKeys.message)
              .including(
                optional: Message.from
                  .forKey(CodingKeys.from)
              )
          )
      )
      .asRequest(of: HomeChatItem.self)
  }
}

public final class HomeViewModel: ObservableObject {
  @Published public private(set) var chats: [HomeChatItem] = []
  @Published public private(set) var spaces: [HomeSpaceItem] = []

  private var chatsCancellable: AnyCancellable?
  private var spacesCancellable: AnyCancellable?
  private var db: AppDatabase

  public init(db: AppDatabase) {
    self.db = db
    start()
  }

  public func start() {
    fetchChats()
    fetchSpaces()
  }

  private func fetchChats() {
    chatsCancellable = ValueObservation
      .tracking { db in
        try HomeChatItem
          .all()
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("Failed to get home chats \(error)")
        },
        receiveValue: { [weak self] chats in
          self?.chats = chats
        }
      )
  }

  private func fetchSpaces() {
    spacesCancellable = ValueObservation
      .tracking { db in
        try Space
          .including(all: Space.members)
          .asRequest(of: HomeSpaceItem.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("Failed to get home spaces \(error)")
        },
        receiveValue: { [weak self] spaces in
          self?.spaces = spaces
        }
      )
  }
}
