import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger
import RealtimeV2

/// What the current viewer may do on one bot. The owner always qualifies.
public struct AgentGrantAccess: Equatable, Sendable {
  public let botUserID: Int64
  public let ownerUserID: Int64
  public let viewerUserID: Int64
  public let operations: Set<InlineProtocol.AgentGrantOperation>
  public let revision: Int64
  /// The server's answer to "can the viewer message this bot". Nil when only
  /// the access list was read, which says nothing about a bot open to everyone.
  public let resolvedCanMessage: Bool?
  /// The bot wrote to the viewer in their DM recently, so they can answer it
  /// there even without access.
  public let canReply: Bool

  public init(
    botUserID: Int64,
    ownerUserID: Int64,
    viewerUserID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64,
    canMessage: Bool? = nil,
    canReply: Bool = false
  ) {
    self.botUserID = botUserID
    self.ownerUserID = ownerUserID
    self.viewerUserID = viewerUserID
    self.operations = operations
    self.revision = revision
    resolvedCanMessage = canMessage
    self.canReply = canReply
  }

  /// The server said the viewer can't message this bot, and the bot hasn't
  /// written to them lately: its chat has no composer. Unknown is never this.
  public var isUnreachable: Bool { canMessage == false && !canReply }

  public var isOwner: Bool { ownerUserID != 0 && viewerUserID == ownerUserID }

  /// The owner, or an admin the owner appointed: they manage who can message
  /// the bot, its profile, settings and token. Only the owner deletes it.
  public var canManage: Bool { isOwner || operations.contains(.configure) }

  /// Whether the viewer can message the bot, add it to chats and mention it.
  /// Nil while unknown: surfaces that offer a bot leave it out, and nothing
  /// that already exists (a chat, its composer) is taken away.
  public var canMessage: Bool? {
    if isOwner || satisfies(.access) { return true }
    return resolvedCanMessage
  }

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

/// What someone on a bot's access list is to it.
public enum BotAccessRole: String, CaseIterable, Sendable {
  /// Can message the bot and steer its work.
  case member
  /// Manages the bot with its owner.
  case admin

  public var title: String {
    switch self {
    case .member: String(localized: "Can Use")
    case .admin: String(localized: "Admin")
    }
  }

  var operations: Set<InlineProtocol.AgentGrantOperation> {
    switch self {
    case .member: .agentAllowlistDefault
    case .admin: [.invoke, .steer, .configure]
    }
  }
}

/// Who an access list entry is for. A space or a group means its current members.
public enum AgentGrantSubject: Hashable, Sendable {
  case user(Int64)
  case space(Int64)
  case group(Int64)

  /// Nil for a subject kind this build doesn't know.
  init?(subject: InlineProtocol.AccessSubject?, userID: Int64) {
    switch subject?.subject {
    case let .userID(id)? where id > 0: self = .user(id)
    case let .spaceID(id)? where id > 0: self = .space(id)
    case let .groupID(id)? where id > 0: self = .group(id)
    case .none where userID > 0: self = .user(userID)
    default: return nil
    }
  }

  var accessSubject: InlineProtocol.AccessSubject {
    .with {
      switch self {
      case let .user(id): $0.userID = id
      case let .space(id): $0.spaceID = id
      case let .group(id): $0.groupID = id
      }
    }
  }
}

/// Everyone with access to a bot the viewer manages. The server lists other
/// people's grants only to the bot's owner, its admins and the bot itself, so
/// this exists only for bots the viewer owns or is an admin of.
public struct OwnedAgentGrants: Equatable, Sendable {
  public let botUserID: Int64
  /// Highest grant revision reflected here.
  public private(set) var revision: Int64
  /// Operations per person, space or group with an active grant.
  public private(set) var operationsBySubject: [AgentGrantSubject: Set<InlineProtocol.AgentGrantOperation>]
  /// Everything at or below this revision is already in the snapshot.
  private let snapshotRevision: Int64
  /// Last change per subject, deletions included, so stale updates never win.
  private var revisionBySubject: [AgentGrantSubject: Int64]

