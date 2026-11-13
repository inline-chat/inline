import Auth
import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger

/// The one answer to "who can be @-mentioned here", shared by every composer.
///
/// Candidates come from the local database (people with access to the chat,
/// the space, DM contacts and the current user's own bots) plus Agents. The
/// database answer is synchronous on first start for a first-frame menu; remote
/// data revalidates in the background and a failed fetch never clears what is
/// shown. Observation runs only during a mention session.
@MainActor
public final class MentionCandidatesSource {
  public enum Scope: Hashable, Sendable {
    /// An existing chat. `peer` is the composer's peer for Agent discovery.
    case chat(chatId: Int64, peer: Peer)
    /// A thread that doesn't exist yet, in a space or Home.
    case newThread(spaceId: Int64?)
  }

  /// The remote pieces, injectable so tests and previews stay offline.
  public struct Services {
    public var agentDirectory: BotAgentDirectory?
    public var ownedBots: OwnedBotsDirectory?
    public var rosterRefresher: MentionRosterRefresher?

    public init(
      agentDirectory: BotAgentDirectory?,
      ownedBots: OwnedBotsDirectory?,
      rosterRefresher: MentionRosterRefresher?
    ) {
      self.agentDirectory = agentDirectory
      self.ownedBots = ownedBots
      self.rosterRefresher = rosterRefresher
    }

    @MainActor public static var live: Services {
      Services(agentDirectory: .shared, ownedBots: .shared, rosterRefresher: .shared)
    }

    public static var offline: Services {
      Services(agentDirectory: nil, ownedBots: nil, rosterRefresher: nil)
    }
  }

  public private(set) var scope: Scope
  public private(set) var candidates: MentionCompletionCandidates = .empty

  /// Emits the current candidates on subscribe, then every distinct change.
  public var updates: AnyPublisher<MentionCompletionCandidates, Never> {
    subject.eraseToAnyPublisher()
  }

  private let db: AppDatabase
  private let services: Services
  private let currentUserId: @MainActor () -> Int64?
  private let subject = CurrentValueSubject<MentionCompletionCandidates, Never>(.empty)
  private let log = Log.scoped("MentionCandidatesSource")

  private var roster: MentionRoster?
  private var peerAgents: [MentionableBotAgent] = []
  private var observation: AnyCancellable?
  private var subscriptions = Set<AnyCancellable>()
  private var agentsGeneration = 0
  private var wantsRosterRefresh = false

