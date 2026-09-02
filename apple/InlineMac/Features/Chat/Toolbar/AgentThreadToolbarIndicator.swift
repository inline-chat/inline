import Combine
import GRDB
import InlineKit
import InlineProtocol
import InlineUI
import SwiftUI

struct AgentThreadToolbarPresentation: Equatable {
  let userInfo: UserInfo
  let name: String
  let botName: String
}

/// Cached, render-ready projection of the Chat's persisted Agent preset. The
/// toolbar view itself performs no database or network work.
@MainActor
final class AgentThreadToolbarModel: ObservableObject {
  private struct Snapshot {
    let chat: InlineKit.Chat?
    let bot: InlineKit.User?
  }

  private struct Identity: Equatable {
    let botUserID: Int64
    let agentID: Int64?
  }

  @Published private(set) var presentation: AgentThreadToolbarPresentation?
  @Published private(set) var catalog: AgentConfigurationCatalogSnapshot?
  @Published private(set) var context: InlineProtocol.AgentThreadContext?
  @Published private(set) var canEdit = false
  @Published private(set) var isUpdating = false

  let peer: InlineKit.Peer
  let chatID: Int64

  private var observation: AnyDatabaseCancellable?
  private var loadTask: Task<Void, Never>?
  private var loadedIdentity: Identity?
  private var generation: UInt = 0

  init(peer: InlineKit.Peer) {
    self.peer = peer
    chatID = peer.asThreadId() ?? 0
  }

  deinit {
    observation?.cancel()
    loadTask?.cancel()
  }

  func start(database: AppDatabase) {
    cancel()
    guard chatID > 0 else { return }

    let chatID = chatID
    observation = ValueObservation.tracking { db in
      let chat = try InlineKit.Chat.fetchOne(db, id: chatID)
      let bot = try chat?.agentThreadContext.flatMap { context in
        try InlineKit.User.fetchOne(db, id: context.botUserID)
      }
      return Snapshot(chat: chat, bot: bot)
    }
    .start(
      in: database.reader,
      scheduling: .immediate,
      onError: { _ in },
      onChange: { [weak self] snapshot in
        Task { @MainActor [weak self] in
          self?.apply(snapshot)
        }
      }
    )
  }

  func cancel() {
    generation &+= 1
    observation?.cancel()
    observation = nil
    loadTask?.cancel()
    loadTask = nil
    loadedIdentity = nil
    presentation = nil
    catalog = nil
    context = nil
    canEdit = false
    isUpdating = false
  }

  var projectTitle: String {
    selectedLabel(
      context?.configuration.projectID,
      present: context?.configuration.hasProjectID == true,
      in: catalog?.projects
    ) ?? "Provider default"
  }

  var modelTitle: String {
    guard context?.hasConfiguration == true, context?.configuration.hasModelID == true else {
      return "Provider default"
    }
    let id = context?.configuration.modelID
    return catalog?.models?.first(where: { $0.id == id })?.label ?? "Unavailable"
  }

  var reasoningTitle: String {
    selectedLabel(
      context?.configuration.reasoningEffortID,
      present: context?.configuration.hasReasoningEffortID == true,
      in: availableReasoningOptions
    ) ?? "Provider default"
  }

  var availableReasoningOptions: [AgentConfigurationOption]? {
    guard let reasoning = catalog?.reasoning else { return nil }
    guard let models = catalog?.models else { return reasoning }
    guard context?.hasConfiguration == true,
          context?.configuration.hasModelID == true,
          let model = models.first(where: { $0.id == context?.configuration.modelID })
    else { return nil }
    guard !model.reasoningEffortIDs.isEmpty else { return reasoning }
    let supported = Set(model.reasoningEffortIDs)
    return reasoning.filter { supported.contains($0.id) }
  }

  func contextSelectingProject(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    updatedContext { configuration in
      if let id { configuration.projectID = id } else { configuration.clearProjectID() }
    }
  }

  func contextSelectingModel(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    updatedContext { configuration in
      if let id { configuration.modelID = id } else { configuration.clearModelID() }
      if id == nil, catalog?.models != nil {
        configuration.clearReasoningEffortID()
      } else if configuration.hasReasoningEffortID,
         let selectedModel = id.flatMap({ selectedModelID in
           catalog?.models?.first(where: { $0.id == selectedModelID })
         }),
         !selectedModel.reasoningEffortIDs.isEmpty,
         !selectedModel.reasoningEffortIDs.contains(configuration.reasoningEffortID)
      {
        configuration.clearReasoningEffortID()
      }
    }
  }

  func contextSelectingReasoning(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    updatedContext { configuration in
      if let id {
        configuration.reasoningEffortID = id
      } else {
        configuration.clearReasoningEffortID()
      }
    }
  }

