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
  @Published private(set) var editabilityResolved = false
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
    editabilityResolved = false
    isUpdating = false
  }

  var explicitProjectID: String? {
    context?.configuration.hasProjectID == true ? context?.configuration.projectID : nil
  }

  var explicitModelID: String? {
    context?.configuration.hasModelID == true ? context?.configuration.modelID : nil
  }

  var explicitReasoningID: String? {
    context?.configuration.hasReasoningEffortID == true
      ? context?.configuration.reasoningEffortID
      : nil
  }

  var effectiveProjectID: String? {
    explicitProjectID ?? catalog?.defaultProjectID
  }

  var effectiveModelID: String? {
    explicitModelID ?? catalog?.defaultModelID
  }

  var effectiveReasoningID: String? {
    explicitReasoningID ?? catalog?.defaultReasoningEffortID(forModelID: effectiveModelID)
  }

  var projectTitle: String? {
    resolvedTitle(
      explicitID: explicitProjectID,
      effectiveID: effectiveProjectID,
      in: catalog?.projects
    )
  }

  var modelTitle: String? {
    guard let effectiveModelID else { return nil }
    return catalog?.models?.first(where: { $0.id == effectiveModelID })?.label
      ?? (explicitModelID == nil ? nil : "Unavailable")
  }

  var reasoningTitle: String? {
    resolvedTitle(
      explicitID: explicitReasoningID,
      effectiveID: effectiveReasoningID,
      in: availableReasoningOptions
    )
  }

  var automaticProjectTitle: String? {
    automaticTitle(catalog?.defaultProjectID, in: catalog?.projects)
  }

  var automaticModelTitle: String? {
    guard let defaultModelID = catalog?.defaultModelID,
          let label = catalog?.models?.first(where: { $0.id == defaultModelID })?.label
    else { return nil }
    return Self.automaticTitle(label)
  }

  var automaticReasoningTitle: String? {
    automaticTitle(
      catalog?.defaultReasoningEffortID(forModelID: effectiveModelID),
      in: availableReasoningOptions
    )
  }

  var availableReasoningOptions: [AgentConfigurationOption]? {
    reasoningOptions(forModelID: effectiveModelID)
  }

  private func reasoningOptions(forModelID modelID: String?) -> [AgentConfigurationOption]? {
    guard let reasoning = catalog?.reasoning else { return nil }
    guard let models = catalog?.models else { return reasoning }
    guard let model = models.first(where: { $0.id == modelID }) else { return nil }
    guard !model.reasoningEffortIDs.isEmpty else { return reasoning }
    let supported = Set(model.reasoningEffortIDs)
    return reasoning.filter { supported.contains($0.id) }
  }

  func contextSelectingModel(_ id: String?) -> InlineProtocol.AgentThreadContext? {
    updatedContext { configuration in
      if let id { configuration.modelID = id } else { configuration.clearModelID() }
      let nextModelID = id ?? catalog?.defaultModelID
      if configuration.hasReasoningEffortID,
         reasoningOptions(forModelID: nextModelID)?.contains(where: {
           $0.id == configuration.reasoningEffortID
         }) != true
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
        ToastCenter.shared.showError("Couldn’t update Agent settings.")
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

    if let ownedBotIDs = try? await fetchOwnedBotIDs(),
       isCurrent(identity, generation: generation)
    {
      canEdit = ownedBotIDs.contains(identity.botUserID)
      editabilityResolved = true
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
      localized: "Automatic — \(label)",
      comment:
        "Reset label for an Agent setting. The variable is the current harness-selected option name."
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
  }
}

struct AgentThreadToolbarIndicator: View {
  @ObservedObject var model: AgentThreadToolbarModel

  var body: some View {
    if let presentation = model.presentation {
      HStack(spacing: 4) {
        UserAvatar(userInfo: presentation.userInfo, size: 14)
        Text(presentation.name)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .frame(maxWidth: 120, alignment: .leading)
      // Preserve the ideal width; maxWidth remains only a truncation cap.
      .fixedSize(horizontal: true, vertical: true)
      .help(tooltip(presentation))
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Agent session: \(presentation.name)")
      .accessibilityHint("Open Agent Settings to change this thread’s configuration.")
    }
  }

  private func tooltip(_ presentation: AgentThreadToolbarPresentation) -> String {
    let owner = presentation.name == presentation.botName
      ? presentation.name
      : "\(presentation.name) via \(presentation.botName)"
    return "Bound to \(owner). This thread has its own Agent session."
  }
}

struct AgentThreadSettingsSection: View {
  @ObservedObject var model: AgentThreadToolbarModel
  let update: (InlineProtocol.AgentThreadContext) async throws -> Void

  var body: some View {
    if model.context != nil {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Thread")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            if let presentation = model.presentation {
              Text(presentation.name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          if model.isUpdating {
            ProgressView()
              .controlSize(.mini)
              .accessibilityLabel("Updating thread settings")
          }
        }

        if let projectTitle = model.projectTitle {
          AgentThreadSettingRow(
            title: "Project",
            selectionTitle: projectTitle,
            selectionDescription: selectedProjectDescription,
            options: projectOptions,
            selectedID: model.explicitProjectID,
            automaticTitle: model.automaticProjectTitle,
            isEditable: false,
            isUpdating: false,
            helpText: "Project is chosen when the thread is created.",
            select: { _ in }
          )
        }

        if let modelTitle = model.modelTitle {
          AgentThreadSettingRow(
            title: "Model",
            selectionTitle: modelTitle,
            selectionDescription: selectedModelDescription,
            options: modelOptions,
            selectedID: model.explicitModelID,
            automaticTitle: model.automaticModelTitle,
            isEditable: model.canEdit,
            isUpdating: model.isUpdating,
            helpText: nil,
            select: selectModel
          )
        }

        if let reasoningTitle = model.reasoningTitle {
          AgentThreadSettingRow(
            title: "Reasoning",
            selectionTitle: reasoningTitle,
            selectionDescription: selectedReasoningDescription,
            options: reasoningOptions,
            selectedID: model.explicitReasoningID,
            automaticTitle: model.automaticReasoningTitle,
            isEditable: model.canEdit,
            isUpdating: model.isUpdating,
            helpText: nil,
            select: selectReasoning
          )
        }

        if model.editabilityResolved, !model.canEdit, showsModel || showsReasoning {
          Label("Only the Agent owner can change Model and Reasoning.", systemImage: "lock")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var showsModel: Bool {
    model.modelTitle != nil
  }

  private var showsReasoning: Bool {
    model.reasoningTitle != nil
  }

  private var projectOptions: [AgentThreadSettingOption] {
    (model.catalog?.projects ?? []).map(AgentThreadSettingOption.init)
  }

  private var modelOptions: [AgentThreadSettingOption] {
    (model.catalog?.models ?? []).map(AgentThreadSettingOption.init)
  }

  private var reasoningOptions: [AgentThreadSettingOption] {
    (model.availableReasoningOptions ?? []).map(AgentThreadSettingOption.init)
  }

  private var selectedProjectDescription: String? {
    projectOptions.first(where: { $0.id == model.effectiveProjectID })?.description
  }

  private var selectedModelDescription: String? {
    modelOptions.first(where: { $0.id == model.effectiveModelID })?.description
  }

  private var selectedReasoningDescription: String? {
    reasoningOptions.first(where: { $0.id == model.effectiveReasoningID })?.description
  }

  private func selectModel(_ id: String?) {
    guard let context = model.contextSelectingModel(id) else { return }
    model.performUpdate(context, using: update)
  }

  private func selectReasoning(_ id: String?) {
    guard let context = model.contextSelectingReasoning(id) else { return }
    model.performUpdate(context, using: update)
  }
}

private struct AgentThreadSettingOption: Identifiable, Equatable {
  let id: String
  let label: String
  let description: String?

  init(_ option: AgentConfigurationOption) {
    id = option.id
    label = option.label
    description = option.description
  }

  init(_ option: AgentModelConfigurationOption) {
    id = option.id
    label = option.label
    description = option.description
  }
}

private struct AgentThreadSettingRow: View {
  let title: LocalizedStringResource
  let selectionTitle: String
  let selectionDescription: String?
  let options: [AgentThreadSettingOption]
  let selectedID: String?
  let automaticTitle: String?
  let isEditable: Bool
  let isUpdating: Bool
  let helpText: LocalizedStringResource?
  let select: (String?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 10) {
        Text(title)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)

        if isEditable, automaticTitle != nil || !options.isEmpty {
          Menu {
            if let automaticTitle {
              selectionButton(label: automaticTitle, id: nil)
              if !options.isEmpty { Divider() }
            }
            ForEach(options) { option in
              selectionButton(
                label: option.label,
                description: option.description,
                id: option.id
              )
            }
          } label: {
            selectionValue
          }
          .menuStyle(.borderlessButton)
          .disabled(isUpdating)
          .accessibilityLabel(Text(title))
          .accessibilityValue(selectionTitle)
        } else {
          selectionValue
            .accessibilityLabel(Text(title))
            .accessibilityValue(selectionTitle)
        }
      }
      if let selectionDescription {
        Text(selectionDescription)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(2)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
      if let helpText {
        Text(helpText)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }

  private var selectionValue: some View {
    Text(selectionTitle)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(maxWidth: 250, alignment: .trailing)
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
