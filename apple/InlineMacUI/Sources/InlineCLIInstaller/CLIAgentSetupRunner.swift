import Darwin
import Foundation

public final class CLIAgentSetupRunner: AgentSetupCLIRunning, @unchecked Sendable {
  private struct CommandOutput: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: Data
  }

  private struct ErrorEnvelope: Decodable {
    struct Payload: Decodable {
      let code: String
      let message: String
      let hint: String?
      let examples: [String]?
    }

    let protocolVersion: Int?
    let status: String?
    let documentationURL: URL?
    let failedPhase: String?
    let timedOut: Bool?
    let changes: [String]?
    let recoveryCommands: [String]?
    let diagnosticReportPath: String?
    let retry: String?
    let error: Payload

    private enum CodingKeys: String, CodingKey {
      case protocolVersion
      case status
      case documentationURL = "documentationUrl"
      case failedPhase
      case timedOut
      case changes
      case recoveryCommands
      case diagnosticReportPath
      case retry
      case error
    }
  }

  private struct ResultEnvelope: Decodable {
    let protocolVersion: Int
    let event: String
    let result: AgentSetupResult
  }

  private static let protocolVersion = 1
  static let maximumOutputBytes = 512 * 1_024
  private static let discoveryTimeout: TimeInterval = 20
  private static let setupTimeout: TimeInterval = 10 * 60
  private static let documentationURL = URL(string: "https://inline.chat/docs/agents")!

  private let configuration: CLIInstallerConfiguration
  private let processState = AgentSetupProcessState()

  public init(configuration: CLIInstallerConfiguration = .production) {
    self.configuration = configuration
  }

  public func discover(installation: CLIInstallation) async throws -> AgentHarnessDiscovery {
    let operationID = try beginOperation()
    defer { finishOperation(operationID) }
    return try await withTaskCancellationHandler {
      let output = try await Task.detached(priority: .userInitiated) { [self] in
        return try run(
          operationID: operationID,
          installation: installation,
          arguments: Self.discoveryArguments,
          timeout: Self.discoveryTimeout
        )
      }.value
      try Task.checkCancellation()
      guard output.status == 0 else { throw failure(from: output) }
      return try Self.parseDiscovery(output.standardOutput)
    } onCancel: {
      cancel()
    }
  }

  public func setup(
    target: AgentHarnessTarget,
    installation: CLIInstallation,
    replaceExisting: Bool = false,
    progress: @escaping @Sendable (AgentSetupProgressEvent) -> Void
  ) async throws -> AgentSetupResult {
    guard target.installed, Self.isValidTargetID(target.id) else {
      throw AgentSetupFailure(
        code: "invalid_target",
        message: "The selected agent harness is not a valid installed target.",
        recoveryURL: Self.documentationURL
      )
    }

    let operationID = try beginOperation()
    defer { finishOperation(operationID) }
    return try await withTaskCancellationHandler {
      let output = try await Task.detached(priority: .userInitiated) { [self] in
        var output = try run(
          operationID: operationID,
          installation: installation,
          arguments: Self.setupArguments(
            targetID: target.id,
            replaceExisting: replaceExisting,
            appProtocol: true
          ),
          timeout: Self.setupTimeout,
          onStandardOutputLine: { line in
            if let event = Self.parseProgressEvent(line) {
              progress(event)
            }
          }
        )
        if Self.isUnsupportedAppProtocol(output) {
          progress(AgentSetupProgressEvent(
            protocolVersion: Self.protocolVersion,
            event: .phaseStarted,
            phase: .configuration
          ))
          output = try run(
            operationID: operationID,
            installation: installation,
            arguments: Self.setupArguments(
              targetID: target.id,
              replaceExisting: replaceExisting,
              appProtocol: false
            ),
            timeout: Self.setupTimeout
          )
          if output.status == 0 {
            progress(AgentSetupProgressEvent(
              protocolVersion: Self.protocolVersion,
              event: .phaseCompleted,
              phase: .configuration,
              outcome: "completed"
            ))
          }
        }
        return output
      }.value
      try Task.checkCancellation()
      guard output.status == 0 else { throw failure(from: output, targetID: target.id) }
      let result = try Self.parseSetup(output.standardOutput)
      guard result.target == target.id else {
        throw AgentSetupFailure(
          code: "unexpected_target",
          message: "Inline CLI configured a different harness than the one selected.",
          recoveryURL: Self.documentationURL
        )
      }
      return result
    } onCancel: {
      cancel()
    }
  }

  public func cancel() {
    let runningProcess = processState.requestCancellation()
    if runningProcess?.isRunning == true {
      runningProcess?.terminate()
    }
    DispatchQueue.global(qos: .utility).async {
      Self.stop(runningProcess)
    }
  }

  public func cancelAndWait() {
    Self.stopAndWait(processState.requestCancellation())
  }

  static let discoveryArguments = ["--json", "--compact", "agents", "discover"]

  static func setupArguments(
    targetID: String,
    replaceExisting: Bool,
    appProtocol: Bool = true
  ) -> [String] {
    var arguments = [
      "--verbose",
      "--json",
      "--compact",
      "agents",
      "setup",
      "--target",
      targetID,
      "--non-interactive",
    ]
    if appProtocol {
      arguments.append(contentsOf: ["--app-protocol", "1"])
    }
    if replaceExisting {
      arguments.append("--replace")
    }
    return arguments
  }

  static func parseDiscovery(_ data: Data) throws -> AgentHarnessDiscovery {
    let discovery: AgentHarnessDiscovery
    do {
      discovery = try JSONDecoder().decode(AgentHarnessDiscovery.self, from: data)
    } catch {
      throw invalidResponse("Inline CLI returned an unreadable harness list.")
    }
    guard discovery.protocolVersion == protocolVersion,
          discovery.action == "agents.discover" else {
      throw invalidResponse("Inline CLI uses an unsupported agent setup protocol. Update it and try again.")
    }
    return discovery
  }

  static func parseSetup(_ data: Data) throws -> AgentSetupResult {
    let result = directSetupResult(from: data) ?? envelopedSetupResult(from: data)
    guard let result else {
      throw invalidResponse("Inline CLI returned an unreadable agent setup result.")
    }
    guard result.protocolVersion == protocolVersion,
          result.ok,
          result.action == "agents.setup",
          result.bot.id > 0,
          validOpenURL(result.openURL, botID: result.bot.id) else {
      throw invalidResponse("Inline CLI returned an invalid agent setup result.")
    }
    return result
  }

  static func parseProgressEvent(_ data: Data) -> AgentSetupProgressEvent? {
    guard let event = try? JSONDecoder().decode(AgentSetupProgressEvent.self, from: data),
          event.protocolVersion == protocolVersion else { return nil }
    if let outcome = event.outcome,
       outcome.isEmpty || outcome.utf8.count > 64 || !outcome.utf8.allSatisfy(Self.isSafeCodeByte) {
      return nil
    }
    if let timeoutSeconds = event.timeoutSeconds,
       !(1 ... 10 * 60).contains(timeoutSeconds) {
      return nil
    }
    let message = event.message.map {
      safeStructuredText($0, maximumScalars: 500)
    }
    return AgentSetupProgressEvent(
      protocolVersion: event.protocolVersion,
      event: event.event,
      phase: event.phase,
      outcome: event.outcome,
      message: message,
      timeoutSeconds: event.timeoutSeconds
    )
  }

  private static func directSetupResult(from data: Data) -> AgentSetupResult? {
    try? JSONDecoder().decode(AgentSetupResult.self, from: data)
  }

  private static func envelopedSetupResult(from data: Data) -> AgentSetupResult? {
    for line in data.split(separator: 0x0A).reversed() {
      guard let envelope = try? JSONDecoder().decode(ResultEnvelope.self, from: Data(line)),
            envelope.protocolVersion == protocolVersion,
            envelope.event == "result" else { continue }
      return envelope.result
    }
    return nil
  }

  private static func validOpenURL(_ url: URL, botID: Int64) -> Bool {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return false
    }
    return components.scheme == "in"
      && components.host == "user"
      && components.path == "/\(botID)"
      && components.query == nil
      && components.fragment == nil
  }

  private func run(
    operationID: UUID,
    installation: CLIInstallation,
    arguments: [String],
    timeout: TimeInterval,
    onStandardOutputLine: (@Sendable (Data) -> Void)? = nil
  ) throws -> CommandOutput {
    try CLIExecutableVerifier.verify(
      installation.executableURL,
      configuration: configuration
    )
    guard FileManager.default.isExecutableFile(atPath: installation.executableURL.path) else {
      throw AgentSetupFailure(
        code: "cli_unavailable",
        message: "The installed Inline CLI could not be launched.",
        recoveryURL: Self.documentationURL
      )
    }

    let nextProcess = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    nextProcess.executableURL = installation.executableURL
    nextProcess.arguments = arguments
    nextProcess.environment = Self.sanitizedEnvironment(ProcessInfo.processInfo.environment)
    nextProcess.standardInput = FileHandle.nullDevice
    nextProcess.standardOutput = standardOutput
    nextProcess.standardError = standardError

    let launched: Bool
    do {
      launched = try processState.launch(nextProcess, operationID: operationID) {
        try nextProcess.run()
      }
    } catch {
      throw AgentSetupFailure(
        code: "cli_launch_failed",
        message: "Inline could not launch the installed CLI.",
        recoveryURL: Self.documentationURL
      )
    }
    guard launched else { throw CancellationError() }
    defer {
      processState.clear(nextProcess)
    }

    try? standardOutput.fileHandleForWriting.close()
    try? standardError.fileHandleForWriting.close()

    if isCancellationRequested(operationID) {
      Self.stop(nextProcess)
      throw CancellationError()
    }

    let outputGroup = DispatchGroup()
    let stdoutCapture = OutputCapture()
    let stderrCapture = OutputCapture()
    let outputLimitState = OutputLimitState()
    let stopOnOverflow: @Sendable () -> Void = {
      guard outputLimitState.markExceeded() else { return }
      Self.stop(nextProcess)
    }
    outputGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      let lineAccumulator = OutputLineAccumulator(onLine: onStandardOutputLine)
      stdoutCapture.store(
        Self.boundedDrain(
          standardOutput.fileHandleForReading,
          onOverflow: stopOnOverflow,
          onChunk: { lineAccumulator.consume($0) }
        )
      )
      lineAccumulator.finish()
      outputGroup.leave()
    }
    outputGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      stderrCapture.store(
        Self.boundedDrain(standardError.fileHandleForReading, onOverflow: stopOnOverflow)
      )
      outputGroup.leave()
    }

    let timeoutState = TimeoutState()
    let timeoutTask = DispatchWorkItem {
      guard nextProcess.isRunning else { return }
      timeoutState.markTimedOut()
      Self.stop(nextProcess)
    }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout,
      execute: timeoutTask
    )
    defer { timeoutTask.cancel() }

    nextProcess.waitUntilExit()
    if outputGroup.wait(timeout: .now() + 5) == .timedOut {
      try? standardOutput.fileHandleForReading.close()
      try? standardError.fileHandleForReading.close()
      outputGroup.wait()
    }
    let stdout = stdoutCapture.value
    let stderr = stderrCapture.value
    if timeoutState.didTimeOut {
      throw AgentSetupFailure(
        code: "setup_timed_out",
        message: "Inline CLI did not finish agent setup in time.",
        hint: "Rerun `inline agents setup --target <name>` in Terminal to continue debugging.",
        recoveryURL: Self.documentationURL,
        timedOut: true
      )
    }
    if outputLimitState.didExceed {
      throw AgentSetupFailure(
        code: "cli_output_too_large",
        message: "Inline CLI produced more setup output than the app can safely process.",
        hint: "Retry in Terminal with the provided setup command for bounded diagnostics.",
        recoveryURL: Self.documentationURL
      )
    }
    if isCancellationRequested(operationID) {
      throw CancellationError()
    }
    return CommandOutput(
      status: nextProcess.terminationStatus,
      standardOutput: stdout,
      standardError: stderr
    )
  }

  private func failure(from output: CommandOutput, targetID: String? = nil) -> AgentSetupFailure {
    if let structured = Self.parseFailure(output.standardError, targetID: targetID) {
      return structured
    }
    return AgentSetupFailure(
      code: "agent_setup_failed",
      message: "Inline CLI could not finish agent setup.",
      hint: "Run the same setup with Inline CLI in Terminal for detailed diagnostics.",
      recoveryURL: Self.documentationURL,
      retryCommand: targetID.map { "inline agents setup --target \($0) --non-interactive" }
    )
  }

  private static func isUnsupportedAppProtocol(_ output: CommandOutput) -> Bool {
    isUnsupportedAppProtocol(
      status: output.status,
      standardError: output.standardError
    )
  }

  static func isUnsupportedAppProtocol(status: Int32, standardError: Data) -> Bool {
    guard status == 2 else { return false }
    guard let message = String(data: standardError, encoding: .utf8) else { return false }
    return message.contains("--app-protocol")
  }

  private func beginOperation() throws -> UUID {
    guard let operationID = processState.begin() else {
      throw AgentSetupFailure(
        code: "operation_in_progress",
        message: "Another Inline agent setup operation is already running.",
        recoveryURL: Self.documentationURL
      )
    }
    return operationID
  }

  private func finishOperation(_ operationID: UUID) {
    processState.finish(operationID)
  }

  private func isCancellationRequested(_ operationID: UUID) -> Bool {
    processState.isCancellationRequested(operationID)
  }

  private static func isValidTargetID(_ id: String) -> Bool {
    !id.isEmpty && id.utf8.allSatisfy { byte in
      (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
    }
  }

  private static func invalidResponse(_ message: String) -> AgentSetupFailure {
    AgentSetupFailure(
      code: "invalid_cli_response",
      message: message,
      recoveryURL: documentationURL
    )
  }

  static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
    var sanitized = environment.filter { !$0.key.hasPrefix("INLINE_") }
    // Honor an explicit privacy opt-out without forwarding DSNs or auth/URL
    // overrides into the trusted app-to-CLI setup boundary.
    if let telemetry = environment["INLINE_CLI_TELEMETRY"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
       ["off", "0", "false"].contains(telemetry) {
      sanitized["INLINE_CLI_TELEMETRY"] = "off"
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let standardPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.local/bin",
      "\(home)/.bun/bin",
      "\(home)/.volta/bin",
      "\(home)/.asdf/shims",
      "\(home)/.local/share/mise/shims",
      "\(home)/.mise/shims",
      "\(home)/.cargo/bin",
      "\(home)/.fnm/current/bin",
      "\(home)/.nodenv/shims",
      "\(home)/.npm-global/bin",
      "\(home)/.local/share/pnpm",
      "\(home)/Library/pnpm",
      "\(home)/.claude/local",
      "\(home)/.opencode/bin",
      "\(home)/.amp/bin",
      "\(home)/.hermes/bin",
      "/usr/bin",
      "/bin",
      "/usr/sbin",
      "/sbin",
    ]
    let inherited = sanitized["PATH"]?
      .split(separator: ":")
      .map(String.init)
      .filter { $0.hasPrefix("/") } ?? []
    sanitized["PATH"] = Self.uniquePaths(standardPaths + inherited).joined(separator: ":")
    return sanitized
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  static func boundedDrain(_ handle: FileHandle) -> Data {
    boundedDrain(handle, onOverflow: nil, onChunk: nil)
  }

  private static func boundedDrain(
    _ handle: FileHandle,
    onOverflow: (@Sendable () -> Void)?,
    onChunk: (@Sendable (Data) -> Void)? = nil
  ) -> Data {
    var retained = Data()
    var reportedOverflow = false
    do {
      while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        let remaining = maximumOutputBytes - retained.count
        if remaining > 0 {
          retained.append(contentsOf: chunk.prefix(remaining))
          onChunk?(Data(chunk.prefix(remaining)))
        }
        if chunk.count > remaining, !reportedOverflow {
          reportedOverflow = true
          onOverflow?()
        }
      }
    } catch {}
    return retained
  }

  public static func safeStructuredText(_ value: String, maximumScalars: Int) -> String {
    var text = value.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path,
      with: "~"
    )
    for pattern in [
      #"(?i)\bBearer\s+[^\s\"']+"#,
      #"\b[0-9]+:IN[A-Za-z0-9_-]{12,}\b"#,
      #"(?i)\"?(token|secret|password|authorization|api[_-]?key)\"?\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^\s,}\]]+)"#,
      #"(?i)--(token|secret|password|authorization|api[_-]?key)(=|\s+)(\"[^\"]*\"|'[^']*'|[^\s]+)"#,
    ] {
      text = text.replacingOccurrences(
        of: pattern,
        with: "[redacted]",
        options: .regularExpression
      )
    }
    let scalars = text
      .unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) || $0.value == 10 }
      .prefix(maximumScalars)
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func safeCode(_ value: String) -> String {
    let filtered = value.lowercased().utf8.filter { byte in
      (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
    }
    let code = String(bytes: filtered.prefix(80), encoding: .utf8) ?? ""
    return code.isEmpty ? "agent_setup_failed" : code
  }

  private static func isSafeCodeByte(_ byte: UInt8) -> Bool {
    (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
  }

  static func parseFailure(_ data: Data, targetID: String? = nil) -> AgentSetupFailure? {
    // Diagnostics and provider warnings may precede the terminal compact JSON
    // failure. Preserve the structured error instead of replacing it with a
    // generic failure whenever stderr contains more than one line.
    let decoder = JSONDecoder()
    let envelope = (try? decoder.decode(ErrorEnvelope.self, from: data))
      ?? data.split(separator: 0x0A).reversed().lazy.compactMap {
        try? decoder.decode(ErrorEnvelope.self, from: Data($0))
      }.first
    guard let envelope else {
      return nil
    }
    if let version = envelope.protocolVersion, version != protocolVersion {
      return invalidResponse("Inline CLI uses an unsupported agent setup protocol. Update it and try again.")
    }
    let retry = envelope.retry ?? targetID.map {
      "inline agents setup --target \($0) --non-interactive"
    }
    let code = safeCode(envelope.error.code)
    return AgentSetupFailure(
      code: code,
      message: safeStructuredText(envelope.error.message, maximumScalars: 1_000),
      hint: envelope.error.hint.map { safeStructuredText($0, maximumScalars: 1_000) },
      examples: (envelope.error.examples ?? []).prefix(3).map {
        safeStructuredText($0, maximumScalars: 500)
      },
      recoveryURL: envelope.documentationURL ?? documentationURL,
      status: envelope.status,
      failedPhase: envelope.failedPhase.map {
        safeStructuredText($0, maximumScalars: 100)
      },
      timedOut: envelope.timedOut ?? (code == "timeout"),
      completedChanges: (envelope.changes ?? []).prefix(20).map {
        safeStructuredText($0, maximumScalars: 100)
      },
      recoveryCommands: (envelope.recoveryCommands ?? []).prefix(5).map {
        safeStructuredText($0, maximumScalars: 500)
      },
      diagnosticReportPath: envelope.diagnosticReportPath.map {
        safeStructuredText($0, maximumScalars: 1_000)
      },
      retryCommand: retry.map { safeStructuredText($0, maximumScalars: 500) }
    )
  }

  private static func stop(_ process: Process?) {
    guard let process, process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }
  }

  static func stopAndWait(_ process: Process?) {
    guard let process else { return }
    stop(process)
    if process.isRunning {
      process.waitUntilExit()
    }
  }
}

