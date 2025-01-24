import Combine
import GRDB

public struct HomeChatItem: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable,
  Identifiable
{
  public var dialog: Dialog
  public var user: User
  public var chat: Chat?
  public var message: Message?
  public var from: User?
  public var id: Int64 { user.id }

  public init(dialog: Dialog, user: User, chat: Chat?, message: Message?, from: User?) {
    self.dialog = dialog
    self.user = user
    self.chat = chat
    self.message = message
    self.from = from
  }
}

public final class HomeViewModel: ObservableObject {
  @Published public private(set) var chats: [HomeChatItem] = []

  private var cancellable: AnyCancellable?
  private var db: AppDatabase

  public init(db: AppDatabase) {
    self.db = db
    start()
  }

  func start() {
    cancellable =
      ValueObservation
        .tracking { db in
          try Dialog
            .filter(Column("peerUserId") != nil)

            .including(
              required: Dialog.peerUser
                .including(
                  optional: User.chat
                    .including(
                      optional: Chat.lastMessage
                        .including(optional: Message.from.forKey("from"))
                    )
                )
            )
            .asRequest(of: HomeChatItem.self)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { _ in
            Log.shared.error("Failed to get home chats")
          },
          receiveValue: { [weak self] chats in
            self?.chats = chats
          }
        )
  }
}
