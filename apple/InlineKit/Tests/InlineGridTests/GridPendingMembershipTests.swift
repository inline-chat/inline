import Foundation
@testable import InlineGrid
import InlineProtocol
import Testing

/// Interfaces render the in-flight change, so leaving never reads as a paused
/// call and switching rooms never reads as moving one.
@Suite("Grid pending membership", .serialized)
@MainActor
struct GridPendingMembershipTests {
  @Test("leaving shows as leaving and its result clears the call without waiting for Home")
  func leaveClearsCallFromItsResult() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await fixture.seedAccount()
      try await fixture.admit()
      try await fixture.enableTransferForPublicActions()
      let joined = try #require(fixture.service.grid(spaceID: 42))

      fixture.service.leaveCurrentRoom(spaceID: 42)
      #expect(fixture.service.pendingMembership == .leave(spaceID: 42))
      #expect(!fixture.service.hasLocalAdmission)

      var left = joined
      left.clearCurrentRoomID()
      left.revision += 1
      left.rooms[0].avatars.removeAll(where: \.ownedByCurrentSession)
      // Home stays unavailable, so only the leave result can clear the call.
      try await eventuallyGridAuthority { control.submissions.count == 1 }
      control.succeed(0, with: GridRoomMutationResult(grids: [left], credentials: nil, currentCall: nil))
      try await eventuallyGridAuthority { !fixture.service.membershipMutationInFlight }
      #expect(fixture.service.pendingMembership == nil)
      #expect(fixture.service.currentCall == nil)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("a new claim while in a call shows as joining and clears when it settles")
  func claimWhileInCallShowsJoining() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await fixture.seedAccount()
      try await fixture.admit()
      try await fixture.enableTransferForPublicActions()

      fixture.service.createAndJoin(spaceID: 42)
      #expect(fixture.service.pendingMembership == .create(spaceID: 42))
      #expect(fixture.service.currentCall?.ownedByCurrentSession == true)

      try await eventuallyGridAuthority { control.submissions.count == 1 }
      control.fail(0)
      try await eventuallyGridAuthority { !fixture.service.membershipMutationInFlight }
      #expect(fixture.service.pendingMembership == nil)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }
}
