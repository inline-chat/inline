import Foundation

/// One entry in an agent work's folder (spec §15.4). Paths are relative to
/// the work's folder; the app never learns the absolute location.
public struct AgentWorkFileEntry: Identifiable, Equatable, Sendable {
  public var id: String { relativePath }
  public let relativePath: String
  public let isDirectory: Bool

  public init(relativePath: String, isDirectory: Bool) {
    self.relativePath = relativePath
    self.isDirectory = isDirectory
  }

  public var name: String {
    relativePath.split(separator: "/").last.map(String.init) ?? relativePath
  }
}

public struct AgentWorkFilePage: Equatable, Sendable {
  public let entries: [AgentWorkFileEntry]
  public let nextAfter: String?

  public init(entries: [AgentWorkFileEntry], nextAfter: String?) {
    self.entries = entries
    self.nextAfter = nextAfter
  }
}

public enum AgentWorkFilesError: Error, Equatable {
  /// The server or bridge doesn't offer work-folder listings yet.
  case unavailable
  /// A short, safe message from the bridge.
  case problem(String)
}

/// Lists files in a work's folder through the bridge, for the composer's file
/// references. Owner or an INVOKE grantee; results are never cached or stored.
public protocol AgentWorkFilesListing: Sendable {
  func list(
    agentSessionID: Int64,
    relativePath: String,
    query: String?,
    after: String?,
    limit: Int
  ) async throws -> AgentWorkFilePage
}

public enum AgentWorkFiles {
  /// The live listing. `LIST_WORK_FILES` (W3) replaces this stub with the
  /// `requestBotFilesystem` call once its generated types land.
  @MainActor public static var listing: any AgentWorkFilesListing = UnavailableListing()

  /// Text inserted into a draft for a file reference: a plain path, never a
  /// mention entity, because `@` in Inline means people and bots.
  public static func referenceText(for entry: AgentWorkFileEntry) -> String {
    let path = entry.isDirectory && !entry.relativePath.hasSuffix("/")
      ? entry.relativePath + "/"
      : entry.relativePath
    return path.contains(" ") ? "`\(path)`" : path
  }

  struct UnavailableListing: AgentWorkFilesListing {
    func list(
      agentSessionID _: Int64,
      relativePath _: String,
      query _: String?,
      after _: String?,
      limit _: Int
    ) async throws -> AgentWorkFilePage {
      throw AgentWorkFilesError.unavailable
    }
  }
}
