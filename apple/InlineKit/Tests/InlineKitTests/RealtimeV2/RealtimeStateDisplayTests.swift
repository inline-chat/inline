import Foundation
import Testing

@testable import RealtimeV2

@Suite("RealtimeV2.RealtimeStateDisplay")
final class RealtimeStateDisplayTests {
  @Test("default display policy uses longer cold start and reconnect delays")
  func testDefaultDisplayPolicy() {
    let policy = RealtimeConnectionDisplayPolicy.default

    #expect(policy.showDelaySeconds(for: .coldStart) == 2)
    #expect(policy.showDelaySeconds(for: .reconnect) == 4)
    #expect(policy.hideDelaySeconds == 1)
  }

  @Test("cold start uses cold display delay")
  @MainActor
  func testColdStartUsesColdDisplayDelay() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.2,
      reconnectDelaySeconds: 0.6,
      hideDelaySeconds: 0.05
    ))

    state.applyConnectionState(.connecting)

    let remainedHiddenEarly = await waitForDisplayedState(
      nil,
      in: state,
      duration: .milliseconds(120)
    )
    #expect(remainedHiddenEarly)

    let didShowConnecting = await waitForDisplayedState(
      .connecting,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didShowConnecting)
  }

  @Test("reconnect uses reconnect display delay after first connection")
  @MainActor
  func testReconnectUsesReconnectDisplayDelayAfterFirstConnection() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.05,
      reconnectDelaySeconds: 0.3,
      hideDelaySeconds: 0.05
    ))

    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)

    let remainedHiddenThroughColdDelay = await waitForDisplayedState(
      nil,
      in: state,
      duration: .milliseconds(180)
    )
    #expect(remainedHiddenThroughColdDelay)

    let didShowConnecting = await waitForDisplayedState(
      .connecting,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didShowConnecting)
  }

  @Test("transient reconnect does not show connecting UI")
  @MainActor
  func testTransientReconnectDoesNotShowConnectingUI() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.05,
      reconnectDelaySeconds: 0.25,
      hideDelaySeconds: 0.05
    ))

    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(100))
    state.applyConnectionState(.connected)

    let remainedHidden = await waitForDisplayedState(
      nil,
      in: state,
      duration: .milliseconds(350)
    )
    #expect(remainedHidden)
  }

  @Test("persistent reconnect shows connecting UI after grace period")
  @MainActor
  func testPersistentReconnectShowsConnectingUIAfterGracePeriod() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.05,
      reconnectDelaySeconds: 0.2,
      hideDelaySeconds: 0.05
    ))

    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)
    let didShowConnecting = await waitForDisplayedState(
      .connecting,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didShowConnecting)
  }

  @Test("pre-visible reconnect transition does not restart grace timer")
  @MainActor
  func testPreVisibleReconnectTransitionDoesNotRestartGraceTimer() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.05,
      reconnectDelaySeconds: 0.2,
      hideDelaySeconds: 0.05
    ))

    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(120))
    state.applyConnectionState(.updating)

    let didShowUpdating = await waitForDisplayedState(
      .updating,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didShowUpdating)
  }

  @Test("displayed reconnect state hides after connected delay")
  @MainActor
  func testDisplayedReconnectStateHidesAfterConnectedDelay() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.05,
      reconnectDelaySeconds: 0.15,
      hideDelaySeconds: 0.08
    ))

    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)
    let didShowConnecting = await waitForDisplayedState(
      .connecting,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didShowConnecting)

    state.applyConnectionState(.connected)
    #expect(state.displayedConnectionState == .connecting)

    let didHide = await waitForDisplayedState(
      nil,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didHide)
  }

  @Test("visible reconnect label updates immediately between non-connected states")
  @MainActor
  func testVisibleReconnectLabelUpdatesImmediatelyBetweenNonConnectedStates() async throws {
    let state = RealtimeState(displayPolicy: .init(
      coldStartDelaySeconds: 0.05,
      reconnectDelaySeconds: 0.1,
      hideDelaySeconds: 0.05
    ))

    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)
    let didShowConnecting = await waitForDisplayedState(
      .connecting,
      in: state,
      timeout: .seconds(1)
    )
    #expect(didShowConnecting)

    state.applyConnectionState(.updating)
    #expect(state.displayedConnectionState == .updating)
  }
}

// MARK: - Test Helpers

@MainActor
private func waitForDisplayedState(
  _ expected: RealtimeConnectionState?,
  in state: RealtimeState,
  timeout: Duration = .seconds(1),
  pollInterval: Duration = .milliseconds(10)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout

  while state.displayedConnectionState != expected {
    if clock.now >= deadline {
      return false
    }
    try? await clock.sleep(for: pollInterval)
  }

  return true
}

@MainActor
private func waitForDisplayedState(
  _ expected: RealtimeConnectionState?,
  in state: RealtimeState,
  duration: Duration,
  pollInterval: Duration = .milliseconds(10)
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + duration

  while clock.now < deadline {
    if state.displayedConnectionState != expected {
      return false
    }
    try? await clock.sleep(for: pollInterval)
  }

  return true
}
