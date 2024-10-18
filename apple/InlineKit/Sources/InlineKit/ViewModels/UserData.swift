import Combine
import GRDB

public final class UserDataViewModel: ObservableObject {
    /// The spaces to display.
    @Published public private(set) var user: User?

    private var cancellable: AnyCancellable?

    private var db: AppDatabase
    private var userId: Int64
    public init(db: AppDatabase, userId: Int64) {
        self.db = db
        self.userId = userId
        getUserData()
    }

    func getUserData() {
        cancellable = ValueObservation
            .tracking { db in
                try User.fetchOne(db, id: self.userId)
            }
            .publisher(in: db.dbWriter, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in /* ignore error */ },
                receiveValue: { [weak self] user in
                    self?.user = user
                })
    }
}
