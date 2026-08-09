import Darwin
import Foundation
import Testing
@testable import InlineCLIInstaller

@Suite("CLI installer/auth exact-child process adapters", .serialized)
struct CLIProcessExecutionTests {
  @Test("batch adapter concurrently drains both streams after retention caps")
  func batchDrainsBothStreams() async throws {
    let result = try await runBatchShell(
      "i=0; while [ $i -lt 20000 ]; do printf 'out-0123456789'; printf 'err-0123456789' >&2; i=$((i + 1)); done",
      maximumOutputBytes: 8 * 1_024
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.count == 8 * 1_024)
    #expect(result.standardError.count == 8 * 1_024)
    #expect(result.standardOutputWasTruncated)
    #expect(result.standardErrorWasTruncated)
  }

  @Test("batch adapter bridges task cancellation to the latched exact child")
  func batchCancellation() async throws {
    let command = Task {
      try await runBatchShell("trap '' TERM; while :; do :; done", timeout: 30)
    }
    try await Task.sleep(for: .milliseconds(100))
    command.cancel()

    do {
      _ = try await command.value
      Issue.record("Expected cancellation")
    } catch CLIInstallerProcessFailure.cancelled(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("auth adapter drains large stderr and surplus stdout without deadlock")
  func authDrainsSurplusOutput() async throws {
    let ready = #"{"version":1,"status":"ready","callbackUrl":"inline://cli-auth?version=1&port=54321&capability=fixture"}"#
    let result = #"{"status":"authenticated","userId":42,"tokenSaved":true,"profileLoaded":false,"warning":null}"#
    let script = """
      printf '%s\\n' '\(ready)'
      i=0; while [ $i -lt 20000 ]; do printf 'token=not-a-real-secret;' >&2; i=$((i + 1)); done
      printf '%s\\n' '\(result)'
      i=0; while [ $i -lt 20000 ]; do printf 'surplus-output;' ; i=$((i + 1)); done
      """

    let processResult = try await runAuthShell(script) { data in
      _ = try CLIAuthBootstrapper.parseReady(data)
    }

    #expect(processResult.status == 0)
    #expect(processResult.standardError.count == 8 * 1_024)
    #expect(processResult.standardErrorWasTruncated)
    let authenticated = try #require(processResult.resultLine)
    #expect(try CLIAuthBootstrapper.parseResult(authenticated).userID == 42)
  }

  @Test("auth adapter rejects an oversized ready line and joins the child")
  func authRejectsOversizedReadyLine() async throws {
    do {
      _ = try await runAuthShell(
        "i=0; while [ $i -lt 20000 ]; do printf 'x'; i=$((i + 1)); done; echo; while :; do :; done",
        maximumReadyBytes: 1_024
      ) { _ in
        Issue.record("Oversized ready line must not be delivered")
      }
      Issue.record("Expected invalid output")
    } catch CLIAuthHandshakeProcessFailure.invalidOutputLine(let index, let result) {
      #expect(index == 0)
      #expect(result.processIdentifier > 1)
      #expect(!processExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("auth timeout terminates and joins the exact child")
  func authTimeout() async throws {
    do {
      _ = try await runAuthShell("trap '' TERM; while :; do :; done", timeout: 0.1) { _ in }
      Issue.record("Expected timeout")
    } catch CLIAuthHandshakeProcessFailure.timedOut(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("auth cancellation terminates and joins the exact child")
  func authCancellation() async throws {
    let command = Task {
      try await runAuthShell("trap '' TERM; while :; do :; done", timeout: 30) { _ in }
    }
    try await Task.sleep(for: .milliseconds(100))
    command.cancel()

    do {
      _ = try await command.value
      Issue.record("Expected cancellation")
    } catch CLIAuthHandshakeProcessFailure.cancelled(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("auth UI diagnostics never contain child stderr")
  func authDiagnosticsAreFixed() {
    let input = Data("token=not-a-real-secret user=person@example.com".utf8)
    let detail = CLIAuthBootstrapper.commandFailureDetail(
      standardError: input,
      wasTruncated: false
    )
    let truncated = CLIAuthBootstrapper.commandFailureDetail(
      standardError: input,
      wasTruncated: true
    )

    #expect(detail == "The installed CLI reported an authentication error.")
    #expect(truncated?.contains("truncated") == true)
    #expect(detail?.contains("not-a-real-secret") == false)
    #expect(detail?.contains("person@example.com") == false)
  }

  @Test("installer child environment removes Inline overrides")
  func installerEnvironmentIsSanitized() {
    let environment = CLIInstallerService.processEnvironment([
      "HOME": "/Users/test",
      "PATH": "relative:/custom/bin",
      "INLINE_TOKEN": "not-a-real-secret",
    ])

    #expect(environment["HOME"] == "/Users/test")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["INLINE_TOKEN"] == nil)
  }

  private func runBatchShell(
    _ script: String,
    maximumOutputBytes: Int = 1_024,
    timeout: TimeInterval = 5
  ) async throws -> CLIInstallerProcessResult {
    try await CLIInstallerProcessAdapter.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes
    )
  }

  private func runAuthShell(
    _ script: String,
    maximumReadyBytes: Int = 8 * 1_024,
    timeout: TimeInterval = 5,
    onReady: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> CLIAuthHandshakeProcessResult {
    try await CLIAuthHandshakeProcess.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: ["PATH": "/usr/bin:/bin"],
      configuration: CLIAuthHandshakeProcess.Configuration(
        timeout: timeout,
        maximumReadyBytes: maximumReadyBytes,
        maximumResultBytes: 8 * 1_024,
        maximumErrorBytes: 8 * 1_024
      ),
      onReady: onReady
    )
  }

  private func processExists(_ processIdentifier: pid_t) -> Bool {
    if Darwin.kill(processIdentifier, 0) == 0 { return true }
    return errno == EPERM
  }
}
