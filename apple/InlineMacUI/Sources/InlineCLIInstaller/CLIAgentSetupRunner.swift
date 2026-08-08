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

    let error: Payload
  }

  private static let protocolVersion = 1
  private static let maximumOutputBytes = 512 * 1_024
  private static let discoveryTimeout: TimeInterval = 20
  private static let setupTimeout: TimeInterval = 10 * 60
  private static let documentationURL = URL(string: "https://inline.chat/docs/agents")!

  private let configuration: CLIInstallerConfiguration
  private let lock = NSLock()
  private var operation: BoundedSubprocessOperation?

  public init(configuration: CLIInstallerConfiguration = .production) {
    self.configuration = configuration
  }

  public func discover(installation: CLIInstallation) async throws -> AgentHarnessDiscovery {
    let output = try await execute(
      installation: installation,
      arguments: ["--json", "--compact", "agents", "discover"],
      timeout: Self.discoveryTimeout
    )
    guard output.status == 0 else { throw failure(from: output) }
    return try Self.parseDiscovery(output.standardOutput)
  }

  public func setup(
    target: AgentHarnessTarget,
    installation: CLIInstallation
  ) async throws -> AgentSetupResult {
    guard target.installed, Self.isValidTargetID(target.id) else {
      throw AgentSetupFailure(
        code: "invalid_target",
        message: "The selected agent harness is not a valid installed target.",
        recoveryURL: Self.documentationURL
      )
    }

    let output = try await execute(
      installation: installation,
      arguments: [
        "--json",
        "--compact",
        "agents",
        "setup",
        "--target",
        target.id,
        "--non-interactive",
      ],
      timeout: Self.setupTimeout
    )
    guard output.status == 0 else { throw failure(from: output) }
    let result = try Self.parseSetup(output.standardOutput)
    guard result.target == target.id else {
      throw AgentSetupFailure(
        code: "unexpected_target",
        message: "Inline CLI configured a different harness than the one selected.",
        recoveryURL: Self.documentationURL
      )
    }
    return result
  }

  public func cancel() {
    lock.withLock { operation }?.cancel()
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
    let result: AgentSetupResult
    do {
      result = try JSONDecoder().decode(AgentSetupResult.self, from: data)
    } catch {
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

  private func execute(
    installation: CLIInstallation,
    arguments: [String],
    timeout: TimeInterval
  ) async throws -> CommandOutput {
    let nextOperation = BoundedSubprocessOperation()
    let registered = lock.withLock { () -> Bool in
      guard operation == nil else { return false }
      operation = nextOperation
      return true
    }
    guard registered else {
      throw AgentSetupFailure(
        code: "operation_in_progress",
        message: "Another Inline agent setup operation is already running.",
        recoveryURL: Self.documentationURL
      )
    }
    defer {
      lock.withLock {
        if operation === nextOperation { operation = nil }
      }
    }

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      let output = try await Task.detached(priority: .userInitiated) { [self] in
        try run(
          installation: installation,
          arguments: arguments,
          timeout: timeout,
          operation: nextOperation
        )
      }.value
      try Task.checkCancellation()
      return output
    } onCancel: {
      nextOperation.cancel()
    }
  }

  private func run(
    installation: CLIInstallation,
    arguments: [String],
    timeout: TimeInterval,
    operation: BoundedSubprocessOperation
  ) throws -> CommandOutput {
    if operation.requestedStopReason != nil { throw CancellationError() }
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

    do {
      let output = try BoundedSubprocess.run(
        executableURL: installation.executableURL,
        arguments: arguments,
        environment: Self.sanitizedEnvironment(ProcessInfo.processInfo.environment),
        timeout: timeout,
        maximumOutputBytes: Self.maximumOutputBytes,
        operation: operation
      )
      return CommandOutput(
        status: output.status,
        standardOutput: output.standardOutput,
        standardError: output.standardError
      )
    } catch let failure as BoundedSubprocessFailure {
      switch failure {
      case .cancelled:
        throw CancellationError()
      case .timedOut:
        throw AgentSetupFailure(
          code: "setup_timed_out",
          message: "Inline CLI did not finish agent setup in time.",
          hint: "Rerun `inline agents setup --target <name>` in Terminal to continue debugging.",
          recoveryURL: Self.documentationURL
        )
      case .launchFailed, .waitFailed:
        throw AgentSetupFailure(
          code: "cli_launch_failed",
          message: "Inline could not launch the installed CLI.",
          recoveryURL: Self.documentationURL
        )
      }
    }
  }

  private func failure(from output: CommandOutput) -> AgentSetupFailure {
    if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: output.standardError) {
      return AgentSetupFailure(
        code: envelope.error.code,
        message: envelope.error.message,
        hint: envelope.error.hint,
        examples: envelope.error.examples ?? [],
        recoveryURL: Self.documentationURL
      )
    }
    let detail = Self.safeDetail(output.standardError)
    return AgentSetupFailure(
      code: "agent_setup_failed",
      message: detail ?? "Inline CLI could not finish agent setup.",
      hint: "Run the same setup with Inline CLI in Terminal for detailed diagnostics.",
      recoveryURL: Self.documentationURL
    )
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
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let standardPaths = [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "\(home)/.local/bin",
      "\(home)/.bun/bin",
      "\(home)/.local/share/pnpm",
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

  static func safeDetail(_ data: Data) -> String? {
    let text = (String(data: data, encoding: .utf8) ?? "")
      .unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) }
      .prefix(1_000)
    let detail = String(String.UnicodeScalarView(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? nil : detail
  }
}
