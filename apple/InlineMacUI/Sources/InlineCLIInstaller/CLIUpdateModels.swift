import Foundation

public struct CLIUpdateStatus: Decodable, Sendable, Equatable {
  public struct Artifact: Decodable, Sendable, Equatable { public let version: String }
  public struct Bridge: Decodable, Sendable, Equatable {
    public let version: String?
    public let candidateVersion: String?
    public let phase: String
  }
  public let schemaVersion: Int
  public let autoUpdate: Bool
  public let channel: String
  public let followsApp: Bool
  public let currentVersion: String
  public let installationMethod: String
  public let automaticUpdatesAvailable: Bool
  public let outcome: String
  public let failure: String?
  public let staged: Artifact?
  public let retryAt: Int64?
  public let bridges: [Bridge]?
}

public enum CLIUpdateOperation: Sendable {
  case status
  case configure(enabled: Bool?, appChannel: CLIUpdateChannel, register: Bool)
  case background
  case followApp(CLIUpdateChannel)
  case apply

  var arguments: [String] {
    switch self {
    case .status: ["update", "status", "--json"]
    case let .configure(enabled, appChannel, register):
      ["update", "config", "--app-channel", appChannel.rawValue, "--json"]
        + (enabled.map { ["--auto", $0 ? "on" : "off"] } ?? [])
        + (register ? ["--register"] : [])
    case .background: ["update", "--background", "--json"]
    case let .followApp(channel): ["update", "config", "--follow-app", "--app-channel", channel.rawValue, "--json"]
    case .apply: ["update", "--json"]
    }
  }
}

public enum CLIUpdateFailure: Error, Sendable, Equatable {
  case unsupportedEngine
}

public struct CLIUpdateCheck: Decodable, Sendable {
  public let latestVersion: String
  public let updateAvailable: Bool
  public let supported: Bool
  enum CodingKeys: String, CodingKey {
    case latestVersion = "latest_version"
    case updateAvailable = "update_available"
    case supported
  }
}