  public init(_ result: InlineProtocol.ListAgentGrantsResult, botUserID: Int64) {
    self.botUserID = botUserID
    var operations: [AgentGrantSubject: Set<InlineProtocol.AgentGrantOperation>] = [:]
    var revisions: [AgentGrantSubject: Int64] = [:]
    for grant in result.grants where grant.botUserID == botUserID {
      let ops = Set(grant.operations).subtracting([.unspecified])
      guard !ops.isEmpty,
            let subject = AgentGrantSubject(subject: grant.hasSubject ? grant.subject : nil, userID: grant.userID)
      else { continue }
      operations[subject] = ops
      revisions[subject] = grant.revision
    }
    operationsBySubject = operations
    revisionBySubject = revisions
    snapshotRevision = result.revision
    revision = max(result.revision, revisions.values.max() ?? 0)
  }

  /// Operations per person with an active grant.
  public var operationsByUserID: [Int64: Set<InlineProtocol.AgentGrantOperation>] {
    var result: [Int64: Set<InlineProtocol.AgentGrantOperation>] = [:]
    for (subject, operations) in operationsBySubject {
      if case let .user(id) = subject { result[id] = operations }
    }
    return result
  }

  public var userIDs: Set<Int64> {
    Set(operationsBySubject.keys.compactMap { if case let .user(id) = $0 { id } else { nil } })
  }

  public var spaceIDs: Set<Int64> {
    Set(operationsBySubject.keys.compactMap { if case let .space(id) = $0 { id } else { nil } })
  }

  public var groupIDs: Set<Int64> {
    Set(operationsBySubject.keys.compactMap { if case let .group(id) = $0 { id } else { nil } })
  }

  public func hasGrant(userID: Int64) -> Bool {
    operationsBySubject[.user(userID)] != nil
  }

  /// People who manage the bot with its owner.
  public var adminUserIDs: Set<Int64> {
    Set(operationsBySubject.compactMap { subject, operations in
      if case let .user(id) = subject, operations.contains(.configure) { id } else { nil }
    })
  }

  /// Nil for someone who isn't on the list.
  public func role(userID: Int64) -> BotAccessRole? {
    guard let operations = operationsBySubject[.user(userID)] else { return nil }
    return operations.contains(.configure) ? .admin : .member
  }

  /// The operations that give `userID` a role, keeping what the role doesn't
  /// cover (an approval delegate stays one when made an admin).
  public func operations(for role: BotAccessRole, userID: Int64) -> Set<InlineProtocol.AgentGrantOperation> {
    let kept = (operationsBySubject[.user(userID)] ?? []).intersection([.approve])
    return role.operations.union(kept)
  }

  public func hasGrant(_ subject: AgentGrantSubject) -> Bool {
    operationsBySubject[subject] != nil
  }

  /// Applies one person's grant change; empty operations remove the grant.
  /// Returns false when the change is not newer than what is already here.
  @discardableResult
  public mutating func apply(
    userID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64
  ) -> Bool {
    apply(subject: .user(userID), operations: operations, revision: revision)
  }

