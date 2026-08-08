import Foundation
import Testing
@testable import InlineCLIInstaller

@Suite("CLI agent setup app protocol")
struct CLIAgentSetupRunnerTests {
  @Test("decodes installed harness discovery")
  func decodesDiscovery() throws {
    let data = Data(
      #"{"protocolVersion":1,"action":"agents.discover","documentationUrl":"https://inline.chat/docs/agents","targets":[{"id":"codex","displayName":"Codex","family":"bridge","installed":true},{"id":"hermes","displayName":"Hermes","family":"gateway","installed":false}]}"#.utf8
    )

    let discovery = try CLIAgentSetupRunner.parseDiscovery(data)

    #expect(discovery.targets.count == 2)
    #expect(discovery.targets.first?.id == "codex")
    #expect(discovery.targets.first?.installed == true)
  }

  @Test("decodes a ready setup result")
  func decodesSetupResult() throws {
    let data = Data(
      #"{"protocolVersion":1,"ok":true,"action":"agents.setup","status":"ready","documentationUrl":"https://inline.chat/docs/agents","openUrl":"in://user/42","target":"codex","family":"bridge","instance":"codex-example","bot":{"id":42,"username":"codex_bot","name":"Codex"},"service":{"kind":"inline_bridge","action":"started","ready":true,"status":"running"},"integration":{"kind":"bridge_provider","action":"configured","version":"1"},"mapping":{"source":"bridge_account","action":"upserted"}}"#.utf8
    )

    let result = try CLIAgentSetupRunner.parseSetup(data)

    #expect(result.target == "codex")
    #expect(result.bot.id == 42)
    #expect(result.service.ready)
  }

  @Test("rejects a future protocol version")
  func rejectsFutureProtocol() {
    let data = Data(
      #"{"protocolVersion":2,"action":"agents.discover","documentationUrl":"https://inline.chat/docs/agents","targets":[]}"#.utf8
    )

    #expect(throws: AgentSetupFailure.self) {
      try CLIAgentSetupRunner.parseDiscovery(data)
    }
  }

  @Test("removes Inline overrides and relative PATH entries")
  func sanitizesEnvironment() {
    let environment = CLIAgentSetupRunner.sanitizedEnvironment([
      "INLINE_TOKEN": "not-a-real-token",
      "PATH": "relative-bin:/custom/bin",
    ])

    #expect(environment["INLINE_TOKEN"] == nil)
    #expect(environment["PATH"]?.contains("relative-bin") == false)
    #expect(environment["PATH"]?.contains("/custom/bin") == true)
  }
}
