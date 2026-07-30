import Combine
import Foundation
import GRDB
import InlineProtocol
import Logger
import Observation
import RealtimeV2

public struct BotChatSettingsBot: Equatable, Identifiable, Sendable {
  public let id: Int64
  public let user: InlineProtocol.User

  public init(user: InlineProtocol.User) {
    id = user.id
    self.user = user
  }

  public var displayName: String {
    let name = [user.firstName.nilIfEmpty, user.lastName.nilIfEmpty]
      .compactMap { $0 }
      .joined(separator: " ")
    return name.nilIfEmpty ?? username.map { "@\($0)" } ?? "Bot"
  }

  public var username: String? { user.username.nilIfEmpty }
}

public enum BotChatSettingsPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded
  case unavailable
}

public enum BotChatSettingsProblem: Equatable, Sendable {
  case unreachable
  case failed(String)

  public var message: String {
    switch self {
    case .unreachable: "Bot unreachable"
    case let .failed(message): message
    }
  }
}

public struct BotChatSettingsBotState: Equatable, Sendable {
  public var phase: BotChatSettingsPhase = .idle
  public var document: BotChatSettingsModel.Document?
  public var isRefreshing = false
  public var isMutating = false
  public var pendingItemID: String?
  public var pendingItemIDs: Set<String> = []
  public var problem: BotChatSettingsProblem?
  public var lastUpdatedAt: Date?

  public init() {}
}

private struct BotChatSettingsQueuedMutation: Equatable, Sendable {
  let traceID: Int
  let botID: Int64
  let itemID: String
  var value: BotChatSettingsMutationValue?
  var staleRetryCount = 0
  var transportRetryCount = 0
}

@MainActor
@Observable
public final class BotChatSettingsCoordinator {
  public typealias DiscoveryFetcher = @Sendable (Peer) async throws -> InlineProtocol.GetPeerBotsResult
  public typealias SettingsRequester = @Sendable (Peer, Int64) async throws -> InlineProtocol.BotChatSettingsResponse
  public typealias ItemInvoker = @Sendable (
    Peer,
    Int64,
    String,
    BotChatSettingsMutationValue?,
    String
  ) async throws -> InlineProtocol.BotChatSettingsResponse

  public let peer: Peer
  public private(set) var bots: [BotChatSettingsBot] = []
  public private(set) var selectedBotID: Int64?
  public private(set) var isDiscovering = false
  public private(set) var isMutating = false

  @ObservationIgnored private let discoveryFetcher: DiscoveryFetcher
  @ObservationIgnored private let settingsRequester: SettingsRequester
  @ObservationIgnored private let itemInvoker: ItemInvoker
  @ObservationIgnored private let retryDelays: [Duration]
  @ObservationIgnored private let transientMutationRetryDelay: Duration
  @ObservationIgnored private let log = Log.scoped("BotChatSettingsCoordinator")
  private var stateByBotID: [Int64: BotChatSettingsBotState] = [:]
  @ObservationIgnored private var didManuallySelectBot = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var discoveryGeneration = 0
  @ObservationIgnored private var discoveryTask: Task<Void, Never>?
  @ObservationIgnored private var retryTask: Task<Void, Never>?
  @ObservationIgnored private var requestTask: Task<Void, Never>?
  @ObservationIgnored private var requestBotID: Int64?
  @ObservationIgnored private var mutationTask: Task<Void, Never>?
  @ObservationIgnored private var activeMutation: BotChatSettingsQueuedMutation?
  @ObservationIgnored private var mutationQueue: [BotChatSettingsQueuedMutation] = []
  @ObservationIgnored private var confirmedDocumentByBotID: [Int64: BotChatSettingsModel.Document] = [:]
  @ObservationIgnored private var discoveryObservation: AnyCancellable?
  @ObservationIgnored private var hasReceivedDiscoverySnapshot = false
  @ObservationIgnored private var nextTraceID = 1
  // TODO(bot-chat-settings): observe bot-initiated capability and document invalidations after V1.

