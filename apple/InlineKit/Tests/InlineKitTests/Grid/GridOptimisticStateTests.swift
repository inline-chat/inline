import InlineProtocol
import Testing

@testable import InlineKit

@Suite("Grid optimistic membership")
struct GridOptimisticStateTests {
  @Test("two failed rapid joins restore the server-confirmed room")
  func twoFailedRapidJoinsRestoreConfirmedRoom() throws {
    let confirmed = grid(currentRoomID: 30, revision: 10)
    let optimisticFirst = grid(currentRoomID: 10, revision: 10)
    let optimisticLatest = grid(currentRoomID: 20, revision: 10)
    var baseline = GridOptimisticState.MembershipRollbackBaseline()

    baseline.beginIfNeeded(with: [1: confirmed])
    // The next request starts while the first optimistic projection is on
    // screen. It must not turn that projection into the rollback baseline.
    baseline.beginIfNeeded(with: [1: optimisticFirst])
    let rollbackGrids = try #require(baseline.grids)

    let rolledBack = GridOptimisticState.rollingBackMembershipIntent(
      .init(
        roomID: 20,
        spaceID: 1,
        previousGrids: rollbackGrids,
        nextGrids: [:]
      ),
      in: [1: optimisticLatest]
    )

    #expect(rolledBack[1]?.currentRoomID == 30)
    #expect(ownedRoomID(in: rolledBack[1]) == 30)
  }

  @Test("a confirmed older join advances the rollback baseline")
  func confirmedOlderJoinAdvancesBaseline() throws {
    let confirmedInitial = grid(currentRoomID: 30, revision: 10)
    let confirmedFirstJoin = grid(currentRoomID: 10, revision: 11)
    let optimisticLatest = grid(currentRoomID: 20, revision: 11)
    var baseline = GridOptimisticState.MembershipRollbackBaseline()

    baseline.beginIfNeeded(with: [1: confirmedInitial])
    baseline.mergeConfirmed([confirmedFirstJoin])
    let rollbackGrids = try #require(baseline.grids)

    let rolledBack = GridOptimisticState.rollingBackMembershipIntent(
      .init(
        roomID: 20,
        spaceID: 1,
        previousGrids: rollbackGrids,
        nextGrids: [:]
      ),
      in: [1: optimisticLatest]
    )

    #expect(rolledBack[1]?.currentRoomID == 10)
    #expect(ownedRoomID(in: rolledBack[1]) == 10)
  }

  private func grid(currentRoomID: Int64, revision: Int64) -> InlineProtocol.Grid {
    let avatar = GridAvatar.with {
      $0.user = .with { $0.id = 7 }
      $0.ownedByCurrentSession = true
    }
    let room = GridRoom.with {
      $0.id = currentRoomID
      $0.spaceID = 1
      $0.createdByUserID = 7
      $0.avatars = [avatar]
    }
    return .with {
      $0.spaceID = 1
      $0.enabled = true
      $0.rooms = [room]
      $0.currentRoomID = currentRoomID
      $0.revision = revision
    }
  }

  private func ownedRoomID(in grid: InlineProtocol.Grid?) -> Int64? {
    grid?.rooms.first { room in
      room.avatars.contains(where: \.ownedByCurrentSession)
    }?.id
  }
}
