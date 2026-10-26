import Auth
import Combine
import Foundation
import InlineProtocol
import Logger

/// What the current viewer may do on one bot. The owner always qualifies.
public struct AgentGrantAccess: Equatable, Sendable {
  public let botUserID: Int64
  public let ownerUserID: Int64
  public let viewerUserID: Int64
  public let operations: Set<InlineProtocol.AgentGrantOperation>
  public let revision: Int64

  public init(
    botUserID: Int64,
    ownerUserID: Int64,
    viewerUserID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64
  ) {
    self.botUserID = botUserID
    self.ownerUserID = ownerUserID
    self.viewerUserID = viewerUserID
    self.operations = operations
    self.revision = revision
  }

  public var isOwner: Bool { ownerUserID != 0 && viewerUserID == ownerUserID }

  public func satisfies(_ requirement: InlineProtocol.AgentGrantRequirement) -> Bool {
    if isOwner { return true }
    switch requirement {
    case .none: return true
    case .owner: return false
    // Any grant lets its holder answer the agent's questions.
    case .access: return !operations.subtracting([.unspecified]).isEmpty
    case .invoke: return operations.contains(.invoke)
    case .steer: return operations.contains(.steer)
    case .approve: return operations.contains(.approve)
    case .view: return operations.contains(.view)
    case .configure: return operations.contains(.configure)
    case .UNRECOGNIZED: return false
    }
  }
}

/// Viewer grants per bot, for disabling actions the viewer cannot use. The
/// server stays authoritative and rejects unauthorized invocations; an
/// unknown grant set therefore renders enabled rather than guessing.
@MainActor
public final class AgentGrantStore: ObservableObject {
  public static let shared = AgentGrantStore()

  @Published public private(set) var accessByBotUserID: [Int64: AgentGrantAccess] = [:]

  private let log = Log.scoped("AgentGrantStore")
  private var inFlight: Set<Int64> = []
  private var failedAt: [Int64: Date] = [:]

  public init() {}

  public func access(botUserID: Int64) -> AgentGrantAccess? {
    accessByBotUserID[botUserID]
  }

  /// Loads the viewer's grants for a bot once, unless a load failed recently.
  public func ensureLoaded(botUserID: Int64) {
    guard botUserID > 0, accessByBotUserID[botUserID] == nil, !inFlight.contains(botUserID) else { return }
    if let failedAt = failedAt[botUserID], Date().timeIntervalSince(failedAt) < 60 { return }
    inFlight.insert(botUserID)
    Task { @MainActor [weak self] in
      defer { self?.inFlight.remove(botUserID) }
      do {
        let response = try await Api.realtime.callRpcDirect(
          method: .listAgentGrants,
          input: .listAgentGrants(.with { $0.botUserID = botUserID })
        )
        guard case let .listAgentGrants(result)? = response else { return }
        self?.apply(result, botUserID: botUserID)
      } catch {
        self?.failedAt[botUserID] = Date()
        self?.log.debug("Couldn't load grants for bot \(botUserID): \(error)")
      }
    }
  }

  public func apply(_ result: InlineProtocol.ListAgentGrantsResult, botUserID: Int64) {
    guard let viewerUserID = Auth.shared.getCurrentUserId() else { return }
    let own = result.grants.first { $0.userID == viewerUserID && $0.botUserID == botUserID }
    store(.init(
      botUserID: botUserID,
      ownerUserID: result.ownerUserID,
      viewerUserID: viewerUserID,
      operations: Set(own?.operations ?? []),
      revision: result.revision
    ))
  }

  public func apply(_ update: InlineProtocol.UpdateAgentGrant) {
    guard let viewerUserID = Auth.shared.getCurrentUserId(),
          update.userID == viewerUserID,
          let current = accessByBotUserID[update.botUserID]
    else {
      // Without the owner id this viewer has no cached access to amend.
      return
    }
    guard update.revision >= current.revision else { return }
    store(.init(
      botUserID: update.botUserID,
      ownerUserID: current.ownerUserID,
      viewerUserID: viewerUserID,
      operations: update.hasGrant ? Set(update.grant.operations) : [],
      revision: update.revision
    ))
  }

  public func removeAll() {
    accessByBotUserID.removeAll()
    failedAt.removeAll()
  }

  private func store(_ access: AgentGrantAccess) {
    if let current = accessByBotUserID[access.botUserID], current.revision > access.revision { return }
    guard accessByBotUserID[access.botUserID] != access else { return }
    accessByBotUserID[access.botUserID] = access
  }
}
