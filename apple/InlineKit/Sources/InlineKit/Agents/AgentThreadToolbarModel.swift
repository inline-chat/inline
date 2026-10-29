import Combine
import Foundation
import GRDB
import InlineProtocol

public struct AgentThreadToolbarPresentation: Equatable {
  public let userInfo: UserInfo
  public let name: String
  public let botName: String
}

/// Cached, render-ready projection of the Chat's persisted Agent preset. The
/// toolbar view itself performs no database or network work.
@MainActor
public final class AgentThreadToolbarModel: ObservableObject {
  private struct Snapshot: Sendable {
    let chat: Chat?
    let bot: User?
  }

  private struct Identity: Equatable {
    let botUserID: Int64
    let agentID: Int64?
  }

  @Published public private(set) var presentation: AgentThreadToolbarPresentation?
  @Published public private(set) var catalog: AgentConfigurationCatalogSnapshot?
  @Published public private(set) var context: InlineProtocol.AgentThreadContext?
  @Published public private(set) var canEditProject = false
  @Published public private(set) var canEdit = false
  @Published public private(set) var editabilityResolved = false
  @Published public private(set) var isUpdating = false

  public let peer: Peer
  public let chatID: Int64

  private var observation: AnyDatabaseCancellable?
  private var loadTask: Task<Void, Never>?
  private var loadedIdentity: Identity?
  private var generation: UInt = 0

  public init(peer: Peer) {
    self.peer = peer
    chatID = peer.asThreadId() ?? 0
  }

  deinit {
    observation?.cancel()
    loadTask?.cancel()
  }

  public func start(database: AppDatabase) {
    cancel()
    guard chatID > 0 else { return }

    let chatID = chatID
    observation = ValueObservation.tracking { db in
      let chat = try Chat.fetchOne(db, id: chatID)
      let bot = try chat?.agentThreadContext.flatMap { context in
        try User.fetchOne(db, id: context.botUserID)
      }
      return Snapshot(chat: chat, bot: bot)
    }
    .start(
      in: database.reader,
      scheduling: .immediate,
      onError: { _ in },
      onChange: { [weak self] snapshot in
        // `.immediate` delivers the initial value synchronously on the main
        // queue; applying it in place lets the toolbar and Compose render the
        // thread's Agent on their first frame instead of after a hop.
        if Thread.isMainThread {
          MainActor.assumeIsolated { self?.apply(snapshot) }
        } else {
          Task { @MainActor [weak self] in
            self?.apply(snapshot)
          }
        }
      }
    )
  }

  public func cancel() {
    generation &+= 1
    observation?.cancel()
    observation = nil
    loadTask?.cancel()
    loadTask = nil
    loadedIdentity = nil
    presentation = nil
    catalog = nil
    context = nil
    canEditProject = false
    canEdit = false
    editabilityResolved = false
    isUpdating = false
  }

  public var explicitProjectID: String? {
    context?.configuration.hasProjectID == true ? context?.configuration.projectID : nil
  }

  public var explicitModelID: String? {
    context?.configuration.hasModelID == true ? context?.configuration.modelID : nil
  }

  public var explicitReasoningID: String? {
    context?.configuration.hasReasoningEffortID == true
      ? context?.configuration.reasoningEffortID
      : nil
  }

  public var effectiveProjectID: String? {
    explicitProjectID ?? catalog?.defaultProjectID
  }

  public var effectiveModelID: String? {
    explicitModelID ?? catalog?.defaultModelID
  }

  public var effectiveReasoningID: String? {
    explicitReasoningID ?? catalog?.defaultReasoningEffortID(forModelID: effectiveModelID)
  }

  public var projectTitle: String? {
    resolvedTitle(
      explicitID: explicitProjectID,
      effectiveID: effectiveProjectID,
      in: catalog?.projects
    )
  }

  public var modelTitle: String? {
    catalog?.modelTitle(forModelID: effectiveModelID) ?? explicitModelID
  }

  public var reasoningTitle: String? {
    resolvedTitle(
      explicitID: explicitReasoningID,
      effectiveID: effectiveReasoningID,
      in: availableReasoningOptions
    ) ?? (automaticReasoningTitle != nil ? String(localized: "Automatic") : nil)
  }