  public init(
    db: AppDatabase,
    scope: Scope,
    services: Services = .live,
    currentUserId: @escaping @MainActor () -> Int64? = { Auth.shared.getCurrentUserId() }
  ) {
    self.db = db
    self.scope = scope
    self.services = services
    self.currentUserId = currentUserId

    // Sent on the main actor.
    services.ownedBots?.changes
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.publish() }
      }
      .store(in: &subscriptions)

    // Bot transactions post this from whatever thread applied them. This
    // closure is main-actor isolated, so it must run on the main queue.
    NotificationCenter.default.publisher(for: .botAgentsChanged)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        MainActor.assumeIsolated { self?.botsChanged() }
      }
      .store(in: &subscriptions)

    if case let .chat(_, peer) = scope, let cached = services.agentDirectory?.cachedAgents(for: peer) {
      peerAgents = cached
    }
  }

  /// Call when a mention session starts: observes the database (synchronously
  /// the first time) and revalidates Agents, the user's bots and the roster.
  public func beginSession() {
    startObserving()
    loadPeerAgents(force: false)
    if let ownedBots = services.ownedBots {
      Task { await ownedBots.refreshIfNeeded() }
    }
    wantsRosterRefresh = true
    refreshRosterIfReady()
  }

  /// Stops observing. The last candidates stay for the next session's first frame.
  public func endSession() {
    observation?.cancel()
    observation = nil
  }

  public func setScope(_ scope: Scope) {
    guard self.scope != scope else { return }
    self.scope = scope
    roster = nil
    peerAgents = []
    agentsGeneration += 1
    if case let .chat(_, peer) = scope, let cached = services.agentDirectory?.cachedAgents(for: peer) {
      peerAgents = cached
    }
    guard observation != nil else {
      // The next session reads the new scope synchronously.
      if candidates != .empty {
        candidates = .empty
        subject.send(candidates)
      }
      return
    }
    observation?.cancel()
    observation = nil
    // A new scope has nothing to show yet, so read it synchronously.
    startObserving(immediate: true)
    loadPeerAgents(force: false)
    wantsRosterRefresh = true
    refreshRosterIfReady()
  }

  // MARK: - Database

  private func startObserving(immediate: Bool? = nil) {
    guard observation == nil else { return }
    let scope = scope
    let currentUserId = currentUserId()
    db.warnIfInMemoryDatabaseForObservation("MentionCandidatesSource.roster")
    let observation = ValueObservation
      .tracking { db in try Self.roster(db, scope: scope, currentUserId: currentUserId) }
      .removeDuplicates()

    // The first read is synchronous so the menu's first frame has candidates.
    // Later sessions already show the last roster, so they read off the main thread.
    let publisher: AnyPublisher<MentionRoster, Error> = if immediate ?? (roster == nil) {
      observation.publisher(in: db.dbWriter, scheduling: .immediate).eraseToAnyPublisher()
    } else {
      observation.publisher(in: db.dbWriter, scheduling: .async(onQueue: .main)).eraseToAnyPublisher()
    }

    self.observation = publisher.sink(
      receiveCompletion: { [weak self] completion in
        guard case let .failure(error) = completion else { return }
        MainActor.assumeIsolated {
          self?.log.error("Failed to observe mention candidates", error: error)
          self?.observation = nil
        }
      },
      receiveValue: { [weak self] roster in
        MainActor.assumeIsolated {
          guard let self, self.scope == scope else { return }
          self.roster = roster
          self.publish()
          self.refreshRosterIfReady()
        }
      }
    )
  }

  private func publish() {
    guard let roster else { return }
    var next = roster.candidates
    let ownedBots = services.ownedBots?.snapshot ?? .empty
    if roster.offersAllOwnedBots {
      // Bots listed but not saved locally yet. Saved rows are fresher.
      let observed = Set(next.users.map(\.userInfo.id))
      next = next.addingOwnedBots(ownedBots.bots.filter { !observed.contains($0.id) })
    }
    next = next.addingAgents(peerAgents)
    let offeredUserIds = Set(next.users.map(\.userInfo.id))
    next = next.addingAgents(ownedBots.agents.filter { offeredUserIds.contains($0.botUserId) })
    guard next != candidates else { return }
    candidates = next
    subject.send(next)
  }

  // MARK: - Remote

  private func botsChanged() {
    loadPeerAgents(force: true)
    if let ownedBots = services.ownedBots {
      Task { await ownedBots.refresh() }
    }
    // A new bot may have joined this space as it was created.
    if let refresher = services.rosterRefresher, let keys = roster?.refreshKeys, !keys.isEmpty {
      Task { await refresher.refresh(keys, force: true) }
    }
  }

  private func loadPeerAgents(force: Bool) {
    guard case let .chat(_, peer) = scope, let directory = services.agentDirectory else { return }
    if let cached = directory.cachedAgents(for: peer), cached != peerAgents {
      peerAgents = cached
      publish()
    }
    guard force || directory.needsRefresh(for: peer) else { return }

    agentsGeneration += 1
    let generation = agentsGeneration
    Task { [weak self] in
      do {
        let agents = try await directory.agents(for: peer, forceRefresh: force)
        guard let self, generation == agentsGeneration else { return }
        peerAgents = agents
        publish()
      } catch {
        // Keep what is shown; the next session revalidates again.
        if !(error is CancellationError) {
          self?.log.error("Failed to load mention Agents", error: error)
        }
      }
    }
  }

  private func refreshRosterIfReady() {
    guard wantsRosterRefresh, let keys = roster?.refreshKeys else { return }
    wantsRosterRefresh = false
    guard let refresher = services.rosterRefresher else { return }
    Task { await refresher.refresh(keys) }
  }
}

