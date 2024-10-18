import Combine
import GRDB

public final class SpaceListViewModel: ObservableObject {
    /// The spaces to display.
    @Published public private(set) var spaces: [Space]?

    private var cancellable: AnyCancellable?
    private var db: AppDatabase
    public init(db: AppDatabase) {
        self.db = db
        start()
    }

    func start() {
        cancellable = ValueObservation
            .tracking { db in
                try Space.fetchAll(db)
            }
            .publisher(in: db.dbWriter, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in /* ignore error */ },
                receiveValue: { [weak self] spaces in
                    self?.spaces = spaces
                })
    }
}
