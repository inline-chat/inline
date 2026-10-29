import Foundation
@testable import InlineGrid
import InlineKit
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

  @Test("a room picked while a join is at the server shows at once and is sent once it settles")
  func pickDuringJoinIsHeldThenSent() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await fixture.seedAccount()
      try await fixture.admit(extraRoomIDs: [8, 9])
      try await fixture.enableTransferForPublicActions()

      fixture.service.join(roomID: 8)
      try await eventuallyGridAuthority { control.submissions.count == 1 }
      fixture.service.join(roomID: 9)
      // Never dropped, never disabled: the newest pick is yours right away.
      #expect(fixture.service.pendingMembership == .join(spaceID: 42, roomID: 9))
      #expect(ownedRoomID(fixture.service) == 9)
      #expect(control.submissions.count == 1)

      control.succeed(0, with: joined(fixture, roomID: 8, membershipID: "membership-b", revision: 2))
      try await eventuallyGridAuthority { control.submissions.count == 2 }
      #expect(control.submissions[1].method == .joinGridRoom)
      #expect(fixture.service.pendingMembership == .join(spaceID: 42, roomID: 9))
      #expect(ownedRoomID(fixture.service) == 9)
      #expect(!fixture.service.hasLocalAdmission)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("picking the room already being joined again sends nothing more")
  func pickingBackTheJoiningRoomSendsNothingMore() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await fixture.seedAccount()
      try await fixture.admit(extraRoomIDs: [8, 9])
      try await fixture.enableTransferForPublicActions()

      fixture.service.join(roomID: 8)
      try await eventuallyGridAuthority { control.submissions.count == 1 }
      fixture.service.join(roomID: 9)
      fixture.service.join(roomID: 8)
      #expect(ownedRoomID(fixture.service) == 8)

      control.succeed(0, with: joined(fixture, roomID: 8, membershipID: "membership-b", revision: 2))
      try await eventuallyGridAuthority { !fixture.service.membershipMutationInFlight }
      #expect(control.submissions.count == 1)
      #expect(ownedRoomID(fixture.service) == 8)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  @Test("a new room shows as a stand-in with you in it, and a failure puts you back")
  func newRoomShowsAsStandIn() async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await fixture.seedAccount()
      try await fixture.admit()
      try await fixture.enableTransferForPublicActions()

      fixture.service.createAndJoin(spaceID: 42)
      // Plain values: `#expect` can't decompose calls that take a key path.
      let placeholder = fixture.service.grid(spaceID: 42)?.rooms.first(where: \.isLocalPlaceholder)
      let standIn = try #require(placeholder)
      let ownsStandIn = standIn.avatars.contains(where: \.ownedByCurrentSession)
      #expect(ownsStandIn)
      #expect(ownedRoomID(fixture.service) == standIn.id)

      try await eventuallyGridAuthority { control.submissions.count == 1 }
      control.fail(0)
      try await eventuallyGridAuthority { !fixture.service.membershipMutationInFlight }
      #expect(fixture.service.grid(spaceID: 42)?.rooms.contains(where: \.isLocalPlaceholder) == false)
      #expect(ownedRoomID(fixture.service) == 7)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }
}

@MainActor
private func ownedRoomID(_ service: GridRoomService) -> Int64? {
  service.grid(spaceID: 42)?.rooms.first(where: { $0.avatars.contains(where: \.ownedByCurrentSession) })?.id
}

/// The server's answer to a join: you in `roomID`, rooms 7–9 still listed.
@MainActor
private func joined(
  _ fixture: GridAuthorityTestFixture,
  roomID: Int64,
  membershipID: String,
  revision: Int64
) -> GridRoomMutationResult {
  let base = fixture.claimResult(membershipID: membershipID, revision: revision, extraRoomIDs: [8, 9])
  var grid = base.grids[0]
  let you = grid.rooms[0].avatars.first(where: \.ownedByCurrentSession)!
  grid.rooms[0].avatars.removeAll(where: \.ownedByCurrentSession)
  if let index = grid.rooms.firstIndex(where: { $0.id == roomID }) {
    grid.rooms[index].avatars.append(you)
  }
  grid.currentRoomID = roomID
  var call = base.currentCall!
  call.roomID = roomID
  return GridRoomMutationResult(grids: [grid], credentials: nil, currentCall: call)
}
