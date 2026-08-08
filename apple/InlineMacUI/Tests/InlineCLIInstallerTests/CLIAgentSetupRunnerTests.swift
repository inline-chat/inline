import Darwin
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

  @Test("drains and bounds large stdout")
  func drainsLargeStandardOutput() throws {
    let result = try runShell(
      "i=0; while [ $i -lt 20000 ]; do printf 'stdout-0123456789'; i=$((i + 1)); done",
      maximumOutputBytes: 8 * 1_024
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.count == 8 * 1_024)
    #expect(result.standardOutputWasTruncated)
    #expect(result.standardError.isEmpty)
    #expect(!result.standardErrorWasTruncated)
  }

  @Test("drains and bounds large stderr")
  func drainsLargeStandardError() throws {
    let result = try runShell(
      "i=0; while [ $i -lt 20000 ]; do printf 'stderr-0123456789' >&2; i=$((i + 1)); done",
      maximumOutputBytes: 8 * 1_024
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.isEmpty)
    #expect(!result.standardOutputWasTruncated)
    #expect(result.standardError.count == 8 * 1_024)
    #expect(result.standardErrorWasTruncated)
  }

  @Test("drains both full pipes without deadlock")
  func drainsBothStreamsConcurrently() throws {
    let result = try runShell(
      "i=0; while [ $i -lt 20000 ]; do printf 'out-0123456789'; printf 'err-0123456789' >&2; i=$((i + 1)); done",
      maximumOutputBytes: 16 * 1_024
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.count == 16 * 1_024)
    #expect(result.standardError.count == 16 * 1_024)
    #expect(result.standardOutputWasTruncated)
    #expect(result.standardErrorWasTruncated)
  }

  @Test("timeout terminates the isolated process group")
  func timeoutTerminatesProcessGroup() throws {
    let operation = BoundedSubprocessOperation()

    do {
      _ = try runStubbornProcess(operation: operation, timeout: 0.1)
      Issue.record("Expected the command to time out")
    } catch BoundedSubprocessFailure.timedOut(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processGroupExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("cancellation terminates the isolated process group")
  func cancellationTerminatesProcessGroup() async throws {
    let operation = BoundedSubprocessOperation()
    let command = Task.detached {
      try runStubbornProcess(operation: operation, timeout: 30)
    }

    try await Task.sleep(for: .milliseconds(100))
    operation.cancel()
    do {
      _ = try await command.value
      Issue.record("Expected the command to be cancelled")
    } catch BoundedSubprocessFailure.cancelled(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processGroupExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("bounds fallback diagnostics and removes controls")
  func boundsSafeDetail() {
    let input = Data(("first\u{0}line\n" + String(repeating: "x", count: 2_000)).utf8)

    let detail = CLIAgentSetupRunner.safeDetail(input)

    #expect(detail?.contains("\u{0}") == false)
    #expect(detail?.count == 1_000)
  }

  private func runShell(
    _ script: String,
    maximumOutputBytes: Int,
    operation: BoundedSubprocessOperation = BoundedSubprocessOperation(),
    timeout: TimeInterval = 5
  ) throws -> BoundedSubprocessResult {
    try BoundedSubprocess.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes,
      operation: operation
    )
  }

  private func runStubbornProcess(
    operation: BoundedSubprocessOperation,
    timeout: TimeInterval
  ) throws -> BoundedSubprocessResult {
    try runShell(
      "trap '' TERM; (trap '' TERM; while :; do sleep 1; done) & wait",
      maximumOutputBytes: 1_024,
      operation: operation,
      timeout: timeout
    )
  }

  private func processGroupExists(_ processGroupID: pid_t) -> Bool {
    if Darwin.kill(-processGroupID, 0) == 0 { return true }
    return errno == EPERM
  }
}
