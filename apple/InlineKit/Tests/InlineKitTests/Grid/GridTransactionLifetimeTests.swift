import Testing
import RealtimeV2

@testable import InlineKit

@Suite("Grid transaction lifetime")
struct GridTransactionLifetimeTests {
  @Test("snapshot requests are ephemeral and coalesce by resource")
  func snapshotRequestsAreEphemeral() throws {
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
    #expect(grid.ephemeralCoalescingKey == "space:42")
    #expect(home.ephemeralCoalescingKey == "home")
    #expect(connection.ephemeralCoalescingKey == "room:7")
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
