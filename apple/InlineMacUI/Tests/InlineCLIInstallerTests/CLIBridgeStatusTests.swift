@testable import InlineCLIInstaller
import Foundation
import Testing

@Suite("CLI bridge status parsing")
struct CLIBridgeStatusTests {
  @Test("Reads every configured agent from the CLI's status list")
  func parsesList() throws {
    let json = """
    [{"status":"running","installed":true,"serviceLoaded":true,"healthy":true,"provider":"codex",
      "displayName":"Codex","botUsername":"codex_bot","workspace":"/tmp","processId":42,
      "inlineConnected":true,"providerReady":true,"detail":null},
     {"status":"stopped","installed":true,"serviceLoaded":false,"healthy":false,"provider":"claude",
      "displayName":null,"botUsername":null,"workspace":null,"processId":null,
      "inlineConnected":false,"providerReady":false,"detail":"stopped by user"}]
    """
    let statuses = try #require(CLIBridgeStatus.parseList(Data(json.utf8)))
    #expect(statuses.map(\.provider) == ["codex", "claude"])
    #expect(statuses[0].healthy && statuses[0].processId == 42)
    #expect(statuses[1].status == "stopped" && statuses[1].detail == "stopped by user")
  }

  @Test("Reads the single not-installed object")
  func parsesNotInstalled() throws {
    let json = """
    {"status":"not_installed","installed":false,"serviceLoaded":false,"healthy":false,"provider":"agent",
     "displayName":null,"botUsername":null,"workspace":null,"processId":null,
     "inlineConnected":false,"providerReady":false,"detail":"run `inline agents setup` first"}
    """
    let statuses = try #require(CLIBridgeStatus.parseList(Data(json.utf8)))
    #expect(statuses.count == 1 && !statuses[0].installed)
  }

  @Test("Rejects non-status output")
  func rejectsGarbage() {
    #expect(CLIBridgeStatus.parseList(Data("Bridge: running".utf8)) == nil)
  }

  @Test("Bridge commands use JSON arguments")
  func arguments() {
    #expect(CLIBridgeCommand.restart.arguments == ["bridge", "restart", "--json"])
    #expect(CLIBridgeCommand.status.arguments == ["bridge", "status", "--json"])
  }
}
