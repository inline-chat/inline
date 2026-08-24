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
}
