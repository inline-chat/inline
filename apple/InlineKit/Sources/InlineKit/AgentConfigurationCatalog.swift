import Foundation
import GRDB
import InlineProtocol

public struct AgentConfigurationOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let description: String?
}

public struct AgentModelConfigurationOption: Identifiable, Equatable, Sendable {
  public let id: String
  public let label: String
  public let description: String?
  public let reasoningEffortIDs: [String]
}

public struct AgentConfigurationCatalogSnapshot: Equatable, Sendable {
  public let projects: [AgentConfigurationOption]?
  public let models: [AgentModelConfigurationOption]?
  public let reasoning: [AgentConfigurationOption]?
  public let canSelectFolder: Bool

  public init(protocolCatalog: InlineProtocol.AgentConfigurationCatalog) throws {
    projects = try Self.projectOptions(protocolCatalog.hasProjects ? protocolCatalog.projects.options : nil)
    reasoning = try Self.reasoningOptions(protocolCatalog.hasReasoning ? protocolCatalog.reasoning.options : nil)
    canSelectFolder = protocolCatalog.hasProjects
      && protocolCatalog.projects.hasCanSelectFolder
      && protocolCatalog.projects.canSelectFolder

    if protocolCatalog.hasModels {
      var ids = Set<String>()
      models = try protocolCatalog.models.options.map { option in
        let id = try Self.identifier(option.id)
        guard ids.insert(id).inserted else { throw AgentConfigurationCatalogError.invalidCatalog }
        let label = try Self.label(option.label)
        return AgentModelConfigurationOption(
          id: id,
          label: label,
          description: option.hasDescription_p ? Self.description(option.description_p) : nil,
          reasoningEffortIDs: option.reasoningEffortIds
        )
      }
    } else {
      models = nil
    }
  }

  private static func projectOptions(
    _ options: [InlineProtocol.AgentProjectOption]?
  ) throws -> [AgentConfigurationOption]? {
    guard let options else { return nil }
    var ids = Set<String>()
    return try options.map { option in
      let id = try identifier(option.id)
      guard ids.insert(id).inserted else { throw AgentConfigurationCatalogError.invalidCatalog }
      return try AgentConfigurationOption(
        id: id,
        label: label(option.label),
        description: option.hasDescription_p ? description(option.description_p) : nil
      )
    }
  }

  private static func reasoningOptions(
    _ options: [InlineProtocol.AgentReasoningEffortOption]?
  ) throws -> [AgentConfigurationOption]? {
    guard let options else { return nil }
    var ids = Set<String>()
    return try options.map { option in
      let id = try identifier(option.id)
      guard ids.insert(id).inserted else { throw AgentConfigurationCatalogError.invalidCatalog }
      return try AgentConfigurationOption(
        id: id,
        label: label(option.label),
        description: option.hasDescription_p ? description(option.description_p) : nil
      )
    }
  }

  private static func identifier(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 256 else {
      throw AgentConfigurationCatalogError.invalidCatalog
    }
    return value
  }

  private static func label(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 256 else {
      throw AgentConfigurationCatalogError.invalidCatalog
    }
    return value
  }

  private static func description(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : String(value.prefix(2_000))
  }
}

public enum AgentConfigurationCatalogError: Error {
  case invalidCatalog
  case invalidResponse
}

private struct StoredAgentConfigurationCatalog: Codable, FetchableRecord, PersistableRecord {
  static let databaseTableName = "agentConfigurationCatalog"

  let botUserId: Int64
  let payload: Data
  let fetchedAt: Date
}

/// Bot-keyed durable cache for provider-published typed Agent choices. The
/// cached value is always returned before refresh so Compose never waits on a
/// provider round trip to render its picker.
@MainActor
public final class AgentConfigurationCatalogStore {
  private struct RefreshResult {
    let catalog: InlineProtocol.AgentConfigurationCatalog?
    let snapshot: AgentConfigurationCatalogSnapshot?
  }

  public static let shared = AgentConfigurationCatalogStore()

  private let database: AppDatabase
  private var inFlight: [Int64: Task<RefreshResult, Error>] = [:]
  private var generation: UInt = 0

  public init(database: AppDatabase = .shared) {
    self.database = database
  }

  public func cached(botUserID: Int64) async -> AgentConfigurationCatalogSnapshot? {
    do {
      return try await database.dbWriter.read { db in
        guard let record = try StoredAgentConfigurationCatalog.fetchOne(db, key: botUserID),
              let protocolCatalog = try? InlineProtocol.AgentConfigurationCatalog(
                serializedBytes: record.payload
              )
        else { return nil }
        return try AgentConfigurationCatalogSnapshot(protocolCatalog: protocolCatalog)
      }
    } catch {
      return nil
    }
  }

  public func refresh(
    botUserID: Int64,
    peer: Peer? = nil
  ) async throws -> AgentConfigurationCatalogSnapshot? {
    if let task = inFlight[botUserID] {
      let requestGeneration = generation
      let snapshot = try await task.value.snapshot
      guard generation == requestGeneration, !Task.isCancelled else {
        throw CancellationError()
      }
      return snapshot
    }
    let requestGeneration = generation
    let task = Task<RefreshResult, Error> {
      let response = try await Api.realtime.callRpcDirect(
        method: .getBotConfigurationCatalog,
        input: .getBotConfigurationCatalog(.with {
          $0.botUserID = botUserID
          if let peer { $0.peerID = peer.toInputPeer() }
        })
      )
      guard case let .getBotConfigurationCatalog(result)? = response else {
        throw AgentConfigurationCatalogError.invalidResponse
      }
      guard result.hasCatalog else {
        return RefreshResult(catalog: nil, snapshot: nil)
      }
      let snapshot = try AgentConfigurationCatalogSnapshot(protocolCatalog: result.catalog)
      return RefreshResult(catalog: result.catalog, snapshot: snapshot)
    }
    inFlight[botUserID] = task
    defer { inFlight[botUserID] = nil }
    let result = try await task.value
    guard generation == requestGeneration, !Task.isCancelled else {
      throw CancellationError()
    }
    if let catalog = result.catalog {
      let payload = try catalog.serializedData()
      try await database.dbWriter.write { db in
        try StoredAgentConfigurationCatalog(
          botUserId: botUserID,
          payload: payload,
          fetchedAt: Date()
        ).save(db)
      }
    } else {
      try await database.dbWriter.write { db in
        _ = try StoredAgentConfigurationCatalog.deleteOne(db, key: botUserID)
      }
    }
    guard generation == requestGeneration else { throw CancellationError() }
    return result.snapshot
  }

  public func clear() async {
    generation &+= 1
    inFlight.values.forEach { $0.cancel() }
    inFlight.removeAll()
    try? await database.dbWriter.write { db in
      _ = try StoredAgentConfigurationCatalog.deleteAll(db)
    }
  }
}
