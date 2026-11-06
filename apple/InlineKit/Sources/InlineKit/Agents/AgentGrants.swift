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
    case .configure: return operations.contains(.configure)
    case .UNRECOGNIZED: return false
    }
  }
}

/// Everyone with access to a bot the viewer owns. The server lists other
/// people's grants only to the bot's owner and the bot itself, so this exists
/// only for the viewer's own bots.
public struct OwnedAgentGrants: Equatable, Sendable {
  public let botUserID: Int64
  /// Highest grant revision reflected here.
  public private(set) var revision: Int64
  /// Operations per person with an active grant.
  public private(set) var operationsByUserID: [Int64: Set<InlineProtocol.AgentGrantOperation>]
  /// Everything at or below this revision is already in the snapshot.
  private let snapshotRevision: Int64
  /// Last change per person, deletions included, so stale updates never win.
  private var revisionByUserID: [Int64: Int64]

  public init(_ result: InlineProtocol.ListAgentGrantsResult, botUserID: Int64) {
    self.botUserID = botUserID
    var operations: [Int64: Set<InlineProtocol.AgentGrantOperation>] = [:]
    var revisions: [Int64: Int64] = [:]
    for grant in result.grants where grant.botUserID == botUserID {
      let ops = Set(grant.operations).subtracting([.unspecified])
      guard !ops.isEmpty else { continue }
      operations[grant.userID] = ops
      revisions[grant.userID] = grant.revision
    }
    operationsByUserID = operations
    revisionByUserID = revisions
    snapshotRevision = result.revision
    revision = max(result.revision, revisions.values.max() ?? 0)
  }

  public var userIDs: Set<Int64> { Set(operationsByUserID.keys) }

  public func hasGrant(userID: Int64) -> Bool {
    operationsByUserID[userID] != nil
  }

  /// Applies one person's grant change; empty operations remove the grant.
  /// Returns false when the change is not newer than what is already here.
  @discardableResult
  public mutating func apply(
    userID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64
  ) -> Bool {
    guard revision > snapshotRevision, revision > (revisionByUserID[userID] ?? 0) else { return false }
    revisionByUserID[userID] = revision
    let ops = operations.subtracting([.unspecified])
    operationsByUserID[userID] = ops.isEmpty ? nil : ops
    self.revision = max(self.revision, revision)
    return true
  }

  /// The viewer's bots among a chat's participants, in participant order.
  public static func ownedBotIDs(
    among participantBotIDs: [Int64],
    owned: [Int64: OwnedAgentGrants]
  ) -> [Int64] {
    var seen: Set<Int64> = []
    return participantBotIDs.filter { owned[$0] != nil && seen.insert($0).inserted }
  }

  /// Keeps the chosen bot while it is still eligible; otherwise the first one.
  public static func selectedBotID(preferred: Int64?, among botIDs: [Int64]) -> Int64? {
    if let preferred, botIDs.contains(preferred) { return preferred }
    return botIDs.first
  }
}

/// Operations an owner gives someone from the access list: start and steer
/// work, as the bridge's /allowlist does.
public extension Set where Element == InlineProtocol.AgentGrantOperation {
  static let agentAllowlistDefault: Self = [.invoke, .steer]
}

/// Viewer grants per bot, for disabling actions the viewer cannot use. The
/// server stays authoritative and rejects unauthorized invocations; an
/// unknown grant set therefore renders enabled rather than guessing.
@MainActor
public final class AgentGrantStore: ObservableObject {
  public static let shared = AgentGrantStore()

  @Published public private(set) var accessByBotUserID: [Int64: AgentGrantAccess] = [:]
  /// Full access lists, only for bots the viewer owns.
  @Published public private(set) var ownedGrantsByBotUserID: [Int64: OwnedAgentGrants] = [:]

  private let log = Log.scoped("AgentGrantStore")
  private var inFlight: Set<Int64> = []
  private var failedAt: [Int64: Date] = [:]
  /// Bumped by `removeAll` (logout, reset) so a load started for another
  /// account or before the reset never lands.
  private var generation: UInt64 = 0

  public init() {}

  public func access(botUserID: Int64) -> AgentGrantAccess? {
    accessByBotUserID[botUserID]
  }

  public func ownedGrants(botUserID: Int64) -> OwnedAgentGrants? {
    ownedGrantsByBotUserID[botUserID]
  }

