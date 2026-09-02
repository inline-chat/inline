import Foundation
import InlineProtocol
import Logger
import Observation

public extension Notification.Name {
  static let botAgentsChanged = Notification.Name("inline.botAgentsChanged")
}

public struct MentionableBotAgent: Hashable, Identifiable, Sendable {
  public let id: Int64
  public let botUserId: Int64
  public let name: String
  public let handle: String?
  public let emoji: String?
  public let description: String?
  public let botUserInfo: UserInfo

  public init(profile: InlineProtocol.BotAgentProfile, botUserInfo: UserInfo) {
    id = profile.id
    botUserId = profile.botUserID
    name = profile.name
    handle = profile.hasHandle ? profile.handle : nil
    emoji = profile.hasEmoji ? profile.emoji : nil
    description = profile.hasDescription_p ? profile.description_p : nil
    self.botUserInfo = botUserInfo
  }

  public init(agent: InlineProtocol.BotAgent, botUserInfo: UserInfo) {
    id = agent.id
    botUserId = agent.botUserID
    name = agent.name
    handle = agent.hasHandle ? agent.handle : nil
    emoji = agent.hasEmoji ? agent.emoji : nil
    description = agent.hasDescription_p ? agent.description_p : nil
    self.botUserInfo = botUserInfo
  }

  public var displayName: String {
    guard let emoji, !emoji.isEmpty else { return name }
    return "\(emoji) \(name)"
  }

  public var botDisplayName: String {
    botUserInfo.user.displayName
  }
}

/// Account-scoped, peer-filtered Agent identities. The server's existing
/// GetPeerBots access resolver is authoritative; this cache never invents
/// visibility and never stores harness instructions or skill keys.
@MainActor
public final class BotAgentDirectory {
  public static let shared = BotAgentDirectory()

  public typealias Fetcher = @Sendable (Peer) async throws -> InlineProtocol.GetPeerBotsResult
  public typealias UserInfoResolver = @MainActor (InlineProtocol.User) -> UserInfo

  private let fetcher: Fetcher
  private let userInfoResolver: UserInfoResolver
  private let isEnabled: @MainActor () -> Bool
  private let now: @MainActor () -> Date
  private let cacheTTL: TimeInterval
  private let maxCachedPeers: Int
  private var agentsByPeer: [Peer: [MentionableBotAgent]] = [:]
  private var botIdsByPeer: [Peer: Set<Int64>] = [:]
  private var cachedAtByPeer: [Peer: Date] = [:]
  private var peerAccessOrder: [Peer] = []
  private var inFlight: [Peer: Task<InlineProtocol.GetPeerBotsResult, Error>] = [:]
  private var generation: UInt = 0

  public convenience init() {
    self.init(
      fetcher: Self.fetchPeerBots,
      userInfoResolver: Self.resolveUserInfo,
      isEnabled: { ExperimentalFeatureFlags.mentionableAgentsEnabled },
      now: Date.init
    )
  }

  public init(
    fetcher: @escaping Fetcher,
    userInfoResolver: @escaping UserInfoResolver,
    isEnabled: @escaping @MainActor () -> Bool = { true },
    now: @escaping @MainActor () -> Date = Date.init,
    cacheTTL: TimeInterval = 60,
    maxCachedPeers: Int = 32
  ) {
    self.fetcher = fetcher
    self.userInfoResolver = userInfoResolver
    self.isEnabled = isEnabled
    self.now = now
    self.cacheTTL = cacheTTL
    self.maxCachedPeers = max(1, maxCachedPeers)
  }

  public func agents(for peer: Peer, forceRefresh: Bool = false) async throws -> [MentionableBotAgent] {
    guard isEnabled() else { return [] }
    if !forceRefresh, let cached = freshCachedAgents(for: peer) {
      return cached
    }
    let requestGeneration = generation
    if let task = inFlight[peer] {
      let result = try await task.value
      guard requestGeneration == generation, isEnabled() else { return [] }
      return store(result, for: peer)
    }

    let fetcher = fetcher
    let task = Task { try await fetcher(peer) }
    inFlight[peer] = task
    defer {
      if requestGeneration == generation {
        inFlight[peer] = nil
      }
    }
    let result = try await task.value
    guard requestGeneration == generation, isEnabled() else { return [] }
    return store(result, for: peer)
  }

