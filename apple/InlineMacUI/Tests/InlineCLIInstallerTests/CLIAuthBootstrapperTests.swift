@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("Inline CLI authentication bootstrap")
struct CLIAuthBootstrapperTests {
  @Test("accepts a bounded callback handshake")
  func acceptsReadyHandshake() throws {
    let data = Data(
      #"{"version":1,"status":"ready","callbackUrl":"inline://cli-auth?version=1&port=54321&capability=abcdefghijklmnopqrstuvwxyz012345"}"#.utf8
    )
    let request = try CLIAuthBootstrapper.parseReady(data)
    #expect(request.callbackURL.host == "cli-auth")
  }

  @Test("rejects an external callback handshake")
  func rejectsExternalHandshake() {
    let data = Data(
      #"{"version":1,"status":"ready","callbackUrl":"https://example.com/cli-auth"}"#.utf8
    )
    #expect(throws: CLIAuthBootstrapError.self) {
      try CLIAuthBootstrapper.parseReady(data)
    }
  }

  @Test("accepts only token-free authenticated results")
  func acceptsAuthenticatedResult() throws {
    let data = Data(
      #"{"status":"authenticated","userId":42,"tokenSaved":true,"profileLoaded":false,"warning":null}"#.utf8
    )
    let result = try CLIAuthBootstrapper.parseResult(data)
    #expect(result.userID == 42)
    #expect(!result.profileLoaded)
  }

  @Test("removes Inline overrides from the child environment")
  func sanitizesEnvironment() {
    let environment = CLIAuthBootstrapper.sanitizedEnvironment([
      "HOME": "/Users/test",
      "PATH": "/custom/bin",
      "INLINE_TOKEN": "secret",
      "INLINE_API_BASE_URL": "https://example.com",
    ])
    #expect(environment["HOME"] == "/Users/test")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["INLINE_TOKEN"] == nil)
    #expect(environment["INLINE_API_BASE_URL"] == nil)
  }

  @Test("describes bootstrap timeouts as a recoverable sign-in failure")
  func describesTimeout() {
    #expect(
      CLIAuthBootstrapError.timedOut.errorDescription ==
        "The installed CLI did not finish signing in within two minutes."
    )
  }
}