// MARK: - Roster

/// What the database says about a scope, compared to skip redundant updates.
struct MentionRoster: Equatable, Sendable {
  var candidates: MentionCompletionCandidates
  /// What to fetch so the local roster is complete.
  var refreshKeys: [MentionRosterRefresher.Key]
  /// False in an existing space chat: the server adds only space members to
  /// it, so the user's bots are offered there once they are members.
  var offersAllOwnedBots: Bool
}

extension MentionCandidatesSource {
  /// How many of a chat's latest messages decide who spoke recently.
  nonisolated static let recentSenderWindow = 100

  nonisolated static func roster(
    _ db: Database,
    scope: Scope,
    currentUserId: Int64?
  ) throws -> MentionRoster {
    var accessIds: Set<Int64> = []
    var groupIdsWithAccess: Set<Int64> = []
    var spaceId: Int64?
    var recentSenderChatId: Int64?
    var refreshKeys: [MentionRosterRefresher.Key] = []
    var offersAllOwnedBots = true

    switch scope {
      case let .chat(chatId, peer):
        if let chat = try Chat.fetchOne(db, id: chatId) {
          let access = try ChatParticipantsWithMembersViewModel.effectiveParticipantAccess(db, for: chat)
          accessIds = access.userIds
          groupIdsWithAccess = access.groupIds
          spaceId = access.sourceChat.spaceId
          offersAllOwnedBots = spaceId == nil
          if access.sourceChat.type != .privateChat {
            refreshKeys.append(.chatParticipants(access.sourceChat.id))
          }
          if access.sourceChat.id != chat.id {
            refreshKeys.append(.chatParticipants(chat.id))
          }
        } else if case .thread = peer {
          refreshKeys.append(.chatParticipants(chatId))
        }
        if case let .user(peerUserId) = peer {
          accessIds.insert(peerUserId)
        }
        recentSenderChatId = chatId

      case let .newThread(id):
        spaceId = id
    }

    var memberIds: Set<Int64> = []
    var groups: [UserGroup] = []
    if let spaceId {
      refreshKeys.append(.spaceMembers(spaceId))
      refreshKeys.append(.userGroups(spaceId))
      memberIds = try Set(Int64.fetchAll(
        db,
        sql: "SELECT userId FROM member WHERE spaceId = ?",
        arguments: [spaceId]
      ))
      groups = try UserGroup
        .filter(UserGroup.Columns.spaceId == spaceId)
        .order(UserGroup.Columns.name)
        .fetchAll(db)
    }

    var ownedBotIds: Set<Int64> = if let currentUserId {
      try BotOwner.ownedBotIds(db, ownerUserId: currentUserId)
    } else {
      []
    }
    if !offersAllOwnedBots {
      ownedBotIds.formIntersection(memberIds.union(accessIds))
    }

    // Recency comes from the DM's last message date: message IDs are per chat
    // and can't be compared across chats.
    var lastDirectMessageDates: [Int64: Date] = [:]
    let directRows = try Row.fetchAll(
      db,
      sql: """
      SELECT chat.peerUserId AS userId, COALESCE(message.date, chat.date) AS date
      FROM chat
      LEFT JOIN message ON message.chatId = chat.id AND message.messageId = chat.lastMsgId
      WHERE chat.type = ? AND chat.peerUserId IS NOT NULL AND chat.lastMsgId > 0
      """,
      arguments: [ChatType.privateChat.rawValue]
    )
    for row in directRows {
      guard let userId: Int64 = row["userId"], let date: Date = row["date"] else { continue }
      lastDirectMessageDates[userId] = max(lastDirectMessageDates[userId] ?? .distantPast, date)
    }

    // A DM dialog can be optimistic (chatId is nil), so use its stable peer identity.
    let pinnedIds = try Set(Int64.fetchAll(
      db,
      sql: "SELECT peerUserId FROM dialog WHERE pinned = 1 AND peerUserId IS NOT NULL"
    ))

    var recentSenderRanks: [Int64: Int] = [:]
    if let recentSenderChatId {
      let senders = try Int64.fetchAll(
        db,
        sql: """
        SELECT fromId FROM message
        WHERE chatId = ? AND fromId IS NOT NULL
        ORDER BY messageId DESC
        LIMIT ?
        """,
        arguments: [recentSenderChatId, recentSenderWindow]
      )
      for senderId in senders where recentSenderRanks[senderId] == nil {
        recentSenderRanks[senderId] = recentSenderRanks.count
      }
    }

    var candidateIds = accessIds.union(memberIds).union(ownedBotIds)
    candidateIds.formUnion(lastDirectMessageDates.keys)
    if let currentUserId {
      candidateIds.remove(currentUserId)
    }

    let userInfos = candidateIds.isEmpty ? [] : try User
      .filter(candidateIds.contains(User.Columns.id))
      .including(all: User.photos.forKey(UserInfo.CodingKeys.profilePhoto))
      .asRequest(of: UserInfo.self)
      .fetchAll(db)

    let users = userInfos
      .filter { $0.user.pendingSetup != true }
      .compactMap { userInfo -> MentionCompletionUser? in
        let id = userInfo.id
        let source: MentionCompletionSource
        if accessIds.contains(id) {
          source = .participant
        } else if ownedBotIds.contains(id) {
          source = .ownedBot
        } else if memberIds.contains(id) {
          source = .spaceMember
        } else if lastDirectMessageDates[id] != nil {
          source = .directChat
        } else {
          return nil
        }
        return MentionCompletionUser(
          userInfo: userInfo,
          source: source,
          lastDirectMessageDate: lastDirectMessageDates[id],
          recentSenderRank: recentSenderRanks[id],
          isPinned: pinnedIds.contains(id)
        )
      }
      // Stable input keeps `removeDuplicates` effective.
      .sorted { $0.userInfo.id < $1.userInfo.id }

    return MentionRoster(
      candidates: MentionCompletionCandidates(
        users: users,
        groups: groups,
        groupIdsWithAccess: groupIdsWithAccess
      ),
      refreshKeys: refreshKeys,
      offersAllOwnedBots: offersAllOwnedBots
    )
  }
}

