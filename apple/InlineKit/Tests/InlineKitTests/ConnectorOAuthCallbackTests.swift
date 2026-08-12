import Foundation
import InlineKit
import Testing

@Suite("Connector OAuth callbacks")
struct ConnectorOAuthCallbackTests {
  @Test("parses provider success callbacks")
  func parsesSuccess() throws {
    let url = try #require(URL(string: "inline-debug://integrations/notion?success=true"))
    let callback = try #require(ConnectorOAuthCallback(url: url))

    #expect(callback.provider == .notion)
    #expect(callback.succeeded)
    #expect(callback.error == nil)
  }

  @Test("accepts the isolated second Debug app callback")
  func parsesSecondDebugApp() throws {
    let url = try #require(URL(string: "inline-debug-2://integrations/notion?success=true"))
    let callback = try #require(ConnectorOAuthCallback(url: url))

    #expect(callback.provider == .notion)
    #expect(callback.succeeded)
  }

  @Test("parses failure details without accepting unrelated links")
  func parsesFailure() throws {
    let url = try #require(URL(
      string: "in://integrations/linear?success=false&error=state_mismatch"
    ))
    let callback = try #require(ConnectorOAuthCallback(url: url))
    let unrelatedURL = try #require(URL(string: "in://chat/42"))
    let wrongScheme = try #require(URL(string: "https://integrations/linear?success=true"))
    let duplicateQuery = try #require(URL(
      string: "in://integrations/linear?success=false&success=true"
    ))

    #expect(callback.provider == .linear)
    #expect(!callback.succeeded)
    #expect(callback.error == "state_mismatch")
    #expect(ConnectorOAuthCallback(url: unrelatedURL) == nil)
    #expect(ConnectorOAuthCallback(url: wrongScheme) == nil)
    #expect(ConnectorOAuthCallback(url: duplicateQuery)?.succeeded == false)
  }
}
