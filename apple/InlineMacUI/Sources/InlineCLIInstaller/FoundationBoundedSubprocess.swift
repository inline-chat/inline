import Darwin
import Foundation

/// Smaller Foundation alternative to `BoundedSubprocess` for commands whose
/// contract owns exactly one child and forbids inherited stdout/stderr writers.
struct FoundationBoundedSubprocessResult: Sendable {
  let processIdentifier: pid_t
  let status: Int32
  let standardOutput: Data
  let standardError: Data
  let standardOutputWasTruncated: Bool
  let standardErrorWasTruncated: Bool
}

enum FoundationBoundedSubprocessFailure: Error, Sendable {
  case launchFailed
  case timedOut(FoundationBoundedSubprocessResult)
  case cancelled(FoundationBoundedSubprocessResult)
}

final class FoundationSubprocessOperation: @unchecked Sendable {
  enum StopReason: Sendable {
    case cancelled
    case timedOut
  }

  private let lock = NSLock()
  private var process: Process?
  private var stopReason: StopReason?
  private var completed = false
  private var stopCompletion: DispatchSemaphore?

  var requestedStopReason: StopReason? {
    lock.withLock { stopReason }
  }

  func cancel() {
    requestStop(.cancelled)
  }

  func timeOut() {
    requestStop(.timedOut)
  }

  /// Holds the registration lock through `run()` so cancellation cannot land
  /// between a preflight check and process registration.
  func launch(_ process: Process) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard stopReason == nil else { return false }
    self.process = process
    do {
      try process.run()
      return true
    } catch {
      self.process = nil
      throw error
    }
  }

  func markCompleted() {
    lock.withLock {
      completed = true
      process = nil
    }
  }

  func waitForStop() {
    lock.withLock { stopCompletion }?.wait()
  }

  private func requestStop(_ reason: StopReason) {
    let stop = lock.withLock { () -> (Process, DispatchSemaphore)? in
      guard stopReason == nil else { return nil }
      guard !completed else { return nil }
      guard let process else {
        // Latch cancellation before launch registration.
        stopReason = reason
        return nil
      }
      // A cancelled DispatchWorkItem may already be executing. Do not convert a
      // child that won the exit race into a timeout/cancellation after the fact.
      guard process.isRunning else {
        completed = true
        self.process = nil
        return nil
      }
      stopReason = reason
      let completion = DispatchSemaphore(value: 0)
      stopCompletion = completion
      return (process, completion)
    }
    guard let (process, completion) = stop else { return }
    DispatchQueue.global(qos: .utility).async {
      defer { completion.signal() }
      FoundationBoundedSubprocess.stopExactChild(process)
    }
  }
}

enum FoundationBoundedSubprocess {
  static func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: TimeInterval,
    maximumOutputBytes: Int,
    operation: FoundationSubprocessOperation
  ) throws -> FoundationBoundedSubprocessResult {
    if let reason = operation.requestedStopReason {
      throw stoppedFailure(reason, result: emptyResult())
    }

    let process = Process()
    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutputPipe
    process.standardError = standardErrorPipe

    let launched: Bool
    do {
      launched = try operation.launch(process)
    } catch {
      throw FoundationBoundedSubprocessFailure.launchFailed
    }
    guard launched else {
      throw stoppedFailure(operation.requestedStopReason ?? .cancelled, result: emptyResult())
    }

    try? standardOutputPipe.fileHandleForWriting.close()
    try? standardErrorPipe.fileHandleForWriting.close()

    let standardOutputDrain = FoundationPipeDrain(
      handle: standardOutputPipe.fileHandleForReading,
      maximumBytes: maximumOutputBytes
    )
    let standardErrorDrain = FoundationPipeDrain(
      handle: standardErrorPipe.fileHandleForReading,
      maximumBytes: maximumOutputBytes
    )
    let drains = DispatchGroup()
    standardOutputDrain.start(in: drains)
    standardErrorDrain.start(in: drains)

    let timeoutTask = DispatchWorkItem { operation.timeOut() }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: timeoutTask
    )

    process.waitUntilExit()
    operation.markCompleted()
    timeoutTask.cancel()
    operation.waitForStop()
    drains.wait()

    let standardOutput = standardOutputDrain.result
    let standardError = standardErrorDrain.result
    let result = FoundationBoundedSubprocessResult(
      processIdentifier: process.processIdentifier,
      status: process.terminationStatus,
      standardOutput: standardOutput.data,
      standardError: standardError.data,
      standardOutputWasTruncated: standardOutput.wasTruncated,
      standardErrorWasTruncated: standardError.wasTruncated
    )

    if let reason = operation.requestedStopReason {
      throw stoppedFailure(reason, result: result)
    }
    return result
  }

  fileprivate static func stopExactChild(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }

  private static func stoppedFailure(
    _ reason: FoundationSubprocessOperation.StopReason,
    result: FoundationBoundedSubprocessResult
  ) -> FoundationBoundedSubprocessFailure {
    switch reason {
    case .cancelled:
      .cancelled(result)
    case .timedOut:
      .timedOut(result)
    }
  }

  private static func emptyResult() -> FoundationBoundedSubprocessResult {
    FoundationBoundedSubprocessResult(
      processIdentifier: 0,
      status: 0,
      standardOutput: Data(),
      standardError: Data(),
      standardOutputWasTruncated: false,
      standardErrorWasTruncated: false
    )
  }
}

private final class FoundationPipeDrain: @unchecked Sendable {
  struct Result: Sendable {
    let data: Data
    let wasTruncated: Bool
  }

  private let handle: FileHandle
  private let maximumBytes: Int
  private var data = Data()
  private var wasTruncated = false

  init(handle: FileHandle, maximumBytes: Int) {
    self.handle = handle
    self.maximumBytes = max(0, maximumBytes)
  }

  var result: Result {
    Result(data: data, wasTruncated: wasTruncated)
  }

  func start(in group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .utility).async { [self] in
      defer {
        try? handle.close()
        group.leave()
      }
      while true {
        let chunk = try? handle.read(upToCount: 32 * 1_024)
        guard let chunk, !chunk.isEmpty else { return }
        let appendCount = min(chunk.count, maximumBytes - data.count)
        if appendCount > 0 {
          data.append(chunk.prefix(appendCount))
        }
        if appendCount < chunk.count {
          wasTruncated = true
        }
      }
    }
  }
}
