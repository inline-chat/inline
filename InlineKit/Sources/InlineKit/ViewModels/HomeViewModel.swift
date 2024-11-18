import Combine
import GRDB

public struct HomeChatItem: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable, Identifiable {
  public var dialog: Dialog
  public var user: User
  public var chat: Chat?
  public var message: Message?
  
  public var id: Int64 { user.id }
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
                  .including(optional: Chat.lastMessage))
          )
          .asRequest(of: HomeChatItem.self)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { _ in /* ignore error */ },
        receiveValue: { [weak self] chats in

          self?.chats = chats
        }
      )
  }
}
