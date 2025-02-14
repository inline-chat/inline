import Combine
import GRDB
import Logger
public struct SpaceItem: FetchableRecord, Identifiable, Codable, Hashable, PersistableRecord,
  TableRecord,
  Sendable, Equatable
{
  public var space: Space
  public var members: [Member]
  public var chats: [SpaceChatItem]

  public var id: Int64 {
    space.id
  }

  public init(space: Space, members: [Member], chats: [SpaceChatItem] = []) {
    self.space = space
    self.members = members
    self.chats = chats
  }
}

public final class SpaceListViewModel: ObservableObject {
  /// The spaces to display.
  @Published public private(set) var spaceItems: [SpaceItem] = []
  @Published public private(set) var fullSpaces: [Space] = []
  @Published public private(set) var spaceChats: [Int64: [SpaceChatItem]] = [:]

  private var cancellables = Set<AnyCancellable>()
  private var db: AppDatabase
  public init(db: AppDatabase) {
    self.db = db
    start()
  }

  public func start() {
    ValueObservation
      .tracking { db in
        try Space.fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in Log.shared.error("Failed to get spaces \(error)") },
        receiveValue: { [weak self] spaces in
          self?.fullSpaces = spaces
          self?.observeSpaces(spaces)
        }
      )
      .store(in: &cancellables)
  }

  private func observeSpaces(_ spaces: [Space]) {
    // Clear existing observations
    cancellables.removeAll()

    // Observe each space
    for space in spaces {
      let viewModel = FullSpaceViewModel(db: db, spaceId: space.id)

      viewModel.$chats
        .sink { [weak self] chats in
          self?.spaceChats[space.id] = chats
        }
        .store(in: &cancellables)
    }
  }
}
