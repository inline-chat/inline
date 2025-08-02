import Testing

@testable import Auth

@Test func testAuthMock() async throws {
  let auth = Auth.mocked(authenticated: true)
  
  #expect(auth.getToken() != nil)
  #expect(auth.getCurrentUserId() != nil)
  #expect(auth.isLoggedIn == true)
}


@Test func testAuthMock() async throws {
  let auth = Auth.mocked(authenticated: true)
  
  #expect(auth.getToken() != nil)
  #expect(auth.getCurrentUserId() != nil)
  #expect(auth.isLoggedIn == true)
}