final class AgentSetupProcessState: @unchecked Sendable {
  private let lock = NSLock()
  private var activeOperationID: UUID?
  private var cancellationRequested = false
  private var process: Process?

  func begin() -> UUID? {
    lock.withLock {
      guard activeOperationID == nil else { return nil }
      let operationID = UUID()
      activeOperationID = operationID
      cancellationRequested = false
      return operationID
    }
  }

  func launch(
    _ nextProcess: Process,
    operationID: UUID,
    start: () throws -> Void
  ) throws -> Bool {
    try lock.withLock {
      guard activeOperationID == operationID,
            !cancellationRequested,
            process == nil else { return false }
      process = nextProcess
      do {
        try start()
      } catch {
        process = nil
        throw error
      }
      return true
    }
  }

  func clear(_ completedProcess: Process) {
    lock.withLock {
      if process === completedProcess { process = nil }
    }
  }

  func requestCancellation() -> Process? {
    lock.withLock {
      guard activeOperationID != nil else { return nil }
      cancellationRequested = true
      return process
    }
  }

  func isCancellationRequested(_ operationID: UUID) -> Bool {
    lock.withLock {
      activeOperationID != operationID || cancellationRequested
    }
  }

  func finish(_ operationID: UUID) {
    lock.withLock {
      guard activeOperationID == operationID else { return }
      activeOperationID = nil
      cancellationRequested = false
      process = nil
    }
  }
}