// MARK: - Roster refresh

/// Fetches the server rosters behind mention candidates at most every few
/// minutes per chat or space. Each request stands alone, and a failure is
/// retried on a later mention session instead of being remembered as done.
@MainActor
public final class MentionRosterRefresher {
  public enum Key: Hashable, Sendable {
    case chatParticipants(Int64)
    case spaceMembers(Int64)
    case userGroups(Int64)
  }

  public typealias Fetcher = @Sendable (Key) async throws -> Void

  public static let shared = MentionRosterRefresher()

  private let fetcher: Fetcher
  private let now: @MainActor () -> Date
  private let freshness: TimeInterval
  private let retryDelay: TimeInterval
  private var succeededAt: [Key: Date] = [:]
  private var failedAt: [Key: Date] = [:]
  private var inFlight: [Key: Task<Void, Never>] = [:]
  private var generation = 0
  private let log = Log.scoped("MentionRosterRefresher")

  public convenience init() {
    self.init(fetcher: Self.fetchLive)
  }

  public init(
    fetcher: @escaping Fetcher,
    now: @escaping @MainActor () -> Date = Date.init,
    freshness: TimeInterval = 5 * 60,
    retryDelay: TimeInterval = 15
  ) {
    self.fetcher = fetcher
    self.now = now
    self.freshness = freshness
    self.retryDelay = retryDelay
  }

