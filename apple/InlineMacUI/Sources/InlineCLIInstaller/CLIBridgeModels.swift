import Foundation

/// One configured agent as reported by `inline bridge status --json`.
public struct CLIBridgeStatus: Decodable, Sendable, Equatable, Identifiable {
  public let status: String
  public let installed: Bool
  public let healthy: Bool
  public let provider: String
  public let displayName: String?
  public let botUsername: String?
  public let processId: UInt32?
  public let inlineConnected: Bool
  public let providerReady: Bool
  public let detail: String?

  public var id: String { provider }

  public init(
    status: String,
    installed: Bool = true,
    healthy: Bool,
    provider: String,
    displayName: String? = nil,
    botUsername: String? = nil,
    processId: UInt32? = nil,
    inlineConnected: Bool = false,
    providerReady: Bool = false,
    detail: String? = nil
  ) {
    self.status = status
    self.installed = installed
    self.healthy = healthy
    self.provider = provider
    self.displayName = displayName
    self.botUsername = botUsername
    self.processId = processId
    self.inlineConnected = inlineConnected
    self.providerReady = providerReady
    self.detail = detail
  }
}

public enum CLIBridgeCommand: Sendable, Equatable {
  case status
  case start
  case stop
  case restart

  var arguments: [String] {
    switch self {
    case .status: ["bridge", "status", "--json"]
    case .start: ["bridge", "start", "--json"]
    case .stop: ["bridge", "stop", "--json"]
    case .restart: ["bridge", "restart", "--json"]
    }
  }

  /// Start and restart wait up to 90 seconds for every agent to become ready.
  var timeout: TimeInterval {
    switch self {
    case .status: 30
    case .stop: 60
    case .start, .restart: 150
    }
  }
}

struct CLIBridgeLogs: Decodable {
  let lines: [String]
}

extension CLIBridgeStatus {
  /// `bridge status` prints a list, or a single object when no bridge is installed.
  static func parseList(_ data: Data) -> [CLIBridgeStatus]? {
    let decoder = JSONDecoder()
    if let list = try? decoder.decode([CLIBridgeStatus].self, from: data) { return list }
    if let single = try? decoder.decode(CLIBridgeStatus.self, from: data) { return [single] }
    return nil
  }
}
