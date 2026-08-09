import Darwin
import Foundation

struct CLIAuthHandshakeProcessResult: Sendable {
  let processIdentifier: pid_t
  let status: Int32
  let resultLine: Data?
  let standardError: Data
  let standardErrorWasTruncated: Bool
}

enum CLIAuthHandshakeProcessFailure: Error, Sendable {
  case launchFailed
  case invalidOutputLine(Int, CLIAuthHandshakeProcessResult)
  case timedOut(CLIAuthHandshakeProcessResult)
  case cancelled(CLIAuthHandshakeProcessResult)
}

/// Exact-child adapter for the CLI's two-line mac-app authentication protocol.
///
/// stdout and stderr are drained from launch until EOF. Only the bounded ready
/// and result lines are retained; extra stdout and bytes after the stderr cap
/// are discarded while draining continues. The CLI must not leave descendants
/// holding inherited pipe descriptors after its exact child exits.
enum CLIAuthHandshakeProcess {
  struct Configuration: Sendable {
    let timeout: TimeInterval
    let maximumReadyBytes: Int
    let maximumResultBytes: Int
    let maximumErrorBytes: Int
  }

  static func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    configuration: Configuration,
    onReady: @escaping @Sendable (Data) async throws -> Void
  ) async throws -> CLIAuthHandshakeProcessResult {
    let operation = FoundationSubprocessOperation()
    let session = CLIAuthHandshakeSession(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      timeout: configuration.timeout,
      lineLimits: [configuration.maximumReadyBytes, configuration.maximumResultBytes],
      maximumErrorBytes: configuration.maximumErrorBytes,
      operation: operation
    )

    return try await withTaskCancellationHandler {
      do {
        try session.launch()
      } catch let failure as CLIAuthHandshakeProcessFailure {
        throw failure
      } catch {
        throw CLIAuthHandshakeProcessFailure.launchFailed
      }

      let readyLine: Data
      switch session.outputLine(at: 0) {
      case .value(let data):
        readyLine = data
      case .tooLong, .endOfFile:
        throw invalidLineFailure(index: 0, session: session, operation: operation)
      }

      if Task.isCancelled || operation.requestedStopReason == .cancelled {
        throw CLIAuthHandshakeProcessFailure.cancelled(session.join())
      }
      if operation.requestedStopReason == .timedOut {
        throw CLIAuthHandshakeProcessFailure.timedOut(session.join())
      }

      do {
        try await onReady(readyLine)
      } catch {
        let reasonBeforeStop = operation.requestedStopReason
        operation.cancel()
        let result = session.join()
        if Task.isCancelled || reasonBeforeStop == .cancelled {
          throw CLIAuthHandshakeProcessFailure.cancelled(result)
        }
        if reasonBeforeStop == .timedOut {
          throw CLIAuthHandshakeProcessFailure.timedOut(result)
        }
        throw error
      }

      let resultLine: Data
      switch session.outputLine(at: 1) {
      case .value(let data):
        resultLine = data
      case .tooLong, .endOfFile:
        throw invalidLineFailure(index: 1, session: session, operation: operation)
      }

      let rawResult = session.join(resultLine: resultLine)
      if Task.isCancelled || operation.requestedStopReason == .cancelled {
        throw CLIAuthHandshakeProcessFailure.cancelled(rawResult)
      }
      if operation.requestedStopReason == .timedOut {
        throw CLIAuthHandshakeProcessFailure.timedOut(rawResult)
      }
      return rawResult
    } onCancel: {
      // Cancellation is explicitly bridged because any detached/background
      // work used by callers does not inherit it automatically.
      operation.cancel()
    }
  }

  private static func invalidLineFailure(
    index: Int,
    session: CLIAuthHandshakeSession,
    operation: FoundationSubprocessOperation
  ) -> CLIAuthHandshakeProcessFailure {
    let reasonBeforeStop = operation.requestedStopReason
    operation.cancel()
    let result = session.join()
    if Task.isCancelled || reasonBeforeStop == .cancelled {
      return .cancelled(result)
    }
    if reasonBeforeStop == .timedOut {
      return .timedOut(result)
    }
    return .invalidOutputLine(index, result)
  }
}

private final class CLIAuthHandshakeSession: @unchecked Sendable {
  private let process: Process
  private let standardOutputPipe = Pipe()
  private let standardErrorPipe = Pipe()
  private let outputDrain: CLIAuthOutputLineDrain
  private let errorDrain: CLIAuthCappedPipeDrain
  private let drains = DispatchGroup()
  private let operation: FoundationSubprocessOperation
  private let timeout: TimeInterval
  private let timeoutGate = CLIAuthTimeoutGate()
  private var timeoutTask: DispatchWorkItem?
  private var launched = false
  private var joinedResult: CLIAuthHandshakeProcessResult?

