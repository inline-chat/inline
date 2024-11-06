import Combine
import GRDB

public struct ChatItem: Codable, FetchableRecord, PersistableRecord, @unchecked Sendable, Hashable {
    public var chat: Chat
    public var user: User?
    public var message: Message?
}

public final class HomeViewModel: ObservableObject, @unchecked Sendable {
    @Published public private(set) var chats: [ChatItem] = []

    private var cancellable: AnyCancellable?
    private var db: AppDatabase
    public init(db: AppDatabase) {
        self.db = db
        start()
    }

    func start() {
        cancellable = ValueObservation
            .tracking { db in
                try Chat
                    .filter(Column("spaceId") == nil)
                    .including(optional: Chat.peerUser)
                    .including(optional: Chat.lastMessage)
                    .asRequest(of: ChatItem.self)
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