  public convenience init(peer: Peer, realtime: RealtimeV2 = Api.realtime) {
    self.init(
      peer: peer,
      discoveryFetcher: { try await Self.fetchPeerBots($0, realtime: realtime) },
      settingsRequester: { try await Self.requestSettings($0, botID: $1, realtime: realtime) },
      itemInvoker: { try await Self.invokeItem($0, botID: $1, itemID: $2, value: $3, revision: $4, realtime: realtime) },
      retryDelays: [.milliseconds(500), .seconds(2), .seconds(5), .seconds(10)],
      transientMutationRetryDelay: .milliseconds(750)
    )
  }

  public init(
    peer: Peer,
    discoveryFetcher: @escaping DiscoveryFetcher,
    settingsRequester: @escaping SettingsRequester,
    itemInvoker: @escaping ItemInvoker,
    retryDelays: [Duration] = [],
    transientMutationRetryDelay: Duration = .milliseconds(750)
  ) {
    self.peer = peer
    self.discoveryFetcher = discoveryFetcher
    self.settingsRequester = settingsRequester
    self.itemInvoker = itemInvoker
    self.retryDelays = retryDelays
    self.transientMutationRetryDelay = transientMutationRetryDelay
  }

  public var isToolbarVisible: Bool { !bots.isEmpty }
  public var selectedBot: BotChatSettingsBot? {
    guard let selectedBotID else { return nil }
    return bots.first(where: { $0.id == selectedBotID })
  }
  public var selectedState: BotChatSettingsBotState {
    guard let selectedBotID else { return .init() }
    return stateByBotID[selectedBotID] ?? .init()
  }

  public func warmUp() async {
    retryTask?.cancel()
    await discover(scheduleRetry: true)
  }

  public func startObservingDiscoveryScope(in database: AppDatabase) {
    discoveryObservation?.cancel()
    hasReceivedDiscoverySnapshot = false
    database.warnIfInMemoryDatabaseForObservation("BotChatSettingsCoordinator.discoveryScope")
    discoveryObservation = ValueObservation
      .tracking { [peer] db in try BotChatSettingsDiscoverySnapshot.fetch(db, peer: peer) }
      .removeDuplicates()
      .publisher(in: database.dbWriter, scheduling: .immediate)
      .sink(
        receiveCompletion: { [weak self] completion in
          guard case let .failure(error) = completion else { return }
          Task { @MainActor [weak self] in self?.log.error("Discovery observation failed", error: error) }
        },
        receiveValue: { [weak self] _ in
          Task { @MainActor [weak self] in
            guard let self else { return }
            if self.hasReceivedDiscoverySnapshot { self.invalidateDiscovery() }
            self.hasReceivedDiscoverySnapshot = true
          }
        }
      )
  }

  public func invalidateDiscovery() {
    retryTask?.cancel()
    discoveryTask?.cancel()
    discoveryTask = Task { [weak self] in await self?.discover(scheduleRetry: true) }
  }

  public func selectBot(_ botID: Int64) {
    guard bots.contains(where: { $0.id == botID }) else { return }
    didManuallySelectBot = true
    selectedBotID = botID
    refreshSelectedIfStale()
  }

  public func refreshSelected() {
    guard let selectedBotID, !hasPendingMutation(for: selectedBotID) else { return }
    startRequest(botID: selectedBotID)
  }

  public func refreshSelectedIfStale(maxAge: TimeInterval = 15) {
    guard let selectedBotID, !hasPendingMutation(for: selectedBotID) else { return }
    let state = stateByBotID[selectedBotID]
    if let lastUpdatedAt = state?.lastUpdatedAt,
       state?.document != nil,
       Date().timeIntervalSince(lastUpdatedAt) < maxAge {
      return
    }
    startRequest(botID: selectedBotID)
  }

