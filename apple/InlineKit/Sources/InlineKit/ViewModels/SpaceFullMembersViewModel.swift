import Combine
import GRDB
import Logger

public final class SpaceFullMembersViewModel: ObservableObject {
  /// The space information.
  @Published public private(set) var space: Space?
  /// The full members for this space.
  @Published public private(set) var members: [FullMemberItem] = []
  
  public var filteredMembers: [FullMemberItem] {
    members.filter { member in
      // Filter out users who are pending setup
      member.userInfo.user.pendingSetup != true
    }
  }
  
  private var spaceCancellable: AnyCancellable?
  private var membersCancellable: AnyCancellable?
  private var db: AppDatabase
  private var spaceId: Int64
  
  public init(db: AppDatabase, spaceId: Int64) {
    self.db = db
    self.spaceId = spaceId
    fetchSpace()
    fetchMembers()
  }
  
  private func fetchSpace() {
    let spaceId = spaceId
    spaceCancellable =
    ValueObservation
      .tracking { db in
        try Space.fetchOne(db, id: spaceId)
      }
      .publisher(in: db.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { error in
          Log.shared.error("failed to fetch space in space members view model. error: \(error)")
        },
        receiveValue: { [weak self] space in
          self?.space = space
        }
      )
  }
  
  public func fetchMembers() {
    let spaceId = spaceId
    membersCancellable = ValueObservation
      .tracking { db in
        try Member
          .fullMemberQuery()
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
