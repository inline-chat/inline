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
  }
}

public struct AgentSetupFailure: LocalizedError, Equatable, Sendable {
  public let code: String
  public let message: String
  public let hint: String?
  public let examples: [String]
  public let recoveryURL: URL

  public init(
    code: String,
    message: String,
    hint: String? = nil,
    examples: [String] = [],
    recoveryURL: URL
  ) {
    self.code = code
    self.message = message
    self.hint = hint
    self.examples = examples
    self.recoveryURL = recoveryURL
  }

  public var errorDescription: String? { message }

  public var recoverySuggestion: String? {
    let parts = [hint, examples.first].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }
}

public protocol AgentSetupCLIRunning: Sendable {
  func discover(installation: CLIInstallation) async throws -> AgentHarnessDiscovery
  func setup(
    target: AgentHarnessTarget,
    installation: CLIInstallation
  ) async throws -> AgentSetupResult
  func cancel()
}
