import Auth
import Combine
import GRDB
import Logger

/// Tracks the current user's membership within a specific space.
@MainActor
public final class SpaceMembershipStatusViewModel: ObservableObject {
  @Published public private(set) var membership: Member?
  @Published public private(set) var isRefreshing = false

  public var role: MemberRole? {
    membership?.role
  }

  public var canManageMembers: Bool {
    switch membership?.role {
      case .owner, .admin:
        true
      default:
        false
    }
  }

  private let db: AppDatabase
  private let spaceId: Int64
  private var cancellable: AnyCancellable?
  private var didRefresh = false
  private var didRefetchOnNil = false

  public init(db: AppDatabase, spaceId: Int64) {
    self.db = db
    self.spaceId = spaceId
    observeMembership()
  }

  private func observeMembership() {
    guard let currentUserId = Auth.getCurrentUserId() else { return }

    let spaceId_ = spaceId

    cancellable =
      ValueObservation
        .tracking { db in
          try Member
            .filter(Column("spaceId") == spaceId_)
            .filter(Column("userId") == currentUserId)
            .fetchOne(db)
        }
        .publisher(in: db.dbWriter, scheduling: .immediate)
        .sink(
          receiveCompletion: { completion in
            if case let .failure(error) = completion {
              Log.shared.error("Failed to observe membership for space \(self.spaceId)", error: error)
            }
          },
          receiveValue: { [weak self] member in
            guard let self else { return }
            self.membership = member

            if member == nil && self.didRefetchOnNil == false {
              self.didRefetchOnNil = true
              Task { await self.refreshIfNeeded(force: true) }
            }
          }
        )
  }

  /// Ensures membership is refreshed at least once from the server after loading cached data.
  public func refreshIfNeeded(force: Bool = false) async {
    guard force || didRefresh == false else { return }
    guard isRefreshing == false else { return }
    didRefresh = true
    isRefreshing = true

    do {
      // TODO: Create a new RPC call to fetch just our membership or something like getSpace etc.
      try await Api.realtime.send(.getSpaceMembers(spaceId: spaceId))
    } catch {
      Log.shared.error("Failed to refresh membership for space \(spaceId)", error: error)
    }

    isRefreshing = false
  }
}