  @discardableResult
  public mutating func apply(
    subject: AgentGrantSubject,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64
  ) -> Bool {
    guard revision > snapshotRevision, revision > (revisionBySubject[subject] ?? 0) else { return false }
    revisionBySubject[subject] = revision
    let ops = operations.subtracting([.unspecified])
    operationsBySubject[subject] = ops.isEmpty ? nil : ops
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

/// Who can reach each bot, for the current viewer: what they may do on bots
/// they see, and the full access list of bots they own.
///
/// The server stays authoritative and rejects what isn't allowed. Here an
/// unknown answer never takes anything away: actions render enabled and a
/// composer stays. Only a known "no" hides them.
@MainActor
public final class AgentGrantStore: ObservableObject {
  public static let shared = AgentGrantStore(database: .shared)

  @Published public private(set) var accessByBotUserID: [Int64: AgentGrantAccess] = [:]
  /// Full access lists, only for bots the viewer owns.
  @Published public private(set) var ownedGrantsByBotUserID: [Int64: OwnedAgentGrants] = [:]
  /// Whether anyone may message a bot the viewer owns, once its settings loaded.
  @Published public private(set) var openToEveryoneByBotUserID: [Int64: Bool] = [:]
  /// Bots whose access list couldn't be loaded, until a load succeeds.
  @Published public private(set) var failedBotUserIDs: Set<Int64> = []

  private let log = Log.scoped("AgentGrantStore")
  private let database: AppDatabase?
  private let auth: AuthHandle
  private let realtime: @Sendable () -> any InlineRPCRealtime
  private var inFlight: Set<Int64> = []
  private var failedAt: [Int64: Date] = [:]
  /// Bots loaded since launch. Stored answers render first; this decides
  /// whether `ensureLoaded` still owes a fresh one.
  private var loadedBotUserIDs: Set<Int64> = []
  /// Bots the server answered about, here or in an earlier session. A listing
  /// never overrides that answer: it can't see space, group or open access.
  private var resolvedBotUserIDs: Set<Int64> = []
  private var unaskedObservation: AnyDatabaseCancellable?
  private var resolvingUnasked = false
  private var unaskedFailedAt: Date?
  private var lastFullRefresh: Date?
  private var hydratedViewerUserID: Int64?
  /// Bumped by `removeAll` (logout, reset) so a load started for another
  /// account or before the reset never lands.
  private var generation: UInt64 = 0

  public convenience init(database: AppDatabase? = nil) {
    self.init(database: database, auth: Auth.shared.handle, realtime: { Api.realtime })
  }

  init(
    database: AppDatabase?,
    auth: AuthHandle,
    realtime: @escaping @Sendable () -> any InlineRPCRealtime
  ) {
    self.database = database
    self.auth = auth
    self.realtime = realtime
    hydrate()
  }

  public func access(botUserID: Int64) -> AgentGrantAccess? {
    accessByBotUserID[botUserID]
  }

  public func ownedGrants(botUserID: Int64) -> OwnedAgentGrants? {
    ownedGrantsByBotUserID[botUserID]
  }

  /// True only when the server said the viewer can't reach this bot and the
  /// bot hasn't invited an answer.
  public func isUnreachable(botUserID: Int64) -> Bool {
    accessByBotUserID[botUserID]?.isUnreachable == true
  }

  /// Whether a list that offers people to message, mention or add should
  /// include this user. People always; a bot only once the viewer is known
  /// to reach it. Before the server has answered about any bot (an older
  /// server, a first launch offline) every bot is offered, as it always was.
  public func offers(_ user: User) -> Bool {
    user.bot != true || resolvedBotUserIDs.isEmpty || accessByBotUserID[user.id]?.canMessage == true
  }

  /// A bot wrote to the viewer in its DM. If its chat had no composer, ask
  /// again: a bot that writes to someone can be answered.
  public func noteIncomingDirectMessage(fromUserID: Int64) {
    guard isUnreachable(botUserID: fromUserID) else { return }
    Task { @MainActor [weak self] in await self?.resolveAccess(botUserIDs: [fromUserID]) }
  }

  /// Loads the viewer's access to a bot once per launch, unless a load failed recently.
  public func ensureLoaded(botUserID: Int64) {
    guard !loadedBotUserIDs.contains(botUserID) else { return }
    if let failedAt = failedAt[botUserID], Date().timeIntervalSince(failedAt) < 60 { return }
    load(botUserID: botUserID)
  }

  /// Reloads even when cached; the cached value stays visible meanwhile.
  public func refresh(botUserID: Int64) {
    load(botUserID: botUserID)
  }

  private func load(botUserID: Int64) {
    guard botUserID > 0, !inFlight.contains(botUserID),
          let accountID = auth.userId()
    else { return }
    inFlight.insert(botUserID)
    let generation = generation
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { if self.generation == generation { self.inFlight.remove(botUserID) } }
      let resolved = await self.resolveAccess(botUserIDs: [botUserID])
      guard self.generation == generation, self.auth.userId() == accountID else { return }
      // The access list is for the owner and admins to read. Without an
      // answer (an older server), the listing still tells an owner from a grantee.
      if resolved, self.accessByBotUserID[botUserID]?.canManage == false {
        self.finishLoad(botUserID: botUserID, failed: false)
        return
      }
      do {
        let response = try await self.realtime().callRpcDirect(
          method: .listAgentGrants,
          input: .listAgentGrants(.with {
            $0.botUserID = botUserID
            $0.includeAllSubjects = true
          }),
          timeout: nil,
          accountToken: nil
        )
        guard self.generation == generation, self.auth.userId() == accountID,
              case let .listAgentGrants(result)? = response
        else { return }
        self.apply(result, botUserID: botUserID, viewerUserID: accountID)
        self.finishLoad(botUserID: botUserID, failed: false)
        if self.ownedGrantsByBotUserID[botUserID] != nil { await self.loadOpenToEveryone(botUserID: botUserID) }
      } catch {
        guard self.generation == generation else { return }
        // A manager without the list has nothing to manage, so that is a failure too.
        let ownerWithoutList = self.accessByBotUserID[botUserID]?.canManage == true &&
          self.ownedGrantsByBotUserID[botUserID] == nil
        self.finishLoad(botUserID: botUserID, failed: !resolved || ownerWithoutList)
        self.log.debug("Couldn't load grants for bot \(botUserID): \(error)")
      }
    }
  }

  private func finishLoad(botUserID: Int64, failed: Bool) {
    if failed {
      failedAt[botUserID] = Date()
      failedBotUserIDs.insert(botUserID)
    } else {
      failedAt[botUserID] = nil
      loadedBotUserIDs.insert(botUserID)
      if failedBotUserIDs.contains(botUserID) { failedBotUserIDs.remove(botUserID) }
    }
  }

  // MARK: Access list edits

  /// Gives one person access to a bot the viewer owns, or changes it.
  public func setGrant(
    botUserID: Int64,
    userID: Int64,
    operations: Set<InlineProtocol.AgentGrantOperation> = .agentAllowlistDefault
  ) async throws {
    try await setGrant(botUserID: botUserID, subject: .user(userID), operations: operations)
  }

  /// Gives a person, a space or a group access to a bot the viewer owns.
  public func setGrant(
    botUserID: Int64,
    subject: AgentGrantSubject,
    operations: Set<InlineProtocol.AgentGrantOperation> = .agentAllowlistDefault
  ) async throws {
    let generation = generation
    let response = try await realtime().callRpcDirect(
      method: .setAgentGrant,
      input: .setAgentGrant(.with {
        $0.botUserID = botUserID
        if case let .user(userID) = subject { $0.userID = userID }
        $0.subject = subject.accessSubject
        $0.operations = Array(operations).sorted { $0.rawValue < $1.rawValue }
      }),
      timeout: nil,
      accountToken: nil
    )
    guard self.generation == generation, case let .setAgentGrant(result)? = response else { return }
    applyOwned(
      botUserID: botUserID,
      subject: subject,
      operations: Set(result.grant.operations),
      revision: result.grant.revision
    )
  }

  /// Removes one person's access to a bot the viewer owns.
  public func deleteGrant(botUserID: Int64, userID: Int64) async throws {
    try await deleteGrant(botUserID: botUserID, subject: .user(userID))
  }

  public func deleteGrant(botUserID: Int64, subject: AgentGrantSubject) async throws {
    let generation = generation
    let response = try await realtime().callRpcDirect(
      method: .deleteAgentGrant,
      input: .deleteAgentGrant(.with {
        $0.botUserID = botUserID
        if case let .user(userID) = subject { $0.userID = userID }
        $0.subject = subject.accessSubject
      }),
      timeout: nil,
      accountToken: nil
    )
    guard self.generation == generation, case let .deleteAgentGrant(result)? = response else { return }
    applyOwned(botUserID: botUserID, subject: subject, operations: [], revision: result.revision)
  }

  // MARK: Open to everyone

  /// Lets anyone message a bot the viewer owns, or limits it to the access
  /// list again. Applies optimistically and reverts when the server rejects it.
  public func setOpenToEveryone(_ open: Bool, botUserID: Int64) async throws {
    let generation = generation
    let previous = openToEveryoneByBotUserID[botUserID]
    openToEveryoneByBotUserID[botUserID] = open
    do {
      let response = try await realtime().callRpcDirect(
        method: .updateAgentSettings,
        input: .updateAgentSettings(.with {
          $0.botUserID = botUserID
          $0.openToEveryone = open
        }),
        timeout: nil,
        accountToken: nil
      )
      guard self.generation == generation, case let .updateAgentSettings(result)? = response, result.hasSettings
      else { return }
      apply(settings: result.settings)
    } catch {
      if self.generation == generation { openToEveryoneByBotUserID[botUserID] = previous }
      throw error
    }
  }

  public func apply(settings: InlineProtocol.AgentSettings) {
    guard ownedGrantsByBotUserID[settings.botUserID] != nil,
          openToEveryoneByBotUserID[settings.botUserID] != settings.openToEveryone
    else { return }
    openToEveryoneByBotUserID[settings.botUserID] = settings.openToEveryone
  }

  private func loadOpenToEveryone(botUserID: Int64) async {
    let generation = generation
    let response = try? await realtime().callRpcDirect(
      method: .getAgentSettings,
      input: .getAgentSettings(.with { $0.botUserID = botUserID }),
      timeout: nil,
      accountToken: nil
    )
    guard self.generation == generation, case let .getAgentSettings(result)? = response, result.hasSettings
    else { return }
    apply(settings: result.settings)
  }

  // MARK: Applying server state

  public func apply(_ result: InlineProtocol.ListAgentGrantsResult, botUserID: Int64, viewerUserID: Int64) {
    // The owner and admins get the whole list; everyone else only their own entry.
    let managesByListing = result.grants.contains { grant in
      grant.botUserID == botUserID && grant.userID == viewerUserID && grant.operations.contains(.configure)
    }
    if result.ownerUserID == viewerUserID || managesByListing {
      let owned = OwnedAgentGrants(result, botUserID: botUserID)
      if let current = ownedGrantsByBotUserID[botUserID], current.revision > owned.revision {
        // A newer local edit or update already landed.
      } else if ownedGrantsByBotUserID[botUserID] != owned {
        ownedGrantsByBotUserID[botUserID] = owned
      }
    } else if ownedGrantsByBotUserID[botUserID] != nil {
      ownedGrantsByBotUserID[botUserID] = nil
      openToEveryoneByBotUserID[botUserID] = nil
    }
    // The server's resolved answer covers spaces, groups and open bots; the
    // viewer's own entry in the listing covers none of them.
    guard !resolvedBotUserIDs.contains(botUserID) else { return }
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
    guard let viewerUserID = auth.userId() else { return }
    apply(update, viewerUserID: viewerUserID)
    // The viewer's own access changed: ask for the resolved answer, which
    // also says whether they can still message the bot some other way.
    if update.userID == viewerUserID {
      let botUserID = update.botUserID
      Task { @MainActor [weak self] in await self?.resolveAccess(botUserIDs: [botUserID]) }
    }
  }

  func apply(_ update: InlineProtocol.UpdateAgentGrant, viewerUserID: Int64) {
    // Owners receive every grant change on their bots.
    if let subject = AgentGrantSubject(subject: update.hasSubject ? update.subject : nil, userID: update.userID) {
      applyOwned(
        botUserID: update.botUserID,
        subject: subject,
        operations: update.hasGrant ? Set(update.grant.operations) : [],
        revision: update.revision
      )
    }
    guard update.userID == viewerUserID,
          let current = accessByBotUserID[update.botUserID]
    else {
      // Without the owner id this viewer has no cached access to amend.
      return
    }
    guard update.revision >= current.revision else { return }
    let operations: Set<InlineProtocol.AgentGrantOperation> = update.hasGrant ? Set(update.grant.operations) : []
    store(.init(
      botUserID: update.botUserID,
      ownerUserID: current.ownerUserID,
      viewerUserID: viewerUserID,
      operations: operations,
      revision: update.revision,
      // Losing a grant doesn't say whether the bot is open to everyone.
      canMessage: operations.isEmpty ? nil : true
    ))
  }

  public func removeAll() {
    generation &+= 1
    accessByBotUserID.removeAll()
    ownedGrantsByBotUserID.removeAll()
    openToEveryoneByBotUserID.removeAll()
    failedBotUserIDs.removeAll()
    failedAt.removeAll()
    inFlight.removeAll()
    loadedBotUserIDs.removeAll()
    resolvedBotUserIDs.removeAll()
    unaskedObservation?.cancel()
    unaskedObservation = nil
    resolvingUnasked = false
    unaskedFailedAt = nil
    lastFullRefresh = nil
    hydratedViewerUserID = nil
  }

  private func applyOwned(
    botUserID: Int64,
    subject: AgentGrantSubject,
    operations: Set<InlineProtocol.AgentGrantOperation>,
    revision: Int64
  ) {
    guard var owned = ownedGrantsByBotUserID[botUserID],
          owned.apply(subject: subject, operations: operations, revision: revision)
    else { return }
    ownedGrantsByBotUserID[botUserID] = owned
  }

  private func store(_ access: AgentGrantAccess) {
    if let current = accessByBotUserID[access.botUserID], current.revision > access.revision { return }
    guard accessByBotUserID[access.botUserID] != access else { return }
    accessByBotUserID[access.botUserID] = access
  }
}

// MARK: - Resolved access, kept in the database

public extension AgentGrantStore {
  /// How many bots one `getAgentAccess` call may ask about.
  nonisolated static let accessBatchSize = 200

