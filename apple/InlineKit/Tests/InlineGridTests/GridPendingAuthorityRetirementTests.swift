import Auth
import Foundation
@testable import InlineGrid
import InlineProtocol
import Testing

@Suite("Grid pending membership auth retirement", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct GridPendingAuthorityRetirementTests {
  enum PendingKind: CaseIterable, Sendable {
    case create, join, move, leave

    var method: InlineProtocol.Method {
      switch self {
        case .create: .createGridRoom
        case .join: .joinGridRoom
        case .move: .moveGridCallHere
        case .leave: .leaveGridRoom
      }
    }

    func submit(to service: GridRoomService) {
      switch self {
        case .create: service.createAndJoin(spaceID: 42)
        case .join: service.join(roomID: 7)
        case .move: service.moveCallHere()
        case .leave: service.leaveCurrentRoom(spaceID: 42)
      }
    }

    var operationKind: GridMembershipOperation.Kind {
      switch self {
        case .create: .create
        case .join: .join(roomID: 7)
        case .move: .move(callID: "call-membership-a", roomID: 7)
        case .leave: .leave(roomID: 7)
      }
    }

    func event(operation: GridMembershipOperation, result: GridRoomMutationResult) -> GridMembershipSyncEvent {
      switch self {
        case .create: .created(operation, result)
        case .join: .joined(operation, result)
        case .move: .moved(operation, result)
        case .leave: .left(operation, result)
      }
    }
  }

  enum Replacement: CaseIterable, Sendable, Equatable {
    case explicit, implicit, denied
  }

  @Test(
    "held public membership work cannot block or clear a successor claim across auth replacement",
    arguments: PendingKind.allCases,
    Replacement.allCases
  )
  func pendingOperationCannotOwnSuccessor(kind: PendingKind, replacement outcome: Replacement) async throws {
    let control = GridAuthorityMembershipControl()
    let fixture = GridAuthorityTestFixture(control: control)
    do {
      try await exercise(kind: kind, replacement: outcome, fixture: fixture, control: control)
    } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  private func exercise(
    kind: PendingKind, replacement outcome: Replacement,
    fixture: GridAuthorityTestFixture, control: GridAuthorityMembershipControl
  ) async throws {
    let oldAccount = try await fixture.seedAccount()
    try await fixture.admit()
    try await fixture.enableTransferForPublicActions()
    let confirmed = try #require(fixture.service.grid(spaceID: 42))
    await fixture.audio.blockShutdown()
    kind.submit(to: fixture.service)
    #expect(fixture.service.membershipMutationInFlight)
    try await eventuallyGridAuthority { control.submissions.count == 1 }
    #expect(control.submissions[0].method == kind.method)
    #expect(control.submissions[0].account == oldAccount)

    let attempt = outcome == .implicit
      ? nil : try await fixture.auth.beginLoginAttempt(allowAuthenticated: true)
    let replacing = Task {
      try await fixture.auth.saveInlineProtocolCredentials(
        fixture.credentials(sessionID: 11), loginAttempt: attempt
      )
      if let attempt {
        return try await fixture.auth.finalizeCredentialsCommittedByLoginAttempt(attempt)
      }
      return try fixture.auth.beginAccountMutation()
    }
    // The old sender is still suspended and deliberately ignores cancellation. Claim bookkeeping
    // must be released by the synchronous auth boundary, before its physical barrier completes.
    try await eventuallyGridAuthority {
      fixture.auth.hasPendingAccountTransition() && !fixture.service.membershipMutationInFlight
    }
    #expect(!control.completed.contains(0))
    #expect(!fixture.service.hasLocalAdmission)
    #expect(fixture.service.currentCall?.membershipID == "membership-a")
    #expect(fixture.service.grid(spaceID: 42)?.currentRoomID == confirmed.currentRoomID)
    #expect(fixture.service.grid(spaceID: 42)?.rooms[0].avatars.contains {
      $0.ownedByCurrentSession && $0.membershipID == "membership-a"
    } == true)

    await fixture.audio.releaseShutdown(succeeded: outcome != .denied)
    if outcome == .denied {
      await #expect(throws: AuthStorageError.loginUnavailable) { try await replacing.value }
      try fixture.auth.validateAccountMutation(oldAccount)
      #expect(fixture.auth.inlineProtocolCredentials()?.accountSessionId == 10)
      // Physical recovery is explicit. The original account may try again once stop is proven.
      await fixture.audio.releaseShutdown(succeeded: true)
      #expect(await fixture.engine.requestShutdownReceipt().value.isLocallyQuiescent)
    } else {
      let newAccount = try await replacing.value
      #expect((newAccount == oldAccount) == (outcome == .implicit))
    }

    fixture.service.createAndJoin(spaceID: 42)
    #expect(fixture.service.membershipMutationInFlight)
    try await eventuallyGridAuthority { control.submissions.count == 2 }
    #expect(control.submissions[1].method == .createGridRoom)
    #expect(!control.completed.contains(0))

    let oldResponse = fixture.claimResult(membershipID: "old-held", revision: 4)
    if kind == .leave {
      control.fail(0)
    } else {
      control.succeed(0, with: oldResponse)
    }
    try await eventuallyGridAuthority { control.completed.contains(0) }
    // A real worker can also have broadcast its event just before reset. Replay that already-
    // buffered result through the production handler while the new public claim remains pending.
    let oldOperation = GridMembershipOperation(
      kind: kind.operationKind, spaceID: 42, expectedMembershipID: "membership-a",
      intentRevision: 1, accountToken: oldAccount, microphoneEnabled: false,
      automaticMicrophoneChange: nil, accessRevision: 0, revision: 1, startedAt: Date()
    )
    let oldEvent = kind.event(operation: oldOperation, result: oldResponse)
    await fixture.service.handle(oldEvent)
    await fixture.service.handle(.failed(oldOperation, message: "old queued failure"))
    #expect(fixture.service.membershipMutationInFlight)
    #expect(fixture.service.grid(spaceID: 42)?.revision == confirmed.revision)
    #expect(fixture.service.currentCall?.membershipID == "membership-a")
    #expect(!fixture.service.hasLocalAdmission)
    #expect(fixture.service.lastError != "old queued failure")

    control.succeed(1, with: fixture.claimResult(membershipID: "successor", revision: 3))
    try await eventuallyGridAuthority {
      fixture.service.hasLocalAdmission && !fixture.service.membershipMutationInFlight
        && fixture.service.media.connectionState == .connected
    }
    #expect(fixture.service.currentCall?.membershipID == "successor")
    let successorIdentity = fixture.service.mediaSessionIdentity
    #expect(successorIdentity != nil)
    // Normal responses above really admitted media. An older success or failure may neither
    // replace its snapshot nor tear it down after the original sender finally returns.
    await fixture.service.handle(oldEvent)
    await fixture.service.handle(.failed(oldOperation, message: "old queued failure"))
    #expect(fixture.service.hasLocalAdmission)
    #expect(fixture.service.mediaSessionIdentity == successorIdentity)
    #expect(fixture.service.currentCall?.membershipID == "successor")
    #expect(fixture.service.grid(spaceID: 42)?.revision == 3)
  }
}