  /// Loads the viewer's grants for a bot once, unless a load failed recently.
  public func ensureLoaded(botUserID: Int64) {
    guard accessByBotUserID[botUserID] == nil else { return }
    if let failedAt = failedAt[botUserID], Date().timeIntervalSince(failedAt) < 60 { return }
    load(botUserID: botUserID)
  }

  /// Reloads even when cached; the cached value stays visible meanwhile.
  public func refresh(botUserID: Int64) {
    load(botUserID: botUserID)
  }

  private func load(botUserID: Int64) {
    guard botUserID > 0, !inFlight.contains(botUserID),
          let accountID = Auth.shared.getCurrentUserId()
    else { return }
    inFlight.insert(botUserID)
    let generation = generation
    Task { @MainActor [weak self] in
      defer { if self?.generation == generation { self?.inFlight.remove(botUserID) } }
      do {
        let response = try await Api.realtime.callRpcDirect(
          method: .listAgentGrants,
          input: .listAgentGrants(.with { $0.botUserID = botUserID })
        )
        guard let self, self.generation == generation, Auth.shared.getCurrentUserId() == accountID,
              case let .listAgentGrants(result)? = response
        else { return }
        self.apply(result, botUserID: botUserID, viewerUserID: accountID)
      } catch {
        guard let self, self.generation == generation else { return }
        self.failedAt[botUserID] = Date()
        self.log.debug("Couldn't load grants for bot \(botUserID): \(error)")
      }
    }
  }

  /// Gives one person access to a bot the viewer owns, or changes it.
  public func setGrant(
    botUserID: Int64,
    userID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation> = .agentAllowlistDefault
  ) async throws {
    let generation = generation
    let response = try await Api.realtime.callRpcDirect(
      method: .setAgentGrant,
      input: .setAgentGrant(.with {
        $0.botUserID = botUserID
        $0.userID = userID
        $0.operations = Array(operations).sorted { $0.rawValue < $1.rawValue }
      })
    )
    guard self.generation == generation, case let .setAgentGrant(result)? = response else { return }
    applyOwned(
      botUserID: botUserID,
      userID: userID,
      operations: Set(result.grant.operations),
      revision: result.grant.revision
    )
  }

  /// Removes one person's access to a bot the viewer owns.
  public func deleteGrant(botUserID: Int64, userID: Int64) async throws {
    let generation = generation
    let response = try await Api.realtime.callRpcDirect(
      method: .deleteAgentGrant,
      input: .deleteAgentGrant(.with {
        $0.botUserID = botUserID
        $0.userID = userID
      })
    )
    guard self.generation == generation, case let .deleteAgentGrant(result)? = response else { return }
    applyOwned(botUserID: botUserID, userID: userID, operations: [], revision: result.revision)
  }

  public func apply(_ result: InlineProtocol.ListAgentGrantsResult, botUserID: Int64, viewerUserID: Int64) {
    if result.ownerUserID == viewerUserID {
      let owned = OwnedAgentGrants(result, botUserID: botUserID)
      if let current = ownedGrantsByBotUserID[botUserID], current.revision > owned.revision {
        // A newer local edit or update already landed.
      } else if ownedGrantsByBotUserID[botUserID] != owned {
        ownedGrantsByBotUserID[botUserID] = owned
      }
    } else if ownedGrantsByBotUserID[botUserID] != nil {
      ownedGrantsByBotUserID[botUserID] = nil
    }
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
    guard let viewerUserID = Auth.shared.getCurrentUserId() else { return }
    apply(update, viewerUserID: viewerUserID)
  }

  func apply(_ update: InlineProtocol.UpdateAgentGrant, viewerUserID: Int64) {
    // Owners receive every grant change on their bots.
    applyOwned(
      botUserID: update.botUserID,
      userID: update.userID,
      operations: update.hasGrant ? Set(update.grant.operations) : [],
      revision: update.revision
    )
    guard update.userID == viewerUserID,
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
    generation &+= 1
    accessByBotUserID.removeAll()
    ownedGrantsByBotUserID.removeAll()
    failedAt.removeAll()
    inFlight.removeAll()
  }

  private func applyOwned(
    botUserID: Int64,
    userID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64
  ) {
    guard var owned = ownedGrantsByBotUserID[botUserID],
          owned.apply(userID: userID, operations: operations, revision: revision)
    else { return }
    ownedGrantsByBotUserID[botUserID] = owned
  }

  private func store(_ access: AgentGrantAccess) {
    if let current = accessByBotUserID[access.botUserID], current.revision > access.revision { return }
    guard accessByBotUserID[access.botUserID] != access else { return }
    accessByBotUserID[access.botUserID] = access
  }
}