  public func refresh(_ keys: [Key], force: Bool = false) async {
    let tasks = keys.compactMap { key -> Task<Void, Never>? in
      if let task = inFlight[key] { return task }
      guard force || needsRefresh(key) else { return nil }
      return start(key)
    }
    for task in tasks {
      await task.value
    }
  }

  public func clear() {
    generation += 1
    inFlight.values.forEach { $0.cancel() }
    inFlight.removeAll()
    succeededAt.removeAll()
    failedAt.removeAll()
  }

  private func needsRefresh(_ key: Key) -> Bool {
    let now = now()
    if let succeededAt = succeededAt[key], now.timeIntervalSince(succeededAt) < freshness { return false }
    if let failedAt = failedAt[key], now.timeIntervalSince(failedAt) < retryDelay { return false }
    return true
  }

  private func start(_ key: Key) -> Task<Void, Never> {
    let generation = generation
    let fetcher = fetcher
    let task = Task { [weak self] in
      let result: Result<Void, Error>
      do {
        try await fetcher(key)
        result = .success(())
      } catch {
        result = .failure(error)
      }
      guard let self, generation == self.generation else { return }
      inFlight[key] = nil
      switch result {
        case .success:
          succeededAt[key] = now()
          failedAt[key] = nil
        case let .failure(error):
          failedAt[key] = now()
          log.error("Failed to refresh mention roster \(key)", error: error)
      }
    }
    inFlight[key] = task
    return task
  }

  private static func fetchLive(_ key: Key) async throws {
    switch key {
      case let .chatParticipants(chatId):
        try await Api.realtime.send(.getChatParticipants(chatID: chatId))
      case let .spaceMembers(spaceId):
        try await Api.realtime.send(.getSpaceMembers(spaceId: spaceId))
      case let .userGroups(spaceId):
        try await Api.realtime.send(.getUserGroups(spaceId: spaceId))
    }
  }
}

// MARK: - Owned bots

/// The current user's own bots and their Agents. Bots are also saved to the
/// database (`BotOwner`); this keeps the listed copies and Agents
/// in memory, revalidates them, and never drops them on a failed refresh.
@MainActor
public final class OwnedBotsDirectory {
  public struct Snapshot: Equatable, Sendable {
    public var bots: [UserInfo]
    public var agents: [MentionableBotAgent]

    public static let empty = Snapshot(bots: [], agents: [])

    public init(bots: [UserInfo], agents: [MentionableBotAgent]) {
      self.bots = bots
      self.agents = agents
    }
  }

  /// One listing: every bot, and each bot's Agents or nil when that bot's
  /// Agents couldn't be fetched (its previous Agents are kept).
  public struct Listing: Sendable {
    public var bots: [UserInfo]
    public var agentsByBotId: [Int64: [MentionableBotAgent]?]

    public init(bots: [UserInfo], agentsByBotId: [Int64: [MentionableBotAgent]?]) {
      self.bots = bots
      self.agentsByBotId = agentsByBotId
    }
  }

  public typealias Fetcher = @Sendable () async throws -> Listing

  public static let shared = OwnedBotsDirectory()

  public private(set) var snapshot: Snapshot = .empty

  /// Emits after every snapshot change.
  public var changes: AnyPublisher<Snapshot, Never> {
    subject.eraseToAnyPublisher()
  }

  private let fetcher: Fetcher
  private let now: @MainActor () -> Date
  private let freshness: TimeInterval
  private let retryDelay: TimeInterval
  private let subject = PassthroughSubject<Snapshot, Never>()
  private var succeededAt: Date?
  private var failedAt: Date?
  private var inFlight: Task<Void, Never>?
  private var generation = 0
  private let log = Log.scoped("OwnedBotsDirectory")

