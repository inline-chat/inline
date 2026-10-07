import Auth
import Foundation
import InlineProtocol
import Testing

@testable import InlineGrid

@Suite("Grid revoked membership responses", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GridMembershipRevocationTests {
  enum ResponseKind: CaseIterable, Sendable {
    case create, join, move, leave
  }

  @Test(
    "a held membership result cannot restore a space after its access is revoked",
    arguments: ResponseKind.allCases)
  func revokedSpaceCannotReturn(kind: ResponseKind) async throws {
    let fixture = GridAuthorityTestFixture()
    do {
      try await exerciseRevokedResponse(kind: kind, fixture: fixture)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  private func exerciseRevokedResponse(kind: ResponseKind, fixture: GridAuthorityTestFixture)
    async throws
  {
    let token = try await fixture.seedAccount()
    try await fixture.admit()
    let call = try #require(fixture.service.currentCall)
    var heldGrid = try #require(fixture.service.grid(spaceID: call.spaceID))
    heldGrid.revision += 1
    #expect(fixture.service.isEnabled(spaceID: call.spaceID))
    #expect(fixture.service.hasLocalAdmission)

    await fixture.service.handle(
      GridEvent.with {
        $0.accessRevoked = .with { $0.spaceID = call.spaceID }
      })
    #expect(fixture.service.grid(spaceID: call.spaceID) == nil)
    #expect(!fixture.service.isEnabled(spaceID: call.spaceID))
    #expect(!fixture.service.hasLocalAdmission)

    let operationKind: GridMembershipOperation.Kind =
      switch kind {
      case .create: .create
      case .join: .join(roomID: call.roomID)
      case .move: .move(callID: call.callID, roomID: call.roomID)
      case .leave: .leave(roomID: call.roomID)
      }
    let operation = GridMembershipOperation(
      kind: operationKind,
      spaceID: call.spaceID,
      expectedMembershipID: call.membershipID,
      intentRevision: 0,
      accountToken: token,
      microphoneEnabled: false,
      automaticMicrophoneChange: nil,
      accessRevision: 0,
      revision: 2,
      startedAt: Date()
    )
    let response = GridRoomMutationResult(
      grids: [heldGrid], credentials: nil, currentCall: call
    )
    let event: GridMembershipSyncEvent =
      switch kind {
      case .create: .created(operation, response)
      case .join: .joined(operation, response)
      case .move: .moved(operation, response)
      case .leave: .left(operation, response)
      }
    // The real event handler attempts Home repair through the unavailable
    // control connection. Rejection must hold without a successful refetch.
    await fixture.service.handle(event)
    #expect(fixture.service.grid(spaceID: call.spaceID) == nil)
    #expect(!fixture.service.isEnabled(spaceID: call.spaceID))
    #expect(fixture.service.recentAvatars(spaceID: call.spaceID).isEmpty)
    #expect(!fixture.service.homeSpaces.contains { $0.spaceID == call.spaceID })
    #expect(fixture.service.currentCall == nil)
    #expect(!fixture.service.hasLocalAdmission)
    #expect(fixture.service.mediaSessionIdentity == nil)
    #expect(!fixture.service.membershipMutationInFlight)
  }
}