  public var automaticProjectTitle: String? {
    automaticTitle(catalog?.defaultProjectID, in: catalog?.projects)
  }

  public var automaticModelTitle: String? {
    catalog?.automaticModelTitle
  }

  public var automaticReasoningTitle: String? {
    catalog?.automaticReasoningTitle(forModelID: effectiveModelID)
      ?? (explicitReasoningID != nil ? String(localized: "Use default") : nil)
  }

  public var availableReasoningOptions: [AgentConfigurationOption]? {
    catalog?.reasoningOptions(forModelID: effectiveModelID)
  }

  public func contextSelectingProject(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    guard canEditProject, let id else { return nil }
    return updatedContext { $0.projectID = id }
  }

  public func contextSelectingModel(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    updatedContext { configuration in
      if let id { configuration.modelID = id } else { configuration.clearModelID() }
      let nextModelID = id ?? catalog?.defaultModelID
      if nextModelID != effectiveModelID,
         configuration.hasReasoningEffortID,
         let catalog,
         catalog.compatibleReasoningEffortID(configuration.reasoningEffortID, forModelID: nextModelID) == nil
      {
        configuration.clearReasoningEffortID()
      }
    }
  }

  public func contextSelectingReasoning(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    updatedContext { configuration in
      if let id {
        configuration.reasoningEffortID = id
      } else {
        configuration.clearReasoningEffortID()
      }
    }
  }

  public func performUpdate(
    _ nextContext: InlineProtocol.AgentThreadContext,
    using update: @escaping @Sendable (InlineProtocol.AgentThreadContext) async throws -> Void
  ) {
    guard canEdit, !isUpdating else { return }
    isUpdating = true
    Task { @MainActor [weak self] in
      defer { self?.isUpdating = false }
      do {
        try await update(nextContext)
      } catch {
        AgentControlErrors.report(String(localized: "Couldn’t update Agent settings."))
      }
    }
  }

  private func apply(_ snapshot: Snapshot) {
    guard let nextContext = snapshot.chat?.agentThreadContext else {
      resetBoundState()
      return
    }

    context = nextContext
    let identity = Identity(
      botUserID: nextContext.botUserID,
      agentID: nextContext.hasAgentID ? nextContext.agentID : nil
    )
    let fallbackInfo = snapshot.bot.map { UserInfo(user: $0) }
      ?? UserInfo.placeholder(id: identity.botUserID)
    if loadedIdentity != identity {
      // A Skilled Agent's display name is not the backing bot's display name.
      // Clear the old projection before resolving the exact target so the
      // toolbar never renders a knowingly incorrect identity for one frame.
      presentation = nil
    }
    if snapshot.bot == nil || loadedIdentity != identity || presentation == nil {
      presentation = AgentThreadToolbarPresentation(
        userInfo: fallbackInfo,
        name: snapshot.bot != nil && identity.agentID == nil
          ? fallbackInfo.user.displayName
          : "Unavailable",
        botName: snapshot.bot == nil ? "Unavailable" : fallbackInfo.user.displayName
      )
    }

    guard loadedIdentity != identity else { return }
    loadedIdentity = identity
    // The durable catalog row is tiny; reading it here keeps titles on the
    // first frame. The load below still refreshes it from the harness.
    catalog = AgentConfigurationCatalogStore.shared.cachedSnapshot(botUserID: identity.botUserID)
    canEditProject = false
    canEdit = false
    editabilityResolved = false
    generation &+= 1
    let requestGeneration = generation
    loadTask?.cancel()
    loadTask = Task { @MainActor [weak self] in
      await self?.load(identity: identity, generation: requestGeneration, fallback: fallbackInfo)
    }
  }