  public func cached(agentId: Int64, botUserId: Int64, for peer: Peer) -> MentionableBotAgent? {
    guard isEnabled() else { return nil }
    return freshCachedAgents(for: peer)?.first { $0.id == agentId && $0.botUserId == botUserId }
  }

  public func invalidate(botUserId: Int64) {
    generation &+= 1
    inFlight.values.forEach { $0.cancel() }
    inFlight.removeAll()
    for peer in botIdsByPeer.compactMap({ $0.value.contains(botUserId) ? $0.key : nil }) {
      removeCachedPeer(peer)
    }
  }

  public func clear() {
    generation &+= 1
    inFlight.values.forEach { $0.cancel() }
    inFlight.removeAll()
    agentsByPeer.removeAll()
    botIdsByPeer.removeAll()
    cachedAtByPeer.removeAll()
    peerAccessOrder.removeAll()
  }

  private func store(
    _ result: InlineProtocol.GetPeerBotsResult,
    for peer: Peer
  ) -> [MentionableBotAgent] {
    botIdsByPeer[peer] = Set(result.bots.compactMap { $0.hasBot ? $0.bot.id : nil })
    let agents = result.bots.flatMap { peerBot -> [MentionableBotAgent] in
      guard peerBot.hasBot else { return [] }
      let userInfo = userInfoResolver(peerBot.bot)
      return peerBot.agents.map { MentionableBotAgent(profile: $0, botUserInfo: userInfo) }
    }
    agentsByPeer[peer] = agents
    cachedAtByPeer[peer] = now()
    touch(peer)
    while peerAccessOrder.count > maxCachedPeers, let expiredPeer = peerAccessOrder.first {
      removeCachedPeer(expiredPeer)
    }
    return agents
  }

  private func freshCachedAgents(for peer: Peer) -> [MentionableBotAgent]? {
    guard let agents = agentsByPeer[peer],
          let cachedAt = cachedAtByPeer[peer],
          now().timeIntervalSince(cachedAt) < cacheTTL
    else {
      removeCachedPeer(peer)
      return nil
    }
    touch(peer)
    return agents
  }

  private func touch(_ peer: Peer) {
    peerAccessOrder.removeAll { $0 == peer }
    peerAccessOrder.append(peer)
  }

  private func removeCachedPeer(_ peer: Peer) {
    agentsByPeer[peer] = nil
    botIdsByPeer[peer] = nil
    cachedAtByPeer[peer] = nil
    peerAccessOrder.removeAll { $0 == peer }
  }

  private static func fetchPeerBots(_ peer: Peer) async throws -> InlineProtocol.GetPeerBotsResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getPeerBots,
      input: .getPeerBots(.with { $0.peerID = peer.toInputPeer() })
    )
    guard case let .getPeerBots(result)? = response else {
      throw PeerBotCommandsViewModelError.invalidResponse
    }
    return result
  }

  private static func resolveUserInfo(_ user: InlineProtocol.User) -> UserInfo {
    ObjectCache.shared.getCachedUser(id: user.id) ?? UserInfo(user: User(from: user))
  }
}

public struct ManagedBotAgentDraft: Equatable, Sendable {
  public var name: String
  public var handle: String
  public var emoji: String
  public var description: String
  public var skillKey: String
  public var instructions: String

  public init(
    name: String = "",
    handle: String = "",
    emoji: String = "",
    description: String = "",
    skillKey: String = "",
    instructions: String = ""
  ) {
    self.name = name
    self.handle = handle
    self.emoji = emoji
    self.description = description
    self.skillKey = skillKey
    self.instructions = instructions
  }

  public init(agent: InlineProtocol.BotAgent) {
    name = agent.name
    handle = agent.hasHandle ? agent.handle : ""
    emoji = agent.hasEmoji ? agent.emoji : ""
    description = agent.hasDescription_p ? agent.description_p : ""
    skillKey = agent.hasSkillKey ? agent.skillKey : ""
    instructions = agent.hasInstructions ? agent.instructions : ""
  }
}

