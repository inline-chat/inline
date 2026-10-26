import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

/// How an Agent publishes its work in a thread (spec §6). Detailed posts every
/// harness item as progress; Friendly posts only short prose updates.
public enum AgentThreadOutputMode: String, Codable, Equatable, Sendable, CaseIterable {
  case detailed
  case friendly

  public init?(_ mode: InlineProtocol.AgentOutputMode) {
    switch mode {
    case .detailed: self = .detailed
    case .friendly: self = .friendly
    case .unspecified, .UNRECOGNIZED: return nil
    }
  }

  public var protocolValue: InlineProtocol.AgentOutputMode {
    switch self {
    case .detailed: .detailed
    case .friendly: .friendly
    }
  }

  public var title: String {
    switch self {
    case .detailed: String(localized: "Detailed")
    case .friendly: String(localized: "Friendly")
    }
  }

  public var summary: String {
    switch self {
    case .detailed: String(localized: "Every step the agent takes, with tool calls you can expand.")
    case .friendly: String(localized: "Only short updates and the final answer.")
    }
  }
}

public enum AgentWorkWaitingKind: String, Codable, Equatable, Sendable {
  case approval
  case question
  case dialog
  case limit
  case setup
}

/// Thin run state the server keeps per Agent session. Unknown or missing
/// state is never presented as idle.
public enum AgentWorkRunState: Codable, Equatable, Sendable {
  case idle
  case working
  case waiting(AgentWorkWaitingKind?)
  case stopping
  case paused
  case heldElsewhere(label: String?)
  case offline
  case unknown

  public var isActive: Bool {
    switch self {
    case .working, .waiting, .stopping: true
    case .idle, .paused, .heldElsewhere, .offline, .unknown: false
    }
  }

  init(_ state: InlineProtocol.AgentSessionState) {
    switch state.runState {
    case .idle: self = .idle
    case .working: self = .working
    case .waiting:
      let kind: AgentWorkWaitingKind? = switch state.waitingReason {
      case .approval: .approval
      case .question: .question
      case .dialog: .dialog
      case .limit: .limit
      case .setup: .setup
      case .unspecified, .UNRECOGNIZED: nil
      }
      self = .waiting(kind)
    case .stopping: self = .stopping
    case .paused: self = .paused
    case .heldElsewhere:
      let label = state.hasHeldBy && state.heldBy.hasLabel ? state.heldBy.label : ""
      self = .heldElsewhere(label: label.isEmpty ? nil : label)
    case .offline: self = .offline
    case .unknown, .UNRECOGNIZED: self = .unknown
    }
  }
}

/// Render-ready state of one Agent's work in one chat: the participation's
/// default session, else the most recently updated one.
public struct AgentWorkState: Codable, Equatable, Sendable, Identifiable {
  public struct Key: Hashable, Codable, Sendable {
    public let peer: Peer
    public let botUserID: Int64

    public init(peer: Peer, botUserID: Int64) {
      self.peer = peer
      self.botUserID = botUserID
    }

    var storageKey: String { "\(peer.toString()):\(botUserID)" }
  }

  public var id: Key { key }
  public let key: Key
  public var sessionID: Int64
  public var runState: AgentWorkRunState
  /// People the current wait is for (approvals: owner and delegates).
  public var attentionForUserIDs: [Int64]
  public var attentionMessageID: Int64?
  public var queueCount: Int
  /// Short chip text such as "Limit resets 3:00 PM".
  public var detail: String?
  public var startedAt: Date?
  public var updatedAt: Date
  public var revision: Int64

  public init(
    key: Key,
    sessionID: Int64,
    runState: AgentWorkRunState,
    attentionForUserIDs: [Int64] = [],
    attentionMessageID: Int64? = nil,
    queueCount: Int = 0,
    detail: String? = nil,
    startedAt: Date? = nil,
    updatedAt: Date = Date(),
    revision: Int64 = 0
  ) {
    self.key = key
    self.sessionID = sessionID
    self.runState = runState
    self.attentionForUserIDs = attentionForUserIDs
    self.attentionMessageID = attentionMessageID
    self.queueCount = queueCount
    self.detail = detail
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.revision = revision
  }

