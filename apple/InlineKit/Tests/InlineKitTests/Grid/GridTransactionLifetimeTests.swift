@testable import InlineKit
import RealtimeV2
import Testing

@Suite("Grid transaction lifetime")
struct GridTransactionLifetimeTests {
  @Test("snapshot requests are ephemeral and preserve read and ownership fences")
  func snapshotRequestsAreEphemeral() {
    let grid = GetGridTransaction(spaceID: 42)
    let home = GetGridHomeTransaction()
    let connection = PrepareGridConnectionTransaction(roomID: 7, generation: 3)

    guard case let .ephemeral(gridConfig) = grid.type,
          case let .ephemeral(homeConfig) = home.type,
          case let .ephemeral(connectionConfig) = connection.type
    else {
      Issue.record("Grid snapshot requests must not persist or replay across reconnect")
      return
    }

    #expect(gridConfig.maxQueueAge == 5)
    #expect(homeConfig.maxQueueAge == 5)
    #expect(connectionConfig.maxQueueAge == 5)
    #expect(grid.ephemeralCoalescingKey != GetGridTransaction(spaceID: 42).ephemeralCoalescingKey)
    #expect(home.ephemeralCoalescingKey != GetGridHomeTransaction().ephemeralCoalescingKey)
    #expect(connection.ephemeralCoalescingKey == "room:7:generation:3:membership:legacy")
    #expect(connection.ephemeralCoalescingKey != PrepareGridConnectionTransaction(
      roomID: 7, generation: 4, expectedMembershipID: "new-owner"
    ).ephemeralCoalescingKey)
    #expect(grid.effectiveReconnectReplayPolicy == .neverReplay)
    #expect(home.effectiveReconnectReplayPolicy == .neverReplay)
    #expect(connection.effectiveReconnectReplayPolicy == .neverReplay)
  }

  @Test("membership mutations carry microphone intent atomically")
  func membershipMutationsCarryMicrophoneIntent() {
    let create = CreateGridRoomTransaction(spaceID: 42, microphoneEnabled: true)
    guard case let .createGridRoom(createInput)? = create.input(from: create.context) else {
      Issue.record("Expected createGridRoom input")
      return
    }
    #expect(createInput.hasMicrophoneEnabled)
    #expect(createInput.microphoneEnabled)

    let join = JoinGridRoomTransaction(roomID: 7, microphoneEnabled: false)
    guard case let .joinGridRoom(joinInput)? = join.input(from: join.context) else {
      Issue.record("Expected joinGridRoom input")
      return
    }
    #expect(joinInput.hasMicrophoneEnabled)
    #expect(joinInput.microphoneEnabled == false)
  }
}

@Suite("Grid ownership request fences")
struct GridOwnershipRequestFenceTests {
  @Test("empty create fence means no presence, while omitted fence stays distinguishable")
  func explicitEmptyFenceIsPresent() {
    let fenced = CreateGridRoomTransaction(spaceID: 42, microphoneEnabled: false, expectedMembershipID: "")
    let legacy = CreateGridRoomTransaction(spaceID: 42, microphoneEnabled: false)
    guard case let .createGridRoom(fencedInput)? = fenced.input(from: fenced.context),
          case let .createGridRoom(legacyInput)? = legacy.input(from: legacy.context)
    else { Issue.record("Expected create input")
      return
    }
    #expect(fencedInput.hasExpectedMembershipID)
    #expect(fencedInput.expectedMembershipID.isEmpty)
    #expect(!legacyInput.hasExpectedMembershipID)
  }

  @Test("browsing never renews, while admitted heartbeat carries exact ownership")
  func snapshotAndRenewalStayDistinct() {
    let read = GetGridTransaction(spaceID: 42)
    let renewal = GetGridTransaction(spaceID: 42, expectedMembershipID: "admitted-owner")
    guard case let .getGrid(readInput)? = read.input(from: read.context),
          case let .getGrid(renewInput)? = renewal.input(from: renewal.context)
    else { Issue.record("Expected GetGrid input")
      return
    }
    #expect(!readInput.hasExpectedMembershipID)
    #expect(renewInput.hasExpectedMembershipID)
    #expect(renewInput.expectedMembershipID == "admitted-owner")
  }

  @Test("move here preserves stable call and caller-observed ownership fence")
  func moveCarriesExactClaim() {
    let move = MoveGridCallHereTransaction(callID: "stable-call", expectedMembershipID: "observed-owner")
    guard case let .moveGridCallHere(input)? = move.input(from: move.context) else {
      Issue.record("Expected MoveGridCallHere input")
      return
    }
    #expect(input.callID == "stable-call")
    #expect(input.expectedMembershipID == "observed-owner")
  }
}
