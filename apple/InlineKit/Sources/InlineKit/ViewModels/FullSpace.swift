import Combine
import GRDB

public final class FullSpaceViewModel: ObservableObject {
    /// The spaces to display.
    @Published public private(set) var space: Space?
    @Published public private(set) var members: [Member]?

    private var spaceSancellable: AnyCancellable?
    private var membersSancellable: AnyCancellable?

    private var db: AppDatabase
    private var spaceId: Int64
    public init(db: AppDatabase, spaceId: Int64) {
        self.db = db
        self.spaceId = spaceId
        fetchSpace()
        fetchMembers()
    }

    func fetchSpace() {
        spaceSancellable = ValueObservation
            .tracking { db in
                try Space.fetchOne(db, id: self.spaceId)
            }
            .publisher(in: db.dbWriter, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in /* ignore error */ },
                receiveValue: { [weak self] space in
                    self?.space = space
                })
    }

    func fetchMembers() {
        membersSancellable = ValueObservation
            .tracking { db in
                try Member.filter(Column("spaceId") == self.spaceId)
                    .fetchAll(db)
            }
            .publisher(in: db.dbWriter, scheduling: .immediate)
            .sink(
                receiveCompletion: { _ in /* ignore error */ },
                receiveValue: { [weak self] members in
                    self?.members = members
                })
    }
}
