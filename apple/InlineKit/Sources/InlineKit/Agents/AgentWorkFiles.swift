import Auth
import Foundation
import InlineProtocol

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
    peer: Peer,
    botUserID: Int64,
    agentSessionID: Int64,
    relativePath: String,
    query: String?,
    after: String?,
    limit: Int
  ) async throws -> AgentWorkFilePage
}

public enum AgentWorkFiles {
  /// The live listing, through `requestBotFilesystem` with LIST_WORK_FILES.
  @MainActor public static var listing: any AgentWorkFilesListing = BridgeListing()

  /// Text inserted into a draft for a file reference: a plain path, never a
  /// mention entity, because `@` in Inline means people and bots.
  public static func referenceText(for entry: AgentWorkFileEntry) -> String {
    let path = entry.isDirectory && !entry.relativePath.hasSuffix("/")
      ? entry.relativePath + "/"
      : entry.relativePath
    return path.contains(" ") ? "`\(path)`" : path
  }

  /// The bridge answers from the work's own folder; every path in and out is
  /// relative to it. Results are never cached or stored.
  struct BridgeListing: AgentWorkFilesListing {
    @MainActor
    func list(
      peer: Peer,
      botUserID: Int64,
      agentSessionID: Int64,
      relativePath: String,
      query: String?,
      after: String?,
      limit: Int
    ) async throws -> AgentWorkFilePage {
      guard let accountID = Auth.shared.getCurrentUserId() else { throw CancellationError() }
      let response = try await Api.realtime.callRpcDirect(
        method: .requestBotFilesystem,
        input: .requestBotFilesystem(.with {
          $0.peerID = peer.toInputPeer()
          // The server resolves the bot and its machine from the session.
          $0.botUserID = 0
          $0.hostInstallationID = ""
          $0.operation = .listWorkFiles
          $0.agentSessionID = agentSessionID
          $0.path = relativePath
          if let after { $0.after = after }
          if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty { $0.query = query }
          $0.limit = UInt32(min(max(limit, 1), 200))
        })
      )
      try Task.checkCancellation()
      guard Auth.shared.getCurrentUserId() == accountID else { throw CancellationError() }
      guard case let .requestBotFilesystem(result)? = response, result.hasResponse else {
        throw AgentWorkFilesError.unavailable
      }
      switch result.response.result {
      case let .listing(listing)?:
        return AgentWorkFilePage(
          entries: listing.entries.map {
            AgentWorkFileEntry(relativePath: $0.name, isDirectory: $0.kind == .directory)
          },
          nextAfter: listing.hasNextAfter ? listing.nextAfter : nil
        )
      case let .problem(problem)?:
        throw AgentWorkFilesError.problem(problem)
      case .workspaceID?, nil:
        throw AgentWorkFilesError.unavailable
      }
    }
  }
}
