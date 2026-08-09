import Darwin
import Foundation
import Testing
@testable import InlineCLIInstaller

@Suite("Foundation exact-child subprocess alternative")
struct FoundationBoundedSubprocessTests {
  @Test("concurrently drains both streams after retention caps")
  func drainsBothStreams() throws {
    let result = try runShell(
      "i=0; while [ $i -lt 20000 ]; do printf 'out-0123456789'; printf 'err-0123456789' >&2; i=$((i + 1)); done",
      maximumOutputBytes: 8 * 1_024
    )

    #expect(result.status == 0)
    #expect(result.standardOutput.count == 8 * 1_024)
    #expect(result.standardError.count == 8 * 1_024)
    #expect(result.standardOutputWasTruncated)
    #expect(result.standardErrorWasTruncated)
  }

  @Test("cancellation latched before launch prevents spawning")
  func prelaunchCancellation() {
    let operation = FoundationSubprocessOperation()
    operation.cancel()

    #expect(throws: FoundationBoundedSubprocessFailure.self) {
      _ = try runShell("exit 0", operation: operation)
    }
  }

  @Test("completed children are not retroactively classified as stopped")
  func completedChildWinsStopRace() throws {
    for _ in 0 ..< 50 {
      let result = try runShell("exit 0", timeout: 0.5)
      #expect(result.status == 0)
    }
  }

  @Test("timeout terminates and joins the exact child")
  func timeout() {
    do {
      _ = try runShell("trap '' TERM; while :; do :; done", timeout: 0.1)
      Issue.record("Expected timeout")
    } catch FoundationBoundedSubprocessFailure.timedOut(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  @Test("cancellation terminates and joins the exact child")
  func cancellation() async throws {
    let operation = FoundationSubprocessOperation()
    let command = Task.detached {
      try runShell(
        "trap '' TERM; while :; do :; done",
        operation: operation,
        timeout: 30
      )
    }
    try await Task.sleep(for: .milliseconds(100))
    operation.cancel()

    do {
      _ = try await command.value
      Issue.record("Expected cancellation")
    } catch FoundationBoundedSubprocessFailure.cancelled(let result) {
      #expect(result.processIdentifier > 1)
      #expect(!processExists(result.processIdentifier))
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }

  private func runShell(
    _ script: String,
    maximumOutputBytes: Int = 1_024,
    operation: FoundationSubprocessOperation = FoundationSubprocessOperation(),
    timeout: TimeInterval = 5
  ) throws -> FoundationBoundedSubprocessResult {
    try FoundationBoundedSubprocess.run(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script],
      environment: ["PATH": "/usr/bin:/bin"],
      timeout: timeout,
      maximumOutputBytes: maximumOutputBytes,
      operation: operation
    )
  }

  private func processExists(_ processIdentifier: pid_t) -> Bool {
    if Darwin.kill(processIdentifier, 0) == 0 { return true }
    return errno == EPERM
  }
}