  public func invoke(itemID: String, value: BotChatSettingsMutationValue?) {
    guard let botID = selectedBotID,
          var state = stateByBotID[botID],
          let document = state.document,
          let optimisticDocument = document.applyingOptimisticMutation(itemID: itemID, value: value)
    else { return }

    if requestBotID == botID {
      requestTask?.cancel()
      requestTask = nil
      requestBotID = nil
    }
    state.document = optimisticDocument
    state.isRefreshing = false
    state.problem = nil
    stateByBotID[botID] = state

    let mutation = BotChatSettingsQueuedMutation(
      traceID: makeTraceID(),
      botID: botID,
      itemID: itemID,
      value: value
    )
    var coalesced = false
    if let queuedIndex = mutationQueue.lastIndex(where: { $0.botID == botID && $0.itemID == itemID }) {
      mutationQueue[queuedIndex] = mutation
      coalesced = true
    } else {
      mutationQueue.append(mutation)
    }
    log.debug(
      "BOT_SETTINGS_TRACE trace=\(mutation.traceID) phase=mutation_queued peer=\(peerTrace) " +
        "bot=\(botID) item=\(itemID) coalesced=\(coalesced ? 1 : 0) queue=\(mutationQueue.count)"
    )
    rebuildPresentation(for: botID)
    startNextMutationIfNeeded()
  }

  private func startNextMutationIfNeeded() {
    guard mutationTask == nil, activeMutation == nil, !mutationQueue.isEmpty else { return }
    let mutation = mutationQueue.removeFirst()
    guard let revision = confirmedDocumentByBotID[mutation.botID]?.revision else {
      finishQueuedMutation(
        mutation,
        problem: .failed("Reload settings and try again")
      )
      startNextMutationIfNeeded()
      return
    }

    activeMutation = mutation
    syncMutationState()
    rebuildPresentation(for: mutation.botID)
    let currentGeneration = generation
    let peer = peer
    let invoker = itemInvoker
    let startedAt = Date()
    log.debug(
      "BOT_SETTINGS_TRACE trace=\(mutation.traceID) phase=mutation_start peer=\(peerTrace) " +
        "bot=\(mutation.botID) item=\(mutation.itemID) retry=\(mutation.staleRetryCount)"
    )
    mutationTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await invoker(
          peer,
          mutation.botID,
          mutation.itemID,
          mutation.value,
          revision
        )
        guard currentGeneration == self.generation, !Task.isCancelled else { return }
        self.log.debug(
          "BOT_SETTINGS_TRACE trace=\(mutation.traceID) phase=mutation_response " +
            "bot=\(mutation.botID) item=\(mutation.itemID) result=\(Self.traceResult(response)) " +
            "elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        self.mutationTask = nil
        self.activeMutation = nil
        self.applyMutationResponse(response, mutation: mutation)
      } catch is CancellationError {
      } catch {
        guard currentGeneration == self.generation else { return }
        if mutation.value != nil, mutation.transportRetryCount == 0 {
          var retry = mutation
          retry.transportRetryCount += 1
          self.log.debug(
            "BOT_SETTINGS_TRACE trace=\(mutation.traceID) phase=mutation_transport_retry " +
              "bot=\(mutation.botID) item=\(mutation.itemID) retry=\(retry.transportRetryCount)"
          )
          do {
            try await Task.sleep(for: self.transientMutationRetryDelay)
          } catch {
            return
          }
          guard currentGeneration == self.generation, !Task.isCancelled else { return }
          self.mutationTask = nil
          self.activeMutation = nil
          let hasNewerValue = self.mutationQueue.contains {
            $0.botID == mutation.botID && $0.itemID == mutation.itemID
          }
          if !hasNewerValue {
            self.mutationQueue.insert(retry, at: 0)
          }
          self.rebuildPresentation(for: mutation.botID)
          self.syncMutationState()
          self.startNextMutationIfNeeded()
          return
        }
        self.log.debug(
          "BOT_SETTINGS_TRACE trace=\(mutation.traceID) phase=mutation_error " +
            "bot=\(mutation.botID) item=\(mutation.itemID) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        self.mutationTask = nil
        self.activeMutation = nil
        self.finishQueuedMutation(mutation, problem: .failed("Couldn’t update bot settings"))
      }
      self.startNextMutationIfNeeded()
    }
  }

