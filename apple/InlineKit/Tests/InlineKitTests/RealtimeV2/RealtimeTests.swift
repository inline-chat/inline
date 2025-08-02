import Testing

@testable import Auth
@testable import RealtimeV2

@Test func testAuth() async throws {
  let auth = Auth.mocked(authenticated: true)
  
  #expect(auth.getToken() != nil)
  #expect(auth.getCurrentUserId() != nil)
  #expect(auth.isLoggedIn == true)
}