/// The single client update path for bot-owner Agent management. Ordinary
/// discovery intentionally stays on the sanitized BotAgentDirectory path.
@MainActor
@Observable
public final class BotAgentsSettingsModel {
  public private(set) var agents: [InlineProtocol.BotAgent] = []
  public private(set) var skills: [InlineProtocol.BotSkill] = []
  public private(set) var isLoading = false
  public private(set) var isLoadingSkills = false
  public private(set) var savingAgentId: Int64?
  public private(set) var deletingAgentIds: Set<Int64> = []
  public private(set) var errorMessage: String?

  public let botUserId: Int64
  @ObservationIgnored private let directory: BotAgentDirectory

  public init(botUserId: Int64, directory: BotAgentDirectory = .shared) {
    self.botUserId = botUserId
    self.directory = directory
  }

  public func load() async {
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let response = try await Api.realtime.callRpcDirect(
        method: .listBotAgents,
        input: .listBotAgents(.with { $0.botUserID = botUserId })
      )
      guard case let .listBotAgents(result)? = response else {
        throw PeerBotCommandsViewModelError.invalidResponse
      }
      agents = result.agents.sorted { $0.id < $1.id }
    } catch {
      errorMessage = "Could not load Skilled Agents."
    }

    await loadSkills()
  }

  public func loadSkills() async {
    guard !isLoadingSkills else { return }
    isLoadingSkills = true
    defer { isLoadingSkills = false }

    do {
      let response = try await Api.realtime.callRpcDirect(
        method: .getBotSkills,
        input: .getBotSkills(.with { $0.botUserID = botUserId })
      )
      guard case let .getBotSkills(result)? = response else {
        throw PeerBotCommandsViewModelError.invalidResponse
      }
      skills = result.skills.sorted {
        if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
        if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return $0.key < $1.key
      }
    } catch {
      skills = []
    }
  }

  @discardableResult
  public func save(_ draft: ManagedBotAgentDraft, agentId: Int64? = nil) async -> Bool {
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, savingAgentId == nil else { return false }
    savingAgentId = agentId ?? 0
    errorMessage = nil
    defer { savingAgentId = nil }

    do {
      let agent: InlineProtocol.BotAgent
      if let agentId {
        let response = try await Api.realtime.callRpcDirect(
          method: .updateBotAgent,
          input: .updateBotAgent(.with {
            $0.agentID = agentId
            $0.name = name
            $0.handle = Self.optionalValue(draft.handle)
            $0.emoji = Self.optionalValue(draft.emoji)
            $0.description_p = Self.optionalValue(draft.description)
            $0.skillKey = Self.optionalValue(draft.skillKey)
            $0.instructions = Self.optionalValue(draft.instructions)
          })
        )
        guard case let .updateBotAgent(result)? = response, result.hasAgent else {
          throw PeerBotCommandsViewModelError.invalidResponse
        }
        agent = result.agent
      } else {
        let response = try await Api.realtime.callRpcDirect(
          method: .createBotAgent,
          input: .createBotAgent(.with {
            $0.botUserID = botUserId
            $0.name = name
            if let value = Self.nonEmptyValue(draft.handle) { $0.handle = value }
            if let value = Self.nonEmptyValue(draft.emoji) { $0.emoji = value }
            if let value = Self.nonEmptyValue(draft.description) { $0.description_p = value }
            if let value = Self.nonEmptyValue(draft.skillKey) { $0.skillKey = value }
            if let value = Self.nonEmptyValue(draft.instructions) { $0.instructions = value }
          })
        )
        guard case let .createBotAgent(result)? = response, result.hasAgent else {
          throw PeerBotCommandsViewModelError.invalidResponse
        }
        agent = result.agent
      }

      agents.removeAll { $0.id == agent.id }
      agents.append(agent)
      agents.sort { $0.id < $1.id }
      directory.invalidate(botUserId: botUserId)
      NotificationCenter.default.post(name: .botAgentsChanged, object: botUserId)
      return true
    } catch {
      errorMessage = agentId == nil ? "Could not create the Skilled Agent." : "Could not update the Skilled Agent."
      return false
    }
  }

  @discardableResult
  public func delete(agentId: Int64) async -> Bool {
    guard deletingAgentIds.insert(agentId).inserted else { return false }
    errorMessage = nil
    defer { deletingAgentIds.remove(agentId) }

    do {
      let response = try await Api.realtime.callRpcDirect(
        method: .deleteBotAgent,
        input: .deleteBotAgent(.with { $0.agentID = agentId })
      )
      guard case let .deleteBotAgent(result)? = response, result.agentID == agentId else {
        throw PeerBotCommandsViewModelError.invalidResponse
      }
      agents.removeAll { $0.id == agentId }
      directory.invalidate(botUserId: botUserId)
      NotificationCenter.default.post(name: .botAgentsChanged, object: botUserId)
      return true
    } catch {
      errorMessage = "Could not delete the Skilled Agent."
      return false
    }
  }

  private static func nonEmptyValue(_ value: String) -> String? {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  private static func optionalValue(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public struct PeerBotCommandSuggestion: Identifiable, Hashable, Sendable {
  public let command: String
  public let description: String
  public let normalizedCommand: String
  public let botId: Int64
  public let botUsername: String?
  public let botDisplayName: String
  public let botUserInfo: UserInfo
  public let isAmbiguous: Bool

  public var id: String {
    "\(botId):\(normalizedCommand)"
  }

  public var botLabel: String? {
    guard let botUsername, !botUsername.isEmpty else { return nil }
    return "@\(botUsername)"
  }

  public var insertionText: String {
    if isAmbiguous, let botUsername, !botUsername.isEmpty {
      return "/\(command)@\(botUsername) "
    }
    return "/\(command) "
  }
}

@MainActor
@Observable
public final class PeerBotCommandsViewModel {
  public enum LoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
  }

  public typealias Fetcher = @Sendable (Peer) async throws -> [InlineProtocol.PeerBotCommands]
  public typealias UserInfoResolver = @MainActor (Int64, InlineProtocol.User) -> UserInfo

  public private(set) var peer: Peer
  public private(set) var loadState: LoadState = .idle
  public private(set) var botGroups: [InlineProtocol.PeerBotCommands] = []

  @ObservationIgnored private let fetcher: Fetcher
  @ObservationIgnored private let userInfoResolver: UserInfoResolver
  @ObservationIgnored private let log = Log.scoped("PeerBotCommandsViewModel")
  @ObservationIgnored private var cache: [Peer: [InlineProtocol.PeerBotCommands]] = [:]
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var loadGeneration = UUID()

  public init(peer: Peer, fetcher: @escaping Fetcher) {
    self.peer = peer
    self.fetcher = fetcher
    userInfoResolver = PeerBotCommandsViewModel.resolveUserInfo
  }

  public init(
    peer: Peer,
    fetcher: @escaping Fetcher,
    userInfoResolver: @escaping UserInfoResolver
  ) {
    self.peer = peer
    self.fetcher = fetcher
    self.userInfoResolver = userInfoResolver
  }

  public convenience init(peer: Peer) {
    self.init(peer: peer, fetcher: Self.fetchPeerBotCommands)
  }

  public var suggestions: [PeerBotCommandSuggestion] {
    Self.flattenSuggestions(from: botGroups, userInfoResolver: userInfoResolver)
  }

  deinit {
    loadTask?.cancel()
  }

  public var shouldAttemptLoad: Bool {
    switch loadState {
    case .idle, .failed:
      return true
    case .loading, .loaded:
      return false
    }
  }

  public func suggestions(matching query: String) -> [PeerBotCommandSuggestion] {
    let normalizedQuery = query
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()

    guard !normalizedQuery.isEmpty else {
      return suggestions
    }

    let parts = normalizedQuery.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
    let commandQuery = parts.first.map(String.init) ?? ""
    let botQuery = parts.count > 1 ? String(parts[1]) : nil

    return suggestions.filter { suggestion in
      let commandMatches = commandQuery.isEmpty || suggestion.normalizedCommand.contains(commandQuery)
      if let botQuery {
        guard commandMatches else { return false }
        return suggestion.botUsername?.lowercased().contains(botQuery) == true
      }

      if commandMatches {
        return true
      }

      let descriptionMatches = suggestion.description.lowercased().contains(normalizedQuery)
      let usernameMatches = suggestion.botUsername?.lowercased().contains(normalizedQuery) == true
      return descriptionMatches || usernameMatches
    }
  }

  public func ensureLoaded() async {
    if let loadTask {
      await loadTask.value
      return
    }

    if let cached = cache[peer] {
      botGroups = cached
      loadState = .loaded
      return
    }

    await startLoad(for: peer)
  }

  public func refresh() async {
    loadTask?.cancel()
    loadTask = nil
    loadGeneration = UUID()
    await startLoad(for: peer, forceRefresh: true)
  }

  public func setPeer(_ peer: Peer) {
    guard self.peer != peer else { return }

    loadTask?.cancel()
    loadTask = nil
    loadGeneration = UUID()
    self.peer = peer
    if let cached = cache[peer] {
      botGroups = cached
      loadState = .loaded
      return
    }

    botGroups = []
    loadState = .idle
  }

  private func startLoad(for peer: Peer, forceRefresh: Bool = false) async {
    let generation = UUID()
    loadGeneration = generation
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await fetchAndStore(for: peer, forceRefresh: forceRefresh, generation: generation)
    }
    loadTask = task
    await task.value
    if loadGeneration == generation {
      loadTask = nil
    }
  }

  private func fetchAndStore(
    for peer: Peer,
    forceRefresh: Bool = false,
    generation: UUID
  ) async {
    if !forceRefresh, let cached = cache[peer] {
      botGroups = cached
      loadState = .loaded
      return
    }

    loadState = .loading

    do {
      let groups = try await fetcher(peer)
      guard loadGeneration == generation, self.peer == peer else {
        return
      }

      cache[peer] = groups
      botGroups = groups
      loadState = .loaded
    } catch {
      if error is CancellationError {
        return
      }
      guard loadGeneration == generation, self.peer == peer else { return }
      log.error("Failed to fetch peer bot commands", error: error)
      loadState = .failed(String(describing: error))
    }
  }

  private static func fetchPeerBotCommands(for peer: Peer) async throws -> [InlineProtocol.PeerBotCommands] {
    let response = try await Api.realtime.callRpcDirect(
      method: .getPeerBotCommands,
      input: .getPeerBotCommands(.with {
        $0.peerID = peer.toInputPeer()
      })
    )

    guard case let .getPeerBotCommands(result)? = response else {
      throw PeerBotCommandsViewModelError.invalidResponse
    }

    return result.bots
  }

  private static func flattenSuggestions(
    from groups: [InlineProtocol.PeerBotCommands],
    userInfoResolver: UserInfoResolver
  ) -> [PeerBotCommandSuggestion] {
    var countsByNormalizedCommand: [String: Int] = [:]
    for group in groups {
      for command in group.commands {
        let normalized = command.command.lowercased()
        countsByNormalizedCommand[normalized, default: 0] += 1
      }
    }

    return groups.flatMap { group in
      let bot = group.bot
      let botUsername = bot.username.nilIfEmpty
      let botDisplayName = displayName(for: bot)
      let botUserInfo = userInfoResolver(bot.id, bot)

      return group.commands.map { command in
        let normalizedCommand = command.command.lowercased()
        return PeerBotCommandSuggestion(
          command: command.command,
          description: command.description_p,
          normalizedCommand: normalizedCommand,
          botId: bot.id,
          botUsername: botUsername,
          botDisplayName: botDisplayName,
          botUserInfo: botUserInfo,
          isAmbiguous: (countsByNormalizedCommand[normalizedCommand] ?? 0) > 1
        )
      }
    }
  }

  private static func resolveUserInfo(botId: Int64, fallbackProtocolUser: InlineProtocol.User) -> UserInfo {
    if let cached = ObjectCache.shared.getUser(id: botId) {
      return cached
    }
    return UserInfo(user: User(from: fallbackProtocolUser))
  }

  private static func displayName(for user: InlineProtocol.User) -> String {
    let explicit = [user.firstName.nilIfEmpty, user.lastName.nilIfEmpty]
      .compactMap { $0 }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !explicit.isEmpty {
      return explicit
    }
    if let username = user.username.nilIfEmpty {
      return "@\(username)"
    }
    return "Bot"
  }
}

private enum PeerBotCommandsViewModelError: Error {
  case invalidResponse
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
