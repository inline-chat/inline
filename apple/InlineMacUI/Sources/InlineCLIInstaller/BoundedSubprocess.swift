import Darwin
import Foundation

struct BoundedSubprocessResult: Sendable {
  let processIdentifier: pid_t
  let status: Int32
  let standardOutput: Data
  let standardError: Data
  let standardOutputWasTruncated: Bool
  let standardErrorWasTruncated: Bool
}

enum BoundedSubprocessFailure: Error, Sendable {
  case launchFailed(Int32)
  case waitFailed(Int32)
  case timedOut(BoundedSubprocessResult)
  case cancelled(BoundedSubprocessResult)
}

final class BoundedSubprocessOperation: @unchecked Sendable {
  enum StopReason: Sendable {
    case cancelled
    case timedOut
  }

  private let lock = NSLock()
  private var processGroupID: pid_t?
  private var stopReason: StopReason?
  private var completed = false
  private var terminationSweep: DispatchSemaphore?

  var requestedStopReason: StopReason? {
    lock.withLock { stopReason }
  }

  func cancel() {
    requestStop(.cancelled)
  }

  func timeOut() {
    requestStop(.timedOut)
  }

  func didSpawn(processGroupID: pid_t) {
    let sweep = lock.withLock { () -> (pid_t, DispatchSemaphore)? in
      self.processGroupID = processGroupID
      return makeTerminationSweepIfNeeded()
    }
    Self.startTerminationSweep(sweep)
  }

  func markCompleted() {
    lock.withLock { completed = true }
  }

  func waitForTerminationSweep() {
    let sweep = lock.withLock { terminationSweep }
    sweep?.wait()
  }

  private func requestStop(_ reason: StopReason) {
    let sweep = lock.withLock { () -> (pid_t, DispatchSemaphore)? in
      guard stopReason == nil else { return nil }
      stopReason = reason
      return makeTerminationSweepIfNeeded()
    }
    Self.startTerminationSweep(sweep)
  }

  private func makeTerminationSweepIfNeeded() -> (pid_t, DispatchSemaphore)? {
    guard !completed,
          terminationSweep == nil,
          let processGroupID,
          processGroupID > 1,
          stopReason != nil else { return nil }
    let completion = DispatchSemaphore(value: 0)
    terminationSweep = completion
    return (processGroupID, completion)
  }

  private static func startTerminationSweep(_ sweep: (pid_t, DispatchSemaphore)?) {
    guard let (processGroupID, completion) = sweep else { return }
    DispatchQueue.global(qos: .utility).async {
      defer { completion.signal() }
      terminateProcessGroup(processGroupID)
    }
  }

  private static func terminateProcessGroup(_ processGroupID: pid_t) {
    guard processGroupID > 1 else { return }
    _ = Darwin.kill(-processGroupID, SIGTERM)

    let deadline = Date().addingTimeInterval(1)
    while processGroupExists(processGroupID), Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if processGroupExists(processGroupID) {
      _ = Darwin.kill(-processGroupID, SIGKILL)
      let killDeadline = Date().addingTimeInterval(1)
      while processGroupExists(processGroupID), Date() < killDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
    }
  }

  private static func processGroupExists(_ processGroupID: pid_t) -> Bool {
    if Darwin.kill(-processGroupID, 0) == 0 { return true }
    return errno == EPERM
  }
}

enum BoundedSubprocess {
  private enum SpawnResult {
    case success(pid_t)
    case failure(Int32)
  }

  static func run(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    timeout: TimeInterval,
    maximumOutputBytes: Int,
    operation: BoundedSubprocessOperation
  ) throws -> BoundedSubprocessResult {
    if let reason = operation.requestedStopReason {
      throw stoppedFailure(reason, result: emptyResult())
    }

    var standardOutputPipe = try PipeDescriptors.open()
    var standardErrorPipe: PipeDescriptors
    do {
      standardErrorPipe = try PipeDescriptors.open()
    } catch {
      standardOutputPipe.closeBoth()
      throw error
    }

    let spawnResult = spawn(
      executableURL: executableURL,
      arguments: arguments,
      environment: environment,
      standardOutputPipe: standardOutputPipe,
      standardErrorPipe: standardErrorPipe
    )
    standardOutputPipe.closeWriteEnd()
    standardErrorPipe.closeWriteEnd()

    let processIdentifier: pid_t
    switch spawnResult {
    case let .success(identifier):
      processIdentifier = identifier
    case let .failure(errorCode):
      standardOutputPipe.closeReadEnd()
      standardErrorPipe.closeReadEnd()
      if let reason = operation.requestedStopReason {
        throw stoppedFailure(reason, result: emptyResult())
      }
      throw BoundedSubprocessFailure.launchFailed(errorCode)
    }

    let lifecycle = SubprocessLifecycle()
    let standardOutputDrain = FileDescriptorDrain(
      fileDescriptor: standardOutputPipe.takeReadEnd(),
      maximumBytes: maximumOutputBytes,
      lifecycle: lifecycle
    )
    let standardErrorDrain = FileDescriptorDrain(
      fileDescriptor: standardErrorPipe.takeReadEnd(),
      maximumBytes: maximumOutputBytes,
      lifecycle: lifecycle
    )
    let drainGroup = DispatchGroup()
    standardOutputDrain.start(in: drainGroup)
    standardErrorDrain.start(in: drainGroup)

    operation.didSpawn(processGroupID: processIdentifier)
    let timeoutTask = DispatchWorkItem { operation.timeOut() }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: timeoutTask
    )

