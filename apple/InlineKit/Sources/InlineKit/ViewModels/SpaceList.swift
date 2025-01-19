import Combine
import GRDB

public struct SpaceItem: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
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

public final class SpaceListViewModel: ObservableObject {
  /// The spaces to display.
  @Published public private(set) var spaceItems: [SpaceItem] = []

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
          try Space
            .including(all: Space.members)
            .asRequest(of: SpaceItem.self)
            .fetchAll(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { error in Log.shared.error("Failed to get spaces \(error)") },
          receiveValue: { [weak self] spaceItems in
            self?.spaceItems = spaceItems
          }
        )
  }
}
