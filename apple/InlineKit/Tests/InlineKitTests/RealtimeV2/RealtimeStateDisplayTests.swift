import Foundation
import Testing

@testable import RealtimeV2

@Suite("RealtimeV2.RealtimeStateDisplay")
final class RealtimeStateDisplayTests {
  @Test("transient reconnect does not show connecting UI")
  @MainActor
  func testTransientReconnectDoesNotShowConnectingUI() async throws {
    let state = RealtimeState(displayDelaySeconds: 0.25, hideDelaySeconds: 0.05)

    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(100))
    state.applyConnectionState(.connected)

    try await Task.sleep(for: .milliseconds(250))
    #expect(state.displayedConnectionState == nil)
  }

  @Test("persistent reconnect shows connecting UI after grace period")
  @MainActor
  func testPersistentReconnectShowsConnectingUIAfterGracePeriod() async throws {
    let state = RealtimeState(displayDelaySeconds: 0.2, hideDelaySeconds: 0.05)

    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(260))

    #expect(state.displayedConnectionState == .connecting)
  }

  @Test("pre-visible reconnect transition does not restart grace timer")
  @MainActor
  func testPreVisibleReconnectTransitionDoesNotRestartGraceTimer() async throws {
    let state = RealtimeState(displayDelaySeconds: 0.2, hideDelaySeconds: 0.05)

    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(120))
    state.applyConnectionState(.updating)

    try await Task.sleep(for: .milliseconds(110))
    #expect(state.displayedConnectionState == .updating)
  }

  @Test("displayed reconnect state hides after connected delay")
  @MainActor
  func testDisplayedReconnectStateHidesAfterConnectedDelay() async throws {
    let state = RealtimeState(displayDelaySeconds: 0.15, hideDelaySeconds: 0.08)

    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(220))
    #expect(state.displayedConnectionState == .connecting)

    state.applyConnectionState(.connected)
    #expect(state.displayedConnectionState == .connecting)

    try await Task.sleep(for: .milliseconds(120))
    #expect(state.displayedConnectionState == nil)
  }

  @Test("visible reconnect label updates immediately between non-connected states")
  @MainActor
  func testVisibleReconnectLabelUpdatesImmediatelyBetweenNonConnectedStates() async throws {
    let state = RealtimeState(displayDelaySeconds: 0.1, hideDelaySeconds: 0.05)

    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(180))
    #expect(state.displayedConnectionState == .connecting)

    state.applyConnectionState(.updating)
    #expect(state.displayedConnectionState == .updating)
  }
}
