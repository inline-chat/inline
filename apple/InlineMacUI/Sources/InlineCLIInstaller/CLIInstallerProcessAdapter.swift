import Foundation

struct CLIInstallerProcessResult: Sendable {
  let processIdentifier: pid_t
  let status: Int32
  let standardOutput: Data
  let standardError: Data
  let standardOutputWasTruncated: Bool
  let standardErrorWasTruncated: Bool
}

enum CLIInstallerProcessFailure: Error, Sendable {
  case launchFailed
  case timedOut(CLIInstallerProcessResult)
  case cancelled(CLIInstallerProcessResult)
}

/// Async integration adapter for the smaller Foundation exact-child runner.
///
/// This is appropriate for `/usr/bin/tar` and `inline --version`: both commands
/// must own exactly one child and must not leave descendants holding inherited
/// stdout/stderr descriptors. Commands that intentionally own a process tree
/// belong on the POSIX `BoundedSubprocess` path instead.
enum CLIInstallerProcessAdapter {
  static func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: TimeInterval,
    maximumOutputBytes: Int
  ) async throws -> CLIInstallerProcessResult {
    let operation = FoundationSubprocessOperation()
    let priority = Task.currentPriority

    return try await withTaskCancellationHandler {
      do {
        let result = try await Task.detached(priority: priority) {
          try FoundationBoundedSubprocess.run(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            operation: operation
          )
        }.value
        try Task.checkCancellation()
        return convert(result)
      } catch FoundationBoundedSubprocessFailure.launchFailed {
        throw CLIInstallerProcessFailure.launchFailed
      } catch FoundationBoundedSubprocessFailure.timedOut(let result) {
        throw CLIInstallerProcessFailure.timedOut(convert(result))
      } catch FoundationBoundedSubprocessFailure.cancelled(let result) {
        throw CLIInstallerProcessFailure.cancelled(convert(result))
      }
    } onCancel: {
      // `Task.detached` does not inherit cancellation. The operation's lock
      // latches this request across its launch/registration critical section.
      operation.cancel()
    }
  }

  private static func convert(
    _ result: FoundationBoundedSubprocessResult
  ) -> CLIInstallerProcessResult {
    CLIInstallerProcessResult(
      processIdentifier: result.processIdentifier,
      status: result.status,
      standardOutput: result.standardOutput,
      standardError: result.standardError,
      standardOutputWasTruncated: result.standardOutputWasTruncated,
      standardErrorWasTruncated: result.standardErrorWasTruncated
    )
  }
}