  public func cancel() {
    generation += 1
    discoveryGeneration += 1
    discoveryTask?.cancel()
    retryTask?.cancel()
    requestTask?.cancel()
    mutationTask?.cancel()
    discoveryObservation?.cancel()
    discoveryTask = nil
    retryTask = nil
    requestTask = nil
    requestBotID = nil
    mutationTask = nil
    activeMutation = nil
    mutationQueue = []
    isMutating = false
    for botID in Array(stateByBotID.keys) {
      if let confirmedDocument = confirmedDocumentByBotID[botID] {
        stateByBotID[botID]?.document = confirmedDocument
      }
      stateByBotID[botID]?.isMutating = false
      stateByBotID[botID]?.pendingItemID = nil
      stateByBotID[botID]?.pendingItemIDs = []
    }
    discoveryObservation = nil
  }

  private func discover(scheduleRetry: Bool) async {
    discoveryGeneration += 1
    let currentDiscoveryGeneration = discoveryGeneration
    let traceID = makeTraceID()
    let startedAt = Date()
    log.debug("BOT_SETTINGS_TRACE trace=\(traceID) phase=discovery_start peer=\(peerTrace)")
    isDiscovering = true
    do {
      let result = try await discoveryFetcher(peer)
      guard currentDiscoveryGeneration == discoveryGeneration, !Task.isCancelled else { return }
      let compatible = result.bots.compactMap { peerBot -> BotChatSettingsBot? in
        guard peerBot.hasBot,
              peerBot.capabilities.contains(where: { $0.kind == .chatSettings && $0.version == 1 })
        else { return nil }
        return BotChatSettingsBot(user: peerBot.bot)
      }
      applyDiscoveredBots(
        compatible,
        suggestedBotID: result.hasSuggestedBotUserID ? result.suggestedBotUserID : nil
      )
      log.debug(
        "BOT_SETTINGS_TRACE trace=\(traceID) phase=discovery_response peer=\(peerTrace) " +
          "bots=\(compatible.count) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
      )
      isDiscovering = false
      if compatible.isEmpty {
        if scheduleRetry { scheduleDiscoveryRetry() }
      } else {
        retryTask?.cancel()
        refreshSelected()
      }
    } catch {
      guard currentDiscoveryGeneration == discoveryGeneration, !Task.isCancelled else { return }
      isDiscovering = false
      log.error("Failed to discover bot settings", error: error)
      if scheduleRetry { scheduleDiscoveryRetry() }
    }
  }

  private func applyDiscoveredBots(_ compatible: [BotChatSettingsBot], suggestedBotID: Int64?) {
    let compatibleIDs = Set(compatible.map(\.id))
    let removedIDs = Set(bots.map(\.id)).subtracting(compatibleIDs)
    if let activeMutation, removedIDs.contains(activeMutation.botID) {
      mutationTask?.cancel()
      mutationTask = nil
      self.activeMutation = nil
    }
    for removedID in removedIDs {
      stateByBotID[removedID] = nil
      confirmedDocumentByBotID[removedID] = nil
      mutationQueue.removeAll(where: { $0.botID == removedID })
    }
    syncMutationState()
    startNextMutationIfNeeded()
    bots = compatible
    guard let fallback = compatible.first?.id else {
      selectedBotID = nil
      return
    }
    if didManuallySelectBot, selectedBotID.map(compatibleIDs.contains) == true { return }
    selectedBotID = suggestedBotID.flatMap { compatibleIDs.contains($0) ? $0 : nil } ?? fallback
  }

