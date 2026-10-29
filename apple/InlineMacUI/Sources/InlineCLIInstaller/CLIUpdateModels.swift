import Foundation

public struct CLIUpdateStatus: Decodable, Sendable, Equatable {
  public struct Artifact: Decodable, Sendable, Equatable { public let version: String }
  public struct Bridge: Decodable, Sendable, Equatable {
    public let version: String?
    public let candidateVersion: String?
    public let phase: String
  }
  public let schemaVersion: Int
  public let revision: UInt64?
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

/// Orders short policy writes while downloads remain free to observe an opt-out.
@MainActor
public final class CLIUpdateCoordinator {
  private var policy: Task<CLIUpdateStatus, Error>?
  private var sequence: UInt64 = 0
  private var observedRevision: UInt64?

  public init() {}

  public func run(
    _ operation: CLIUpdateOperation,
    execute: @escaping @MainActor @Sendable () async throws -> CLIUpdateStatus
  ) async throws -> CLIUpdateStatus {
    switch operation {
    case .configure, .followApp:
      let previous = policy
      sequence &+= 1
      let current = sequence
      let task = Task {
        _ = try? await previous?.value
        return try await execute()
      }
      policy = task
      defer { if sequence == current { policy = nil } }
      return try await task.value
    case .status, .background, .apply:
      return try await execute()
    }
  }

  /// A delayed status response must not replace a newer confirmed preference.
  public func accepts(_ status: CLIUpdateStatus) -> Bool {
    guard let revision = status.revision else { return observedRevision == nil }
    if let observedRevision, revision < observedRevision { return false }
    observedRevision = revision
    return true
  }
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
