import Combine
import GRDB
import Logger

public final class SpaceMembersViewModel: ObservableObject {
  /// The members of the space
  @Published public private(set) var members: [Member] = []

  private var membersCancellable: AnyCancellable?
  private var db: AppDatabase
  private var spaceId: Int64

  public init(db: AppDatabase, spaceId: Int64) {
    self.db = db
    self.spaceId = spaceId
    fetchMembers()
  }

  public func fetchMembers() {
    let spaceId = spaceId
    membersCancellable = ValueObservation
      .tracking { db in
        try Member
          .filter(Column("spaceId") == spaceId)
          .fetchAll(db)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("Failed to fetch members in space members view model. error: \(error)")
        },
        receiveValue: { [weak self] members in
          self?.members = members
        }
      )
  }

  /// Refetch members from the server
  public func refetchMembers() async {
    do {
      try await Realtime.shared.invokeWithHandler(
        .getSpaceMembers,
        input: .getSpaceMembers(.with { input in
          input.spaceID = spaceId
        })
      )
    } catch {
      Log.shared.error("Failed to refetch space members: \(error)")
    }
  }
}