  private func scheduleDiscoveryRetry() {
    guard !retryDelays.isEmpty else { return }
    retryTask?.cancel()
    let currentGeneration = generation
    retryTask = Task { [weak self] in
      guard let self else { return }
      for delay in self.retryDelays {
        do { try await Task.sleep(for: delay) } catch { return }
        guard currentGeneration == self.generation, !Task.isCancelled else { return }
        await self.discover(scheduleRetry: false)
        if !self.bots.isEmpty { return }
      }
      self.retryTask = nil
    }
  }

  private func startRequest(botID: Int64) {
    guard bots.contains(where: { $0.id == botID }) else { return }
    guard requestTask == nil || requestBotID != botID else { return }
    requestTask?.cancel()
    requestBotID = botID
    var state = stateByBotID[botID] ?? .init()
    state.phase = state.document == nil ? .loading : .loaded
    state.isRefreshing = state.document != nil
    state.problem = nil
    stateByBotID[botID] = state
    let currentGeneration = generation
    let peer = peer
    let requester = settingsRequester
    let traceID = makeTraceID()
    let startedAt = Date()
    log.debug(
      "BOT_SETTINGS_TRACE trace=\(traceID) phase=request_start peer=\(peerTrace) bot=\(botID) " +
        "has_snapshot=\(state.document == nil ? 0 : 1)"
    )
    requestTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await requester(peer, botID)
        guard currentGeneration == self.generation, !Task.isCancelled else { return }
        self.log.debug(
          "BOT_SETTINGS_TRACE trace=\(traceID) phase=request_response bot=\(botID) " +
            "result=\(Self.traceResult(response)) elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        self.requestTask = nil
        self.requestBotID = nil
        self.applyRequestResponse(response, botID: botID)
      } catch is CancellationError {
      } catch {
        guard currentGeneration == self.generation else { return }
        self.log.debug(
          "BOT_SETTINGS_TRACE trace=\(traceID) phase=request_error bot=\(botID) " +
            "elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))"
        )
        self.finishRequest(botID: botID, problem: .failed("Couldn’t load bot settings"))
      }
    }
  }

  private func applyRequestResponse(_ response: InlineProtocol.BotChatSettingsResponse, botID: Int64) {
    var state = stateByBotID[botID] ?? .init()
    state.isRefreshing = false

    switch response.result {
    case let .document(protocolDocument):
      if let document = parseDocument(protocolDocument) {
        confirmedDocumentByBotID[botID] = document
        state.lastUpdatedAt = Date()
        state.problem = nil
      } else {
        state.problem = .failed("Bot returned invalid settings")
      }
    case let .problem(problem):
      if problem.hasCurrentDocument, let document = parseDocument(problem.currentDocument) {
        confirmedDocumentByBotID[botID] = document
        state.lastUpdatedAt = Date()
      }
      switch problem.code {
      case .unreachable:
        state.problem = .unreachable
      default:
        state.problem = .failed(problem.message.nilIfEmpty ?? "Bot settings request failed")
      }
    case nil:
      state.problem = .failed("Bot returned an invalid response")
    }
    stateByBotID[botID] = state
    rebuildPresentation(for: botID)
  }

  private func applyMutationResponse(
    _ response: InlineProtocol.BotChatSettingsResponse,
    mutation: BotChatSettingsQueuedMutation
  ) {
    var state = stateByBotID[mutation.botID] ?? .init()
    var responseProblem: BotChatSettingsProblem?

    switch response.result {
    case let .document(protocolDocument):
      if let document = parseDocument(protocolDocument) {
        confirmedDocumentByBotID[mutation.botID] = document
        state.lastUpdatedAt = Date()
        state.problem = nil
      } else {
        responseProblem = .failed("Bot returned invalid settings")
      }
    case let .problem(problem):
      var hasCurrentDocument = false
      if problem.hasCurrentDocument, let document = parseDocument(problem.currentDocument) {
        confirmedDocumentByBotID[mutation.botID] = document
        state.lastUpdatedAt = Date()
        hasCurrentDocument = true
      }
      if problem.code == .stale, hasCurrentDocument, mutation.staleRetryCount == 0 {
        var retry = mutation
        retry.staleRetryCount += 1
        mutationQueue.insert(retry, at: 0)
        log.debug(
          "BOT_SETTINGS_TRACE trace=\(mutation.traceID) phase=mutation_rebase " +
            "bot=\(mutation.botID) item=\(mutation.itemID) retry=\(retry.staleRetryCount)"
        )
      } else if problem.code == .unreachable {
        responseProblem = .unreachable
      } else {
        responseProblem = .failed(problem.message.nilIfEmpty ?? "Couldn’t update bot settings")
      }
    case nil:
      responseProblem = .failed("Bot returned an invalid response")
    }
    stateByBotID[mutation.botID] = state
    finishQueuedMutation(mutation, problem: responseProblem)
  }

  private func parseDocument(
    _ protocolDocument: InlineProtocol.BotChatSettingsDocument
  ) -> BotChatSettingsModel.Document? {
    do {
      return try BotChatSettingsModel.Document(protocolDocument: protocolDocument)
    } catch {
      log.error("Rejected invalid bot settings document", error: error)
      return nil
    }
  }

  private func finishQueuedMutation(
    _ mutation: BotChatSettingsQueuedMutation,
    problem: BotChatSettingsProblem?
  ) {
    if let problem { stateByBotID[mutation.botID]?.problem = problem }
    rebuildPresentation(for: mutation.botID)
    syncMutationState()
  }

  private func rebuildPresentation(for botID: Int64) {
    var state = stateByBotID[botID] ?? .init()
    var document = confirmedDocumentByBotID[botID]
    let pendingMutations = [activeMutation].compactMap { $0 } + mutationQueue
    let botMutations = pendingMutations.filter { $0.botID == botID }
    for mutation in botMutations {
      guard let nextDocument = document?.applyingOptimisticMutation(
        itemID: mutation.itemID,
        value: mutation.value
      ) else { continue }
      document = nextDocument
    }
    state.document = document.flatMap { $0.sections.isEmpty ? nil : $0 }
    state.phase = state.document == nil ? .unavailable : .loaded
    state.pendingItemIDs = Set(botMutations.map(\.itemID))
    state.pendingItemID = botMutations.first?.itemID
    state.isMutating = !botMutations.isEmpty
    stateByBotID[botID] = state
  }

  private func hasPendingMutation(for botID: Int64) -> Bool {
    activeMutation?.botID == botID || mutationQueue.contains(where: { $0.botID == botID })
  }

  private func syncMutationState() {
    isMutating = activeMutation != nil || !mutationQueue.isEmpty
  }

  private var peerTrace: String {
    switch peer {
    case let .user(userID): "user:\(userID)"
    case let .thread(chatID): "chat:\(chatID)"
    }
  }

  private func makeTraceID() -> Int {
    defer { nextTraceID += 1 }
    return nextTraceID
  }

  private static func elapsedMilliseconds(since date: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(date) * 1_000))
  }

  private static func traceResult(_ response: InlineProtocol.BotChatSettingsResponse) -> String {
    switch response.result {
    case .document: "document"
    case let .problem(problem): "problem:\(problem.code)"
    case nil: "invalid"
    }
  }

  private func finishRequest(botID: Int64, problem: BotChatSettingsProblem) {
    requestTask = nil
    requestBotID = nil
    var state = stateByBotID[botID] ?? .init()
    state.isRefreshing = false
    state.phase = state.document == nil ? .unavailable : .loaded
    state.problem = problem
    stateByBotID[botID] = state
  }

  private static func fetchPeerBots(_ peer: Peer, realtime: RealtimeV2) async throws -> InlineProtocol.GetPeerBotsResult {
    let response = try await realtime.callRpcDirect(
      method: .getPeerBots,
      input: .getPeerBots(.with { $0.peerID = peer.toInputPeer() })
    )
    guard case let .getPeerBots(result)? = response else { throw BotChatSettingsCoordinatorError.invalidResponse }
    return result
  }

  private static func requestSettings(
    _ peer: Peer,
    botID: Int64,
    realtime: RealtimeV2
  ) async throws -> InlineProtocol.BotChatSettingsResponse {
    let response = try await realtime.callRpcDirect(
      method: .requestBotChatSettings,
      input: .requestBotChatSettings(.with {
        $0.peerID = peer.toInputPeer()
        $0.botUserID = botID
        $0.version = 1
      })
    )
    guard case let .requestBotChatSettings(result)? = response, result.hasResponse else {
      throw BotChatSettingsCoordinatorError.invalidResponse
    }
    return result.response
  }

  private static func invokeItem(
    _ peer: Peer,
    botID: Int64,
    itemID: String,
    value: BotChatSettingsMutationValue?,
    revision: String,
    realtime: RealtimeV2
  ) async throws -> InlineProtocol.BotChatSettingsResponse {
    let response = try await realtime.callRpcDirect(
      method: .invokeBotChatSettingsItem,
      input: .invokeBotChatSettingsItem(.with {
        $0.peerID = peer.toInputPeer()
        $0.botUserID = botID
        $0.version = 1
        $0.itemID = itemID
        if let value { $0.value = value.protocolValue }
        $0.documentRevision = revision
      })
    )
    guard case let .invokeBotChatSettingsItem(result)? = response, result.hasResponse else {
      throw BotChatSettingsCoordinatorError.invalidResponse
    }
    return result.response
  }
}

