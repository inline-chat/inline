import Foundation
import InlineConfig
import Testing
@testable import Auth

@Suite("Headless credential isolation")
struct AuthTestIsolationTests {
  @Test func runnerIsRecognizedBeforeSingletonInitialization() {
    #expect(TestProcess.isRunning)
  }

  @Test func credentialNamespacesDoNotShareOrPersistBytes() {
    let first = UUID().uuidString
    let second = UUID().uuidString
    defer {
      AuthKeychainConfig.mockDelete("token", namespace: first)
      AuthKeychainConfig.mockDelete("token", namespace: second)
    }
    AuthKeychainConfig.mockSet("first", forKey: "token", namespace: first)
    AuthKeychainConfig.mockSet("second", forKey: "token", namespace: second)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: first) == "first")
    #expect(AuthKeychainConfig.mockGetString("token", namespace: second) == "second")
    #expect(UserDefaults.standard.data(forKey: "mock_secure_\(first)_token") == nil)
    AuthKeychainConfig.mockDelete("token", namespace: first)
    #expect(AuthKeychainConfig.mockGetData("token", namespace: first) == nil)
    #expect(AuthKeychainConfig.mockGetString("token", namespace: second) == "second")
  }

  @Test func independentAuthFixturesDoNotShareAuthority() async throws {
    let first = Auth.mocked(authenticated: false)
    let second = Auth.mocked(authenticated: false)
    try await first.saveCredentials(token: "101:test-only", userId: 101)
    await first.refreshFromStorage()
    await second.refreshFromStorage()
    #expect(first.getCurrentUserId() == 101)
    #expect(second.getCurrentUserId() == nil)
    #expect(second.getToken() == nil)
  }
}