  public init?(session: InlineProtocol.AgentSession) {
    guard session.hasState, session.botUserID > 0, session.hasPeerID else { return nil }
    let state = session.state
    let attention: InlineProtocol.AgentAttention? = state.hasAttention ? state.attention : nil
    self.init(
      key: .init(peer: session.peerID.toPeer(), botUserID: session.botUserID),
      sessionID: session.id,
      runState: AgentWorkRunState(state),
      attentionForUserIDs: attention?.userIds ?? [],
      attentionMessageID: attention.flatMap { $0.hasMessageID ? $0.messageID : nil },
      queueCount: Int(state.queuedCount),
      detail: state.hasDetail && !state.detail.isEmpty ? state.detail : nil,
      startedAt: state.hasStartedAt ? Date(timeIntervalSince1970: TimeInterval(state.startedAt)) : nil,
      updatedAt: Date(timeIntervalSince1970: TimeInterval(state.updatedAt)),
      revision: state.revision
    )
  }

  public func isWaiting(for userID: Int64?) -> Bool {
    guard case .waiting = runState, let userID else { return false }
    return attentionForUserIDs.isEmpty || attentionForUserIDs.contains(userID)
  }
}

/// Agent work state for chats: run state per (chat, agent), the per-thread
/// output mode override and each agent's default. Reads are synchronous and
/// hydrated once from the local database, so Compose, the work bar and the
/// sidebar render the last known state on their first frame. Server updates
/// replace it as they arrive.
@MainActor
public final class AgentWorkStateStore: ObservableObject {
  public static let shared = AgentWorkStateStore(database: .shared)

  private enum Kind: String {
    case session
    case outputOverride
    case outputDefault
  }