private enum BotChatSettingsCoordinatorError: Error { case invalidResponse }

private struct BotChatSettingsDiscoverySnapshot: Equatable, Sendable {
  let signature: [Int64]

  static func fetch(_ db: Database, peer: Peer) throws -> Self {
    switch peer {
    case let .user(userID):
      let user = try User.fetchOne(db, id: userID)
      return Self(signature: [userID, user?.bot == true ? 1 : 0])
    case let .thread(chatID):
      var signature: [Int64] = []
      var nextChatID: Int64? = chatID
      var visited = Set<Int64>()
      while let currentChatID = nextChatID, visited.insert(currentChatID).inserted {
        guard let chat = try Chat.fetchOne(db, id: currentChatID) else { break }
        signature.append(contentsOf: [chat.id, chat.parentChatId ?? 0, chat.spaceId ?? 0, chat.isPublic == true ? 1 : 0])
        let participantIDs = try ChatParticipant
          .filter(ChatParticipant.Columns.chatId == chat.id)
          .order(ChatParticipant.Columns.userId)
          .fetchAll(db)
          .map(\.userId)
        signature.append(contentsOf: participantIDs)
        try appendBotFlags(for: participantIDs, db: db, to: &signature)
        if chat.isPublic == true, let spaceID = chat.spaceId {
          let memberIDs = try Member
            .filter(Member.Columns.spaceId == spaceID)
            .filter(Member.Columns.canAccessPublicChats == true)
            .order(Member.Columns.userId)
            .fetchAll(db)
            .map(\.userId)
          signature.append(contentsOf: memberIDs)
          try appendBotFlags(for: memberIDs, db: db, to: &signature)
        }
        nextChatID = chat.parentChatId
      }
      return Self(signature: signature)
    }
  }

  private static func appendBotFlags(for userIDs: [Int64], db: Database, to signature: inout [Int64]) throws {
    guard !userIDs.isEmpty else { return }
    for user in try User.filter(userIDs.contains(User.Columns.id)).order(User.Columns.id).fetchAll(db) {
      signature.append(contentsOf: [user.id, user.bot ? 1 : 0])
    }
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