  func performUpdate(
    _ nextContext: InlineProtocol.AgentThreadContext,
    using update: @escaping (InlineProtocol.AgentThreadContext) async throws -> Void
  ) {
    guard canEdit, !isUpdating else { return }
    isUpdating = true
    Task { @MainActor [weak self] in
      defer { self?.isUpdating = false }
      do {
        try await update(nextContext)
      } catch {
        ToastCenter.shared.showError("Could not update this Agent session.")
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
    catalog = nil
    canEdit = false
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
    canEdit = false
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
        ?? UserInfo(user: InlineKit.User(from: peerBot.bot))
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

    if let ownedBotIDs = try? await fetchOwnedBotIDs(), isCurrent(identity, generation: generation) {
      canEdit = ownedBotIDs.contains(identity.botUserID)
    }

    do {
      let refreshed = try await AgentConfigurationCatalogStore.shared.refresh(
        botUserID: identity.botUserID,
        peer: peer
      )
      if isCurrent(identity, generation: generation) {
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

  private func selectedLabel(
    _ id: String?,
    present: Bool,
    in options: [AgentConfigurationOption]?
  ) -> String? {
    guard present, let id else { return nil }
    return options?.first(where: { $0.id == id })?.label ?? "Unavailable"
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}

struct AgentThreadToolbarIndicator: View {
  @ObservedObject var model: AgentThreadToolbarModel
  let update: (InlineProtocol.AgentThreadContext) async throws -> Void

  var body: some View {
    if let presentation = model.presentation {
      Menu {
        Text("This thread has its own session with \(presentation.name).")

        if model.catalog?.projects != nil || model.context?.configuration.hasProjectID == true {
          Divider()
          AgentThreadConfigurationSubmenu(
            title: "Project",
            selectionTitle: model.projectTitle,
            options: model.catalog?.projects ?? [],
            selectedID: model.context?.configuration.hasProjectID == true
              ? model.context?.configuration.projectID
              : nil,
            // Every bound Chat created by Compose or the Agent tool already
            // has a first message, so its provider session has started and the
            // project is immutable. Keep the selected project visible here;
            // choose it while creating the Chat.
            isDisabled: true,
            select: { id in
              guard let context = model.contextSelectingProject(id) else { return }
              model.performUpdate(context, using: update)
            }
          )
        }

        if model.catalog?.models != nil || model.context?.configuration.hasModelID == true {
          AgentThreadModelSubmenu(
            selectionTitle: model.modelTitle,
            options: model.catalog?.models ?? [],
            selectedID: model.context?.configuration.hasModelID == true
              ? model.context?.configuration.modelID
              : nil,
            isDisabled: !model.canEdit || model.isUpdating,
            select: { id in
              guard let context = model.contextSelectingModel(id) else { return }
              model.performUpdate(context, using: update)
            }
          )
        }

        if model.availableReasoningOptions != nil || model.context?.configuration.hasReasoningEffortID == true {
          AgentThreadConfigurationSubmenu(
            title: "Reasoning",
            selectionTitle: model.reasoningTitle,
            options: model.availableReasoningOptions ?? [],
            selectedID: model.context?.configuration.hasReasoningEffortID == true
              ? model.context?.configuration.reasoningEffortID
              : nil,
            isDisabled: !model.canEdit || model.isUpdating,
            select: { id in
              guard let context = model.contextSelectingReasoning(id) else { return }
              model.performUpdate(context, using: update)
            }
          )
        }
      } label: {
        HStack(spacing: 4) {
          UserAvatar(userInfo: presentation.userInfo, size: 14)
          Text(presentation.name)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: 120, alignment: .leading)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .help(tooltip(presentation))
      .accessibilityLabel("Agent session: \(presentation.name)")
    }
  }

  private func tooltip(_ presentation: AgentThreadToolbarPresentation) -> String {
    let owner = presentation.name == presentation.botName
      ? presentation.name
      : "\(presentation.name) via \(presentation.botName)"
    return "Bound to \(owner). This thread has its own Agent session."
  }
}

private struct AgentThreadConfigurationSubmenu: View {
  let title: String
  let selectionTitle: String
  let options: [AgentConfigurationOption]
  let selectedID: String?
  let isDisabled: Bool
  let select: (String?) -> Void

  var body: some View {
    Menu("\(title): \(selectionTitle)") {
      selectionButton(label: "Provider default", id: nil)
      if !options.isEmpty { Divider() }
      ForEach(options) { option in
        selectionButton(
          label: option.label,
          description: option.description,
          id: option.id
        )
      }
    }
    .disabled(isDisabled)
  }

  private func selectionButton(
    label: String,
    description: String? = nil,
    id: String?
  ) -> some View {
    Button {
      select(id)
    } label: {
      AgentThreadConfigurationOptionLabel(
        title: label,
        description: description,
        isSelected: selectedID == id
      )
    }
  }
}

private struct AgentThreadModelSubmenu: View {
  let selectionTitle: String
  let options: [AgentModelConfigurationOption]
  let selectedID: String?
  let isDisabled: Bool
  let select: (String?) -> Void

  var body: some View {
    Menu("Model: \(selectionTitle)") {
      selectionButton(label: "Provider default", id: nil)
      if !options.isEmpty { Divider() }
      ForEach(options) { option in
        selectionButton(
          label: option.label,
          description: option.description,
          id: option.id
        )
      }
    }
    .disabled(isDisabled)
  }

  private func selectionButton(
    label: String,
    description: String? = nil,
    id: String?
  ) -> some View {
    Button {
      select(id)
    } label: {
      AgentThreadConfigurationOptionLabel(
        title: label,
        description: description,
        isSelected: selectedID == id
      )
    }
  }
}

private struct AgentThreadConfigurationOptionLabel: View {
  let title: String
  let description: String?
  let isSelected: Bool

  var body: some View {
    if isSelected {
      Label {
        content
      } icon: {
        Image(systemName: "checkmark")
      }
    } else {
      content
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(title)
      if let description, !description.isEmpty {
        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