  private struct Row: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agentClientState"
    var kind: String
    var key: String
    var payload: Data
  }

  private struct OutputOverride: Codable {
    var key: AgentWorkState.Key
    var mode: AgentThreadOutputMode?
    var revision: Int64
  }

  private struct OutputDefault: Codable {
    var botUserID: Int64
    var mode: AgentThreadOutputMode?
    var isOffline: Bool?
  }

  @Published public private(set) var states: [AgentWorkState.Key: AgentWorkState] = [:]
  @Published public private(set) var outputOverrides: [AgentWorkState.Key: AgentThreadOutputMode] = [:]
  @Published public private(set) var defaultOutputModes: [Int64: AgentThreadOutputMode] = [:]
  /// Bots that reported a bridge v2 runtime, so their output mode applies.
  @Published public private(set) var runtimeBotUserIDs: Set<Int64> = []
  /// Bots whose runtime the server reports offline (lapsed heartbeats).
  @Published public private(set) var offlineBotUserIDs: Set<Int64> = []

  private let database: AppDatabase?
  private let log = Log.scoped("AgentWorkStateStore")
  private var overrideRevisions: [AgentWorkState.Key: Int64] = [:]
  private var didHydrate = false
  /// Bumped by `removeAll` (logout, reset) so a refresh started before it,
  /// or for another account, never repopulates the cleared state.
  private var generation: UInt64 = 0

  public init(database: AppDatabase? = nil) {
    self.database = database
    // Hydrate before any view reads, so first-frame reads never publish
    // from inside a view update.
    hydrateIfNeeded()
  }

  // MARK: Reads

  public func state(peer: Peer, botUserID: Int64) -> AgentWorkState? {
    hydrateIfNeeded()
    return states[.init(peer: peer, botUserID: botUserID)].map(overlaid)
  }

  public func states(peer: Peer) -> [AgentWorkState] {
    hydrateIfNeeded()
    return states.values
      .filter { $0.key.peer == peer }
      .map(overlaid)
      .sorted { $0.key.botUserID < $1.key.botUserID }
  }

  /// An offline runtime overrides the last-known work state; the state
  /// itself is kept and returns when the runtime reports again.
  private func overlaid(_ state: AgentWorkState) -> AgentWorkState {
    guard offlineBotUserIDs.contains(state.key.botUserID), state.runState != .idle else { return state }
    var copy = state
    copy.runState = .offline
    return copy
  }

  /// The most urgent state among a chat's agents, for sidebar badges. Idle,
  /// paused and offline agents show no badge.
  public func badgeState(peer: Peer, viewerUserID: Int64?) -> AgentWorkState? {
    let candidates = states(peer: peer).filter { Self.urgency($0, viewer: viewerUserID) > 0 }
    return candidates.max { Self.urgency($0, viewer: viewerUserID) < Self.urgency($1, viewer: viewerUserID) }
  }

  /// The effective output mode: the thread's override, else the agent's
  /// default, else Detailed.
  public func outputMode(peer: Peer, botUserID: Int64) -> AgentThreadOutputMode {
    hydrateIfNeeded()
    return outputOverrides[.init(peer: peer, botUserID: botUserID)]
      ?? defaultOutputModes[botUserID]
      ?? .detailed
  }

  public func outputModeOverride(peer: Peer, botUserID: Int64) -> AgentThreadOutputMode? {
    hydrateIfNeeded()
    return outputOverrides[.init(peer: peer, botUserID: botUserID)]
  }

  public func defaultOutputMode(botUserID: Int64) -> AgentThreadOutputMode {
    hydrateIfNeeded()
    return defaultOutputModes[botUserID] ?? .detailed
  }

  // MARK: Server input

  public func apply(session: InlineProtocol.AgentSession) {
    guard let state = AgentWorkState(session: session) else { return }
    apply(state)
  }

  /// Applies a server state, ignoring anything older for the same session.
  public func apply(_ state: AgentWorkState) {
    hydrateIfNeeded()
    if let current = states[state.key] {
      if current.sessionID == state.sessionID, current.revision > state.revision { return }
      // Another session of the same agent replaces the shown one only when
      // it is newer; the server owns the default-session rule.
      if current.sessionID != state.sessionID, current.updatedAt > state.updatedAt { return }
    }
    // A moved session reports its destination peer; drop it from the chat
    // it left so the source's work bar and badge clear.
    for (key, existing) in states where existing.sessionID == state.sessionID && key != state.key {
      remove(key)
    }
    guard states[state.key] != state else { return }
    states[state.key] = state
    persist(.session, key: state.key.storageKey, value: state)
  }

  public func apply(participation: InlineProtocol.AgentParticipation) {
    hydrateIfNeeded()
    guard participation.hasPeerID, participation.botUserID > 0 else { return }
    let key = AgentWorkState.Key(peer: participation.peerID.toPeer(), botUserID: participation.botUserID)
    if let revision = overrideRevisions[key], revision > participation.revision { return }
    overrideRevisions[key] = participation.revision
    let mode = participation.hasOutputMode ? AgentThreadOutputMode(participation.outputMode) : nil
    if outputOverrides[key] != mode { outputOverrides[key] = mode }
    persist(
      .outputOverride,
      key: key.storageKey,
      value: OutputOverride(key: key, mode: mode, revision: participation.revision)
    )
  }

  public func apply(runtime: InlineProtocol.AgentRuntime) {
    hydrateIfNeeded()
    guard runtime.botUserID > 0 else { return }
    let mode = AgentThreadOutputMode(runtime.defaultOutputMode)
    if defaultOutputModes[runtime.botUserID] != mode { defaultOutputModes[runtime.botUserID] = mode }
    if !runtimeBotUserIDs.contains(runtime.botUserID) { runtimeBotUserIDs.insert(runtime.botUserID) }
    let isOffline = runtime.status == .offline
    if isOffline != offlineBotUserIDs.contains(runtime.botUserID) {
      if isOffline { offlineBotUserIDs.insert(runtime.botUserID) } else { offlineBotUserIDs.remove(runtime.botUserID) }
    }
    persist(
      .outputDefault,
      key: "\(runtime.botUserID)",
      value: OutputDefault(botUserID: runtime.botUserID, mode: mode, isOffline: isOffline)
    )
  }

  /// Local echo for a change the viewer just made; the server update follows.
  public func setOutputModeOverride(_ mode: AgentThreadOutputMode?, peer: Peer, botUserID: Int64) {
    hydrateIfNeeded()
    outputOverrides[.init(peer: peer, botUserID: botUserID)] = mode
  }

  public func setDefaultOutputMode(_ mode: AgentThreadOutputMode, botUserID: Int64) {
    hydrateIfNeeded()
    defaultOutputModes[botUserID] = mode
  }

  /// Refreshes one chat's sessions, or the viewer's busy sessions everywhere
  /// when `peer` is nil (sidebar badges after launch or reconnect).
  public func refresh(peer: Peer? = nil) async {
    guard let accountID = Auth.shared.getCurrentUserId() else { return }
    let generation = generation
    do {
      let response = try await Api.realtime.callRpcDirect(
        method: .getAgentSessionStates,
        input: .getAgentSessionStates(.with { input in
          if let peer { input.peerID = peer.toInputPeer() }
        })
      )
      guard self.generation == generation, Auth.shared.getCurrentUserId() == accountID,
            case let .getAgentSessionStates(result)? = response
      else { return }
      let sessions = result.sessions.compactMap { AgentWorkState(session: $0) }
      if let peer {
        // A chat refresh is complete for that chat: drop agents that left.
        let present = Set(sessions.map(\.key))
        for key in states.keys where key.peer == peer && !present.contains(key) {
          remove(key)
        }
      }
      sessions.forEach { apply($0) }
    } catch {
      log.debug("Couldn't refresh agent session states: \(error)")
    }
  }

  public func remove(_ key: AgentWorkState.Key) {
    states[key] = nil
    delete(.session, key: key.storageKey)
  }

  public func removeAll() {
    generation &+= 1
    states.removeAll()
    outputOverrides.removeAll()
    defaultOutputModes.removeAll()
    runtimeBotUserIDs.removeAll()
    offlineBotUserIDs.removeAll()
    overrideRevisions.removeAll()
    guard let database else { return }
    Task.detached {
      try? await database.dbWriter.write { db in _ = try Row.deleteAll(db) }
    }
  }

  // MARK: Persistence

  private func hydrateIfNeeded() {
    guard !didHydrate else { return }
    didHydrate = true
    guard let database else { return }
    // A handful of small rows, read once on first use for first-frame state.
    let rows = (try? database.reader.read { db -> [Row] in try Row.fetchAll(db) }) ?? []
    let decoder = JSONDecoder()
    for row in rows {
      switch Kind(rawValue: row.kind) {
      case .session:
        if let state = try? decoder.decode(AgentWorkState.self, from: row.payload) { states[state.key] = state }
      case .outputOverride:
        if let value = try? decoder.decode(OutputOverride.self, from: row.payload) {
          outputOverrides[value.key] = value.mode
          overrideRevisions[value.key] = value.revision
        }
      case .outputDefault:
        if let value = try? decoder.decode(OutputDefault.self, from: row.payload) {
          defaultOutputModes[value.botUserID] = value.mode
          runtimeBotUserIDs.insert(value.botUserID)
          if value.isOffline == true { offlineBotUserIDs.insert(value.botUserID) }
        }
      case nil:
        break
      }
    }
  }

  private func persist(_ kind: Kind, key: String, value: some Encodable) {
    guard let database, let payload = try? JSONEncoder().encode(value) else { return }
    let row = Row(kind: kind.rawValue, key: key, payload: payload)
    Task.detached {
      try? await database.dbWriter.write { db in try row.save(db) }
    }
  }

  private func delete(_ kind: Kind, key: String) {
    guard let database else { return }
    let kind = kind.rawValue
    Task.detached {
      try? await database.dbWriter.write { db in
        _ = try Row.filter(Column("kind") == kind && Column("key") == key).deleteAll(db)
      }
    }
  }

  private static func urgency(_ state: AgentWorkState, viewer: Int64?) -> Int {
    switch state.runState {
    case .waiting: state.isWaiting(for: viewer) ? 4 : 2
    case .working, .stopping: 3
    case .heldElsewhere: 1
    case .paused, .offline, .idle, .unknown: 0
    }
  }
}
