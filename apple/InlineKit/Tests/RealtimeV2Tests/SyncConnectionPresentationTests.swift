import Foundation
import Testing
@testable import RealtimeV2

@Suite("Sync connection presentation", .serialized)
struct SyncConnectionPresentationTests {
  @Test("platform policies expose sync status promptly and hide immediately")
  func platformPolicies() {
    #expect(RealtimeConnectionDisplayPolicy.iOS.showDelaySeconds(for: .coldStart) == 0)
    #expect(RealtimeConnectionDisplayPolicy.iOS.showDelaySeconds(for: .reconnect) == 0.3)
    #expect(RealtimeConnectionDisplayPolicy.iOS.hideDelaySeconds == 0)
    #expect(RealtimeConnectionDisplayPolicy.macOS.showDelaySeconds(for: .coldStart) == 0)
    #expect(RealtimeConnectionDisplayPolicy.macOS.showDelaySeconds(for: .reconnect) == 1)
    #expect(RealtimeConnectionDisplayPolicy.macOS.hideDelaySeconds == 0)
  }

  @Test("iOS cold connection is visible on the first state projection")
  @MainActor
  func immediateColdStart() {
    let state = RealtimeState(displayPolicy: .iOS)
    state.applyConnectionState(.connecting)
    #expect(state.displayedConnectionState == .connecting)
    state.applyConnectionState(.updating)
    #expect(state.displayedConnectionState == .updating)
    state.applyConnectionState(.connected)
    #expect(state.displayedConnectionState == nil)
  }

  @Test("a transient reconnect and catch-up never flash after recovery")
  @MainActor
  func transientReconnectStaysHidden() async throws {
    let state = RealtimeState(displayPolicy: .iOS)
    state.applyConnectionState(.connected)
    state.applyConnectionState(.connecting)
    try await Task.sleep(for: .milliseconds(50))
    state.applyConnectionState(.updating)
    #expect(state.displayedConnectionState == nil)
    state.applyConnectionState(.connected)
    #expect(state.displayedConnectionState == nil)
    try await Task.sleep(for: .milliseconds(350))
    #expect(state.displayedConnectionState == nil)
  }
}