  init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: TimeInterval,
    lineLimits: [Int],
    maximumErrorBytes: Int,
    operation: FoundationSubprocessOperation
  ) {
    process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = standardOutputPipe
    process.standardError = standardErrorPipe
    outputDrain = CLIAuthOutputLineDrain(
      handle: standardOutputPipe.fileHandleForReading,
      limits: lineLimits
    )
    errorDrain = CLIAuthCappedPipeDrain(
      handle: standardErrorPipe.fileHandleForReading,
      maximumBytes: maximumErrorBytes
    )
    self.timeout = timeout
    self.operation = operation
  }

  func launch() throws {
    let didLaunch: Bool
    do {
      didLaunch = try operation.launch(process)
    } catch {
      throw CLIAuthHandshakeProcessFailure.launchFailed
    }
    guard didLaunch else {
      throw CLIAuthHandshakeProcessFailure.cancelled(Self.emptyResult())
    }
    launched = true

    try? standardOutputPipe.fileHandleForWriting.close()
    try? standardErrorPipe.fileHandleForWriting.close()
    outputDrain.start(in: drains)
    errorDrain.start(in: drains)

    let timeoutTask = DispatchWorkItem { [operation, timeoutGate] in
      timeoutGate.requestTimeout(operation: operation)
    }
    self.timeoutTask = timeoutTask
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: timeoutTask
    )
  }

  func outputLine(at index: Int) -> CLIAuthOutputLineDrain.Line {
    outputDrain.line(at: index)
  }

  func join(resultLine: Data? = nil) -> CLIAuthHandshakeProcessResult {
    if let joinedResult {
      if resultLine == nil || joinedResult.resultLine != nil { return joinedResult }
      return CLIAuthHandshakeProcessResult(
        processIdentifier: joinedResult.processIdentifier,
        status: joinedResult.status,
        resultLine: resultLine,
        standardError: joinedResult.standardError,
        standardErrorWasTruncated: joinedResult.standardErrorWasTruncated
      )
    }
    guard launched else { return Self.emptyResult() }

    process.waitUntilExit()
    timeoutGate.markCompleted()
    timeoutTask?.cancel()
    operation.markCompleted()
    drains.wait()
    operation.waitForStop()

    let error = errorDrain.result
    let result = CLIAuthHandshakeProcessResult(
      processIdentifier: process.processIdentifier,
      status: process.terminationStatus,
      resultLine: resultLine,
      standardError: error.data,
      standardErrorWasTruncated: error.wasTruncated
    )
    joinedResult = result
    return result
  }

  private static func emptyResult() -> CLIAuthHandshakeProcessResult {
    CLIAuthHandshakeProcessResult(
      processIdentifier: 0,
      status: 0,
      resultLine: nil,
      standardError: Data(),
      standardErrorWasTruncated: false
    )
  }
}

private final class CLIAuthTimeoutGate: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false

  func requestTimeout(operation: FoundationSubprocessOperation) {
    lock.lock()
    defer { lock.unlock() }
    guard !completed else { return }
    operation.timeOut()
  }

  func markCompleted() {
    lock.withLock { completed = true }
  }
}

private final class CLIAuthOutputLineDrain: @unchecked Sendable {
  enum Line: Sendable {
    case value(Data)
    case tooLong
    case endOfFile
  }

  private let handle: FileHandle
  private let limits: [Int]
  private let lock = NSLock()
  private let readySignals: [DispatchSemaphore]
  private var lines: [Line?]
  private var currentLine = Data()
  private var currentLineWasTruncated = false
  private var currentIndex = 0

  init(handle: FileHandle, limits: [Int]) {
    self.handle = handle
    self.limits = limits.map { max(0, $0) }
    readySignals = limits.map { _ in DispatchSemaphore(value: 0) }
    lines = limits.map { _ in nil }
  }

  func start(in group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .utility).async { [self] in
      defer {
        finishAtEndOfFile()
        try? handle.close()
        group.leave()
      }
      while true {
        // Unlike a batch collector, this protocol must observe a short first
        // line while the child remains alive waiting for authorization.
        // `availableData` returns as soon as pipe data is available instead of
        // waiting to fill a requested read length or reach EOF.
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        consume(chunk)
      }
    }
  }

  func line(at index: Int) -> Line {
    precondition(lines.indices.contains(index))
    readySignals[index].wait()
    return lock.withLock { lines[index] ?? .endOfFile }
  }

  private func consume(_ chunk: Data) {
    for byte in chunk {
      guard currentIndex < limits.count else { continue }
      if byte == 0x0A {
        publishCurrentLine()
      } else if currentLine.count < limits[currentIndex] {
        currentLine.append(byte)
      } else {
        if !currentLineWasTruncated {
          currentLineWasTruncated = true
          // An invalid oversized line is knowable as soon as it crosses the
          // cap. Wake the protocol consumer immediately, while this drain keeps
          // discarding through the delimiter so the pipe can never back up.
          publish(.tooLong, at: currentIndex)
        }
      }
    }
  }

  private func publishCurrentLine() {
    if !currentLineWasTruncated {
      publish(.value(currentLine), at: currentIndex)
    }
    currentIndex += 1
    currentLine = Data()
    currentLineWasTruncated = false
  }

  private func finishAtEndOfFile() {
    if currentIndex < limits.count, currentLineWasTruncated {
      currentIndex += 1
    }
    while currentIndex < limits.count {
      publish(.endOfFile, at: currentIndex)
      currentIndex += 1
    }
  }

  private func publish(_ line: Line, at index: Int) {
    lock.withLock { lines[index] = line }
    readySignals[index].signal()
  }
}

private final class CLIAuthCappedPipeDrain: @unchecked Sendable {
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
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        let appendCount = min(chunk.count, maximumBytes - data.count)
        if appendCount > 0 { data.append(chunk.prefix(appendCount)) }
        if appendCount < chunk.count { wasTruncated = true }
      }
    }
  }
}