  public convenience init() {
    self.init(fetcher: Self.fetchLive)
  }

  public init(
    fetcher: @escaping Fetcher,
    now: @escaping @MainActor () -> Date = Date.init,
    freshness: TimeInterval = 5 * 60,
    retryDelay: TimeInterval = 15
  ) {
    self.fetcher = fetcher
    self.now = now
    self.freshness = freshness
    self.retryDelay = retryDelay
  }

  /// Fetches when never fetched, stale, or past a failure's retry delay.
  public func refreshIfNeeded() async {
    // A second pass covers a change made while an older fetch was in flight.
    for _ in 0 ..< 2 {
      if let inFlight {
        await inFlight.value
        continue
      }
      guard needsRefresh else { return }
      await start().value
    }
  }

  /// Refetches now, e.g. after a bot or Agent changed.
  public func refresh() async {
    generation += 1
    succeededAt = nil
    failedAt = nil
    inFlight = nil
    await refreshIfNeeded()
  }

  public func clear() {
    generation += 1
    inFlight?.cancel()
    inFlight = nil
    succeededAt = nil
    failedAt = nil
    guard snapshot != .empty else { return }
    snapshot = .empty
    subject.send(snapshot)
  }

  private var needsRefresh: Bool {
    let now = now()
    if let succeededAt, now.timeIntervalSince(succeededAt) < freshness { return false }
    if let failedAt, now.timeIntervalSince(failedAt) < retryDelay { return false }
    return true
  }

  private func start() -> Task<Void, Never> {
    let generation = generation
    let fetcher = fetcher
    let task = Task { [weak self] in
      let result: Result<Listing, Error>
      do {
        result = try await .success(fetcher())
      } catch {
        result = .failure(error)
      }
      guard let self, generation == self.generation else { return }
      inFlight = nil
      switch result {
        case let .success(listing):
          succeededAt = now()
          failedAt = nil
          apply(listing)
        case let .failure(error):
          failedAt = now()
          log.error("Failed to list owned bots", error: error)
      }
    }
    inFlight = task
    return task
  }

  private func apply(_ listing: Listing) {
    let previousAgents = Dictionary(grouping: snapshot.agents, by: \.botUserId)
    let agents = listing.bots.flatMap { bot -> [MentionableBotAgent] in
      let fetched = listing.agentsByBotId[bot.id] ?? nil
      return (fetched ?? previousAgents[bot.id] ?? []).map { $0.withBotUserInfo(bot) }
    }
    let next = Snapshot(bots: listing.bots, agents: agents)
    guard next != snapshot else { return }
    snapshot = next
    subject.send(next)
  }

  private static func fetchLive() async throws -> Listing {
    // Sending `listBots` also saves the bots and their owner locally.
    guard case let .listBots(response)? = try await Api.realtime.send(.listBots()) else {
      throw OwnedBotsDirectoryError.invalidResponse
    }
    var bots: [UserInfo] = []
    var agentsByBotId: [Int64: [MentionableBotAgent]?] = [:]
    for bot in response.bots {
      let userInfo = UserInfo(user: User(from: bot))
      bots.append(userInfo)
      do {
        let result = try await Api.realtime.callRpcDirect(
          method: .listBotAgents,
          input: .listBotAgents(.with { $0.botUserID = bot.id })
        )
        guard case let .listBotAgents(agents)? = result else {
          throw OwnedBotsDirectoryError.invalidResponse
        }
        agentsByBotId[bot.id] = .some(agents.agents.map { MentionableBotAgent(agent: $0, botUserInfo: userInfo) })
      } catch {
        agentsByBotId[bot.id] = .some(nil)
      }
    }
    return Listing(bots: bots, agentsByBotId: agentsByBotId)
  }
}

private enum OwnedBotsDirectoryError: Error {
  case invalidResponse
}