  /// Keeps the stored answers current: asks about each new bot as it is first
  /// saved, and about all of them when the last full answer is old. Call when
  /// the app becomes active while signed in; repeated calls are cheap.
  func start() {
    guard auth.userId() != nil else { return }
    hydrate()
    observeUnaskedBots()
    Task { @MainActor [weak self] in await self?.refreshAllAccessIfStale() }
  }

  /// Asks again about every bot saved here, at most once per `maxAge`. For
  /// app activation: access through a space, a group or an open bot changes
  /// without an update to this viewer.
  func refreshAllAccessIfStale(maxAge: TimeInterval = 600) async {
    if let lastFullRefresh, Date().timeIntervalSince(lastFullRefresh) < maxAge { return }
    await refreshAllAccess()
  }

  func refreshAllAccess() async {
    guard let database else { return }
    let generation = generation
    guard let ids = try? await database.reader.read({ db in try BotVisibility.allBotIds(db) }),
          self.generation == generation
    else { return }
    lastFullRefresh = Date()
    if await !resolveAccess(botUserIDs: ids), self.generation == generation { lastFullRefresh = nil }
  }

  /// Asks the server what the viewer may do with these bots and stores the
  /// answers. Returns false when nothing could be learned (offline, or a
  /// server without this call), leaving what is stored untouched.
  @discardableResult
  func resolveAccess(botUserIDs: [Int64]) async -> Bool {
    let ids = Array(Set(botUserIDs.filter { $0 > 0 })).sorted()
    guard !ids.isEmpty, let viewerUserID = auth.userId() else { return ids.isEmpty }
    let generation = generation
    var answers: [InlineProtocol.AgentAccess] = []
    for start in stride(from: 0, to: ids.count, by: Self.accessBatchSize) {
      let chunk = Array(ids[start ..< min(start + Self.accessBatchSize, ids.count)])
      do {
        let response = try await realtime().callRpcDirect(
          method: .getAgentAccess,
          input: .getAgentAccess(.with { $0.botUserIds = chunk }),
          timeout: nil,
          accountToken: nil
        )
        guard case let .getAgentAccess(result)? = response else { return false }
        answers.append(contentsOf: result.access)
      } catch {
        log.debug("Couldn't resolve access for \(chunk.count) bots: \(error)")
        return false
      }
    }
    guard self.generation == generation, auth.userId() == viewerUserID else { return false }
    let answered = Set(answers.map(\.botUserID))
    // A bot the server left out is deleted or unknown to it: nobody reaches it.
    let records = answers.map(BotAccess.init) +
      ids.filter { !answered.contains($0) }.map { BotAccess(botUserId: $0, canMessage: false, operations: []) }
    for answer in answers { applyResolved(answer, viewerUserID: viewerUserID) }
    for id in ids where !answered.contains(id) {
      applyResolved(.with { $0.botUserID = id }, viewerUserID: viewerUserID)
    }
    persist(records)
    return true
  }