private final class TimeoutState: @unchecked Sendable {
  private let lock = NSLock()
  private var timedOut = false

  var didTimeOut: Bool {
    lock.withLock { timedOut }
  }

  func markTimedOut() {
    lock.withLock { timedOut = true }
  }
}

private final class OutputCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  var value: Data {
    lock.withLock { data }
  }

  func store(_ data: Data) {
    lock.withLock { self.data = data }
  }
}

private final class OutputLineAccumulator: @unchecked Sendable {
  private let onLine: (@Sendable (Data) -> Void)?
  private var buffer = Data()

  init(onLine: (@Sendable (Data) -> Void)?) {
    self.onLine = onLine
  }

  func consume(_ chunk: Data) {
    guard onLine != nil else { return }
    buffer.append(chunk)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if !line.isEmpty { onLine?(line) }
    }
  }

  func finish() {
    guard !buffer.isEmpty else { return }
    onLine?(buffer)
    buffer.removeAll(keepingCapacity: false)
  }
}

private final class OutputLimitState: @unchecked Sendable {
  private let lock = NSLock()
  private var exceeded = false

  var didExceed: Bool {
    lock.withLock { exceeded }
  }

  func markExceeded() -> Bool {
    lock.withLock {
      guard !exceeded else { return false }
      exceeded = true
      return true
    }
  }
}