    var waitStatus: Int32 = 0
    var waitResult: pid_t
    repeat {
      waitResult = Darwin.waitpid(processIdentifier, &waitStatus, 0)
    } while waitResult == -1 && errno == EINTR
    let waitError = waitResult == -1 ? errno : 0

    timeoutTask.cancel()
    if waitError != 0 { operation.cancel() }
    lifecycle.markChildExited()
    operation.markCompleted()
    drainGroup.wait()
    operation.waitForTerminationSweep()

    let standardOutput = standardOutputDrain.result
    let standardError = standardErrorDrain.result
    let result = BoundedSubprocessResult(
      processIdentifier: processIdentifier,
      status: Self.terminationStatus(from: waitStatus),
      standardOutput: standardOutput.data,
      standardError: standardError.data,
      standardOutputWasTruncated: standardOutput.wasTruncated,
      standardErrorWasTruncated: standardError.wasTruncated
    )

    if waitError != 0 {
      throw BoundedSubprocessFailure.waitFailed(waitError)
    }
    if let reason = operation.requestedStopReason {
      throw stoppedFailure(reason, result: result)
    }
    return result
  }

  private static func spawn(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    standardOutputPipe: PipeDescriptors,
    standardErrorPipe: PipeDescriptors
  ) -> SpawnResult {
    var fileActions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&fileActions) == 0,
          posix_spawnattr_init(&attributes) == 0 else {
      if fileActions != nil { posix_spawn_file_actions_destroy(&fileActions) }
      if attributes != nil { posix_spawnattr_destroy(&attributes) }
      return .failure(ENOMEM)
    }
    defer {
      posix_spawn_file_actions_destroy(&fileActions)
      posix_spawnattr_destroy(&attributes)
    }

    var emptySignalMask = sigset_t()
    var defaultSignals = sigset_t()
    sigemptyset(&emptySignalMask)
    sigemptyset(&defaultSignals)
    for signal in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] {
      sigaddset(&defaultSignals, signal)
    }
    let flags = Int16(
      POSIX_SPAWN_SETPGROUP
        | POSIX_SPAWN_CLOEXEC_DEFAULT
        | POSIX_SPAWN_SETSIGDEF
        | POSIX_SPAWN_SETSIGMASK
    )
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
          posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0,
          posix_spawn_file_actions_addopen(
            &fileActions,
            STDIN_FILENO,
            "/dev/null",
            O_RDONLY,
            0
          ) == 0,
          posix_spawn_file_actions_adddup2(
            &fileActions,
            standardOutputPipe.writeEnd,
            STDOUT_FILENO
          ) == 0,
          posix_spawn_file_actions_adddup2(
            &fileActions,
            standardErrorPipe.writeEnd,
            STDERR_FILENO
          ) == 0,
          posix_spawn_file_actions_addclose(&fileActions, standardOutputPipe.readEnd) == 0,
          posix_spawn_file_actions_addclose(&fileActions, standardOutputPipe.writeEnd) == 0,
          posix_spawn_file_actions_addclose(&fileActions, standardErrorPipe.readEnd) == 0,
          posix_spawn_file_actions_addclose(&fileActions, standardErrorPipe.writeEnd) == 0 else {
      return .failure(EINVAL)
    }

    let argv = [executableURL.path] + arguments
    let environmentValues = environment
      .map { "\($0.key)=\($0.value)" }
      .sorted()
    guard let argumentPointers = MutableCStringArray(argv),
          let environmentPointers = MutableCStringArray(environmentValues) else {
      return .failure(ENOMEM)
    }
    var processIdentifier: pid_t = 0
    let spawnError = argumentPointers.withUnsafeMutablePointer { argumentPointer in
      environmentPointers.withUnsafeMutablePointer { environmentPointer in
        posix_spawn(
          &processIdentifier,
          executableURL.path,
          &fileActions,
          &attributes,
          argumentPointer,
          environmentPointer
        )
      }
    }
    return spawnError == 0 ? .success(processIdentifier) : .failure(spawnError)
  }

  private static func terminationStatus(from waitStatus: Int32) -> Int32 {
    let signal = waitStatus & 0x7F
    if signal == 0 {
      return (waitStatus >> 8) & 0xFF
    }
    return 128 + signal
  }

  private static func stoppedFailure(
    _ reason: BoundedSubprocessOperation.StopReason,
    result: BoundedSubprocessResult
  ) -> BoundedSubprocessFailure {
    switch reason {
    case .cancelled:
      .cancelled(result)
    case .timedOut:
      .timedOut(result)
    }
  }

  private static func emptyResult() -> BoundedSubprocessResult {
    BoundedSubprocessResult(
      processIdentifier: 0,
      status: 0,
      standardOutput: Data(),
      standardError: Data(),
      standardOutputWasTruncated: false,
      standardErrorWasTruncated: false
    )
  }
}