  private func applyResolved(_ answer: InlineProtocol.AgentAccess, viewerUserID: Int64) {
    resolvedBotUserIDs.insert(answer.botUserID)
    let current = accessByBotUserID[answer.botUserID]
    let access = AgentGrantAccess(
      botUserID: answer.botUserID,
      ownerUserID: answer.isOwner ? viewerUserID : answer.ownerUserID,
      viewerUserID: viewerUserID,
      operations: Set(answer.operations).subtracting([.unspecified]),
      // The answer is current as of now; keep the revision so later grant
      // updates still order against it.
      revision: current?.revision ?? 0,
      canMessage: answer.canMessage,
      canReply: answer.canReply
    )
    guard current != access else { return }
    accessByBotUserID[answer.botUserID] = access
  }

  private func persist(_ records: [BotAccess]) {
    guard let database, !records.isEmpty, let account = try? auth.beginAccountMutation() else { return }
    let auth = auth
    Task.detached {
      try? await database.dbWriter.write { db in
        try auth.validateAccountMutation(account)
        for record in records {
          // The bot may have been deleted locally while the answer was in flight.
          guard try User.exists(db, key: record.botUserId) else { continue }
          try BotAccess.set(db, record)
        }
      }
    }
  }

  /// Stored answers, read once per account so the first frame already knows them.
  private func hydrate() {
    guard let database, let viewerUserID = auth.userId(), hydratedViewerUserID != viewerUserID else { return }
    hydratedViewerUserID = viewerUserID
    let stored = try? database.reader.read { db -> ([BotAccess], [BotOwner]) in
      (try BotAccess.fetchAll(db), try BotOwner.fetchAll(db))
    }
    guard let (records, owners) = stored else { return }
    let ownerByBot = Dictionary(owners.map { ($0.botUserId, $0.ownerUserId) }, uniquingKeysWith: { first, _ in first })
    for record in records where accessByBotUserID[record.botUserId] == nil {
      resolvedBotUserIDs.insert(record.botUserId)
      accessByBotUserID[record.botUserId] = AgentGrantAccess(
        botUserID: record.botUserId,
        ownerUserID: ownerByBot[record.botUserId] ?? 0,
        viewerUserID: viewerUserID,
        operations: record.grantOperations,
        revision: 0,
        canMessage: record.canMessage,
        canReply: record.canReply
      )
    }
  }

  private func observeUnaskedBots() {
    guard let database, unaskedObservation == nil else { return }
    unaskedObservation = ValueObservation
      .tracking { db in try BotVisibility.unaskedBotIds(db) }
      .removeDuplicates()
      .start(
        in: database.reader,
        scheduling: .async(onQueue: .main),
        onError: { _ in },
        onChange: { [weak self] ids in
          MainActor.assumeIsolated { self?.resolveUnasked(ids) }
        }
      )
  }

  private func resolveUnasked(_ ids: [Int64]) {
    guard !ids.isEmpty, !resolvingUnasked else { return }
    // Don't hammer a server that can't answer; activation refresh retries.
    if let unaskedFailedAt, Date().timeIntervalSince(unaskedFailedAt) < 60 { return }
    resolvingUnasked = true
    let generation = generation
    Task { @MainActor [weak self] in
      guard let self else { return }
      let resolved = await self.resolveAccess(botUserIDs: Array(ids.prefix(Self.accessBatchSize)))
      guard self.generation == generation else { return }
      self.resolvingUnasked = false
      self.unaskedFailedAt = resolved ? nil : Date()
    }
  }
}
