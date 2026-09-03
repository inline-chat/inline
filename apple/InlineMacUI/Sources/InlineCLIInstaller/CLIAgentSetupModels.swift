import Foundation

public enum AgentHarnessFamily: String, Codable, Sendable {
  case gateway
  case bridge
}

public struct AgentHarnessTarget: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let family: AgentHarnessFamily
  public let installed: Bool

  public init(
    id: String,
    displayName: String,
    family: AgentHarnessFamily,
    installed: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.family = family
    self.installed = installed
  }
}

public struct AgentHarnessDiscovery: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let action: String
  public let documentationURL: URL
  public let targets: [AgentHarnessTarget]

  public init(
    protocolVersion: Int,
    action: String,
    documentationURL: URL,
    targets: [AgentHarnessTarget]
  ) {
    self.protocolVersion = protocolVersion
    self.action = action
    self.documentationURL = documentationURL
    self.targets = targets
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case action
    case documentationURL = "documentationUrl"
    case targets
  }
}

public struct AgentSetupResult: Codable, Equatable, Sendable {
  public struct Bot: Codable, Equatable, Sendable {
    public let id: Int64
    public let username: String
    public let name: String
  }

  public struct Service: Codable, Equatable, Sendable {
    public let kind: String
    public let action: String
    public let ready: Bool
    public let status: String?
  }

  public struct Readiness: Codable, Equatable, Sendable {
    public let ready: Bool
    public let code: String?
    public let message: String?
    public let command: String?
    public let verified: Bool?
  }

  public let protocolVersion: Int
  public let ok: Bool
  public let action: String
  public let status: String
  public let documentationURL: URL
  public let openURL: URL
  public let target: String
  public let family: AgentHarnessFamily
  public let instance: String
  public let bot: Bot
  public let service: Service
  public let readiness: Readiness?

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case ok
    case action
    case status
    case documentationURL = "documentationUrl"
    case openURL = "openUrl"
    case target
    case family
    case instance
    case bot
    case service
    case readiness
  }
}

public struct AgentSetupProgressEvent: Codable, Equatable, Sendable {
  public enum Event: String, Codable, Sendable {
    case phaseStarted = "phase.started"
    case phaseCompleted = "phase.completed"
  }

  public enum Phase: String, Codable, Sendable {
    case preflight
    case bot
    case integration
    case access
    case service
    case verification
    case configuration
  }

  public let protocolVersion: Int
  public let event: Event
  public let phase: Phase
  public let outcome: String?
  public let message: String?
  public let timeoutSeconds: Int?

  public init(
    protocolVersion: Int,
    event: Event,
    phase: Phase,
    outcome: String? = nil,
    message: String? = nil,
    timeoutSeconds: Int? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.event = event
    self.phase = phase
    self.outcome = outcome
    self.message = message
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct AgentSetupFailure: LocalizedError, Equatable, Sendable {
  public let code: String
  public let message: String
  public let hint: String?
  public let examples: [String]
  public let recoveryURL: URL
  public let status: String?
  public let failedPhase: String?
  public let timedOut: Bool
  public let completedChanges: [String]
  public let recoveryCommands: [String]
  public let diagnosticReportPath: String?
  public let retryCommand: String?

  public init(
    code: String,
    message: String,
    hint: String? = nil,
    examples: [String] = [],
    recoveryURL: URL,
    status: String? = nil,
    failedPhase: String? = nil,
    timedOut: Bool = false,
    completedChanges: [String] = [],
    recoveryCommands: [String] = [],
    diagnosticReportPath: String? = nil,
    retryCommand: String? = nil
  ) {
    self.code = code
    self.message = message
    self.hint = hint
    self.examples = examples
    self.recoveryURL = recoveryURL
    self.status = status
    self.failedPhase = failedPhase
    self.timedOut = timedOut
    self.completedChanges = completedChanges
    self.recoveryCommands = recoveryCommands
    self.diagnosticReportPath = diagnosticReportPath
    self.retryCommand = retryCommand
  }

  public var errorDescription: String? { message }

  public var recoverySuggestion: String? {
    let suggestions = [hint].compactMap { $0 }
      + recoveryCommands
      + [retryCommand, examples.first].compactMap { $0 }
    return suggestions.isEmpty ? nil : suggestions.joined(separator: "\n")
  }

  public var isPartial: Bool {
    status == "partial" || !completedChanges.isEmpty
  }

  public var supportsConfirmedReplacement: Bool {
    code == "setup_conflict" || code == "mapped_bot_missing"
  }
}

public protocol AgentSetupCLIRunning: Sendable {
  func discover(installation: CLIInstallation) async throws -> AgentHarnessDiscovery
  func setup(
    target: AgentHarnessTarget,
    installation: CLIInstallation,
    replaceExisting: Bool,
    progress: @escaping @Sendable (AgentSetupProgressEvent) -> Void
  ) async throws -> AgentSetupResult
  func cancel()
  func cancelAndWait()
}