  private func resetBoundState() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
    loadedIdentity = nil
    presentation = nil
    catalog = nil
    context = nil
    canEditProject = false
    canEdit = false
    editabilityResolved = false
    isUpdating = false
  }

  private func load(identity: Identity, generation: UInt, fallback: UserInfo?) async {
    if let cached = await AgentConfigurationCatalogStore.shared.cached(botUserID: identity.botUserID),
       isCurrent(identity, generation: generation)
    {
      catalog = cached
    }

    if let peerBots = try? await fetchPeerBots(), isCurrent(identity, generation: generation),
       let peerBot = peerBots.bots.first(where: { $0.hasBot && $0.bot.id == identity.botUserID })
    {
      let userInfo = ObjectCache.shared.getCachedUser(id: identity.botUserID)
        ?? UserInfo(user: User(from: peerBot.bot))
      if let agentID = identity.agentID {
        if let agentName = peerBot.agents.first(where: { $0.id == agentID })?.name,
           let name = Self.nonEmpty(agentName)
        {
          presentation = AgentThreadToolbarPresentation(
            userInfo: userInfo,
            name: name,
            botName: userInfo.user.displayName
          )
        }
      } else {
        presentation = AgentThreadToolbarPresentation(
          userInfo: userInfo,
          name: userInfo.user.displayName,
          botName: userInfo.user.displayName
        )
      }
    } else if identity.agentID == nil,
              isCurrent(identity, generation: generation),
              presentation == nil,
              let fallback
    {
      presentation = AgentThreadToolbarPresentation(
        userInfo: fallback,
        name: fallback.user.displayName,
        botName: fallback.user.displayName
      )
    }

    if let ownedBotIDs = try? await fetchOwnedBotIDs(),
       isCurrent(identity, generation: generation)
    {
      canEdit = ownedBotIDs.contains(identity.botUserID)
      editabilityResolved = true
    }

    if canEdit,
       let response = try? await Api.realtime.callRpcDirect(
         method: .getAgentSession,
         input: .getAgentSession(.with {
           $0.peerID = peer.toInputPeer()
           $0.botUserID = identity.botUserID
         })
       ),
       case let .getAgentSession(result) = response,
       isCurrent(identity, generation: generation)
    {
      canEditProject = !result.hasConnection
    }

    do {
      let refreshed = try await AgentConfigurationCatalogStore.shared.refresh(
        botUserID: identity.botUserID,
        peer: peer
      )
      if let refreshed, isCurrent(identity, generation: generation) {
        catalog = refreshed
      }
    } catch {
      // A failed refresh leaves the last validated cached catalog visible.
    }
  }

  private func fetchPeerBots() async throws -> InlineProtocol.GetPeerBotsResult {
    let response = try await Api.realtime.callRpcDirect(
      method: .getPeerBots,
      input: .getPeerBots(.with { $0.peerID = peer.toInputPeer() })
    )
    guard case let .getPeerBots(result)? = response else {
      throw AgentConfigurationCatalogError.invalidResponse
    }
    return result
  }

  private func fetchOwnedBotIDs() async throws -> Set<Int64> {
    let response = try await Api.realtime.callRpcDirect(
      method: .listBots,
      input: .listBots(.with { _ in })
    )
    guard case let .listBots(result)? = response else {
      throw AgentConfigurationCatalogError.invalidResponse
    }
    return Set(result.bots.map(\.id))
  }

  private func isCurrent(_ identity: Identity, generation: UInt) -> Bool {
    !Task.isCancelled && generation == self.generation && identity == loadedIdentity
  }

  private func updatedContext(
    _ update: (inout InlineProtocol.AgentThreadConfiguration) -> Void
  ) -> InlineProtocol.AgentThreadContext? {
    guard canEdit, !isUpdating, var next = context else { return nil }
    var configuration = next.hasConfiguration
      ? next.configuration
      : InlineProtocol.AgentThreadConfiguration()
    update(&configuration)
    if configuration.hasProjectID || configuration.hasModelID || configuration.hasReasoningEffortID {
      next.configuration = configuration
    } else {
      next.clearConfiguration()
    }
    return next
  }

  private func resolvedTitle(
    explicitID: String?,
    effectiveID: String?,
    in options: [AgentConfigurationOption]?
  ) -> String? {
    guard let effectiveID else { return nil }
    return options?.first(where: { $0.id == effectiveID })?.label
      ?? (explicitID == nil ? nil : "Unavailable")
  }

  private func automaticTitle(
    _ id: String?,
    in options: [AgentConfigurationOption]?
  ) -> String? {
    guard let id, let label = options?.first(where: { $0.id == id })?.label else { return nil }
    return Self.automaticTitle(label)
  }

  private static func automaticTitle(_ label: String) -> String {
    String(
      localized: "Use default — \(label)",
      comment:
        "Reset label for an Agent setting. The variable is the current harness-selected option name."
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}
