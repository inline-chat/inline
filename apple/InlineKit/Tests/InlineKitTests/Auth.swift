import Combine
import Foundation
import Testing

@testable import Auth

@Test func testAuthMock() async throws {
  let auth = Auth.mocked(authenticated: true)
  
  #expect(auth.getToken() != nil)
  #expect(auth.getCurrentUserId() != nil)
  #expect(auth.getIsLoggedIn() == true)
}

@Test("Auth UI replays the initial snapshot once before subsequent authentication", arguments: [false, true])
@MainActor func testAuthUIUsesOneOrderedSnapshotSource(initiallyAuthenticated: Bool) async throws {
  let auth = Auth.mocked(authenticated: initiallyAuthenticated)
  var updates: [AuthStatus] = []
  let observation = auth.$status.dropFirst().sink { updates.append($0) }
  defer { observation.cancel() }

  // The synchronous cache is ready before any UI observer task runs.
  let initial = auth.getStatus()
  try await auth.saveCredentials(token: "2:nextMockToken", userId: 2)
  let authenticated = auth.getStatus()
  let deadline = ContinuousClock.now.advanced(by: .seconds(2))
  while auth.currentUserId != 2, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
  }

  #expect(auth.currentUserId == 2)
  #expect(updates == [initial, authenticated])
  #expect(auth.status == auth.getStatus())
}
