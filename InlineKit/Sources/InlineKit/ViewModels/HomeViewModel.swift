import Combine
import GRDB

public final class HomeViewModel: ObservableObject {
    @Published public private(set) var chats: [Chat] = []

    private var cancellable: AnyCancellable?
    private var db: AppDatabase
    public init(db: AppDatabase) {
        self.db = db
        start()
    }

    func start() {
        cancellable = ValueObservation
            .tracking { db in
                try Chat.filter(Column("spaceId") == nil).fetchAll(db)
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