private final class MutableCStringArray {
  private var pointers: [UnsafeMutablePointer<CChar>?]

  init?(_ strings: [String]) {
    var allocated: [UnsafeMutablePointer<CChar>?] = []
    allocated.reserveCapacity(strings.count + 1)
    for string in strings {
      guard let pointer = strdup(string) else {
        for pointer in allocated { free(pointer) }
        return nil
      }
      allocated.append(pointer)
    }
    allocated.append(nil)
    pointers = allocated
  }

  deinit {
    for pointer in pointers where pointer != nil { free(pointer) }
  }

  func withUnsafeMutablePointer<ResultValue>(
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> ResultValue
  ) -> ResultValue {
    pointers.withUnsafeMutableBufferPointer { buffer in
      body(buffer.baseAddress!)
    }
  }
}

private struct PipeDescriptors {
  private(set) var readEnd: Int32
  private(set) var writeEnd: Int32

  static func open() throws -> PipeDescriptors {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&descriptors) == 0 else {
      throw BoundedSubprocessFailure.launchFailed(errno)
    }
    let flags = Darwin.fcntl(descriptors[0], F_GETFL)
    guard flags != -1,
          Darwin.fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != -1 else {
      let errorCode = errno
      Darwin.close(descriptors[0])
      Darwin.close(descriptors[1])
      throw BoundedSubprocessFailure.launchFailed(errorCode)
    }
    return PipeDescriptors(readEnd: descriptors[0], writeEnd: descriptors[1])
  }

  mutating func takeReadEnd() -> Int32 {
    defer { readEnd = -1 }
    return readEnd
  }

  mutating func closeReadEnd() {
    guard readEnd >= 0 else { return }
    Darwin.close(readEnd)
    readEnd = -1
  }

  mutating func closeWriteEnd() {
    guard writeEnd >= 0 else { return }
    Darwin.close(writeEnd)
    writeEnd = -1
  }

  mutating func closeBoth() {
    closeReadEnd()
    closeWriteEnd()
  }
}

private final class SubprocessLifecycle: @unchecked Sendable {
  private let lock = NSLock()
  private var childExited = false

  var didChildExit: Bool {
    lock.withLock { childExited }
  }

  func markChildExited() {
    lock.withLock { childExited = true }
  }
}

private final class FileDescriptorDrain: @unchecked Sendable {
  struct Result: Sendable {
    let data: Data
    let wasTruncated: Bool
  }

  private let fileDescriptor: Int32
  private let maximumBytes: Int
  private let lifecycle: SubprocessLifecycle
  private var data = Data()
  private var wasTruncated = false

  init(fileDescriptor: Int32, maximumBytes: Int, lifecycle: SubprocessLifecycle) {
    self.fileDescriptor = fileDescriptor
    self.maximumBytes = max(0, maximumBytes)
    self.lifecycle = lifecycle
  }

  var result: Result {
    Result(data: data, wasTruncated: wasTruncated)
  }

  func start(in group: DispatchGroup) {
    group.enter()
    DispatchQueue.global(qos: .utility).async { [self] in
      defer { group.leave() }
      drain()
    }
  }

  private func drain() {
    defer { Darwin.close(fileDescriptor) }
    var buffer = [UInt8](repeating: 0, count: 32 * 1_024)

    while true {
      var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
      let pollResult = Darwin.poll(&descriptor, 1, 100)
      if pollResult == -1 {
        if errno == EINTR { continue }
        return
      }
      if pollResult == 0 {
        if lifecycle.didChildExit {
          _ = readAvailable(into: &buffer)
          return
        }
        continue
      }

      if readAvailable(into: &buffer) { return }
      if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 { return }
      if descriptor.revents & Int16(POLLHUP) != 0 { return }
    }
  }

  @discardableResult
  private func readAvailable(into buffer: inout [UInt8]) -> Bool {
    while true {
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
      }
      if bytesRead > 0 {
        let appendCount = min(bytesRead, maximumBytes - data.count)
        if appendCount > 0 {
          buffer.withUnsafeBytes { rawBuffer in
            data.append(rawBuffer.bindMemory(to: UInt8.self).baseAddress!, count: appendCount)
          }
        }
        if bytesRead > appendCount { wasTruncated = true }
        continue
      }
      if bytesRead == 0 { return true }
      if errno == EINTR { continue }
      if errno == EAGAIN || errno == EWOULDBLOCK { return false }
      return true
    }
  }
}
