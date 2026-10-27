import Combine
import GRDB
import InlineKit
import InlineMacUI
import InlineProtocol
import InlineUI
import Observation
import SwiftUI

/// Agent controls for the thread Compose (spec §6, decided Oct 26).
///
/// A compact pill appears when the draft would reach an Agent in Detailed
/// mode. Clicking it opens or closes the chain (folder or project, model,
/// reasoning, usage) in Compose's accessory row. Friendly mode shows nothing.
/// The output mode itself is never set here; it lives in the toolbar's
/// Agent Settings.
@MainActor
final class ComposeAgentChainModel: ObservableObject {
  private static let chainOpenDefaultsKey = "compose.agentChain.open"

  /// Where the chain reads and writes this thread's Agent configuration.
  enum Source: Equatable {
    /// The thread's server-side Agent preset (`Chat.agentContext`).
    case agentThread
    /// The Agent's own per-chat settings document, published by its bridge.
    case agentSettings
  }

  @Published private(set) var target: AgentComposeTarget?
  @Published private(set) var source: Source?
  @Published private(set) var isAvailable = false
  @Published private(set) var botUserInfo: UserInfo?
  @Published private(set) var catalog: AgentConfigurationCatalogSnapshot?
  @Published var isChainOpen: Bool {
    didSet {
      guard oldValue != isChainOpen else { return }
      UserDefaults.standard.set(isChainOpen, forKey: Self.chainOpenDefaultsKey)
    }
  }

  let peer: InlineKit.Peer
  let chatID: Int64?
  let threadModel: AgentThreadToolbarModel
  private(set) var settings: BotChatSettingsCoordinator?

  private let database: AppDatabase
  private let updateAgentContext: (InlineProtocol.AgentThreadContext) async throws -> Void
  private let directMessageBotUserID: Int64?
  private var leadingMentionUserIDs: [Int64] = []
  private var replyToUserID: Int64?
  private var cancellables: Set<AnyCancellable> = []
  private var catalogTask: Task<Void, Never>?
  private var settingsTask: Task<Void, Never>?
  private var isStarted = false

  init(
    peer: InlineKit.Peer,
    chatID: Int64?,
    peerUser: InlineKit.User?,
    database: AppDatabase,
    updateAgentContext: @escaping (InlineProtocol.AgentThreadContext) async throws -> Void
  ) {
    self.peer = peer
    self.chatID = chatID
    self.database = database
    self.updateAgentContext = updateAgentContext
    directMessageBotUserID = peerUser?.bot == true ? peerUser?.id : nil
    threadModel = AgentThreadToolbarModel(peer: peer)
    isChainOpen = UserDefaults.standard.bool(forKey: Self.chainOpenDefaultsKey)
  }

  deinit {
    catalogTask?.cancel()
    settingsTask?.cancel()
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    if peer.isThread {
      threadModel.start(database: database)
      threadModel.$context
        .map { $0?.botUserID }
        .removeDuplicates()
        .sink { [weak self] _ in self?.resolve() }
        .store(in: &cancellables)
      threadModel.objectWillChange
        .sink { [weak self] in
          // Thread preset and catalog changes re-render the pill and chain.
          self?.objectWillChange.send()
          Task { @MainActor [weak self] in self?.refreshAvailability() }
        }
        .store(in: &cancellables)
    }
    let store = AgentWorkStateStore.shared
    Publishers.Merge(
      store.$outputOverrides.map { _ in () },
      store.$defaultOutputModes.map { _ in () }
    )
    .sink { [weak self] _ in
      Task { @MainActor [weak self] in self?.refreshAvailability() }
    }
    .store(in: &cancellables)
    resolve()
  }

  func stop() {
    isStarted = false
    cancellables.removeAll()
    catalogTask?.cancel()
    settingsTask?.cancel()
    threadModel.cancel()
    settings?.cancel()
    settings = nil
  }

  /// Leading mentions decide the addressee, so only the start of the draft is
  /// read. Called on every text change; it stays O(leading mentions).
  func updateDraft(_ text: NSAttributedString) {
    let ids = AgentComposeTargetResolver.leadingMentionUserIDs(in: text)
    guard ids != leadingMentionUserIDs else { return }
    leadingMentionUserIDs = ids
    resolve()
  }

  func updateReply(toUserID userID: Int64?) {
    guard replyToUserID != userID else { return }
    replyToUserID = userID
    resolve()
  }

  func toggleChain() {
    isChainOpen.toggle()
  }

  /// Inserts text at the composer's cursor. Set by Compose.
  var onInsertText: ((String) -> Void)?

  /// The work in this chat that file references resolve against.
  var workSessionID: Int64? {
    target.flatMap { AgentWorkStateStore.shared.state(peer: peer, botUserID: $0.botUserID)?.sessionID }
  }

  /// The owner or an INVOKE grantee; unknown grants show the button and the
  /// server decides.
  var canReferenceFiles: Bool {
    guard let target else { return false }
    AgentGrantStore.shared.ensureLoaded(botUserID: target.botUserID)
    return AgentGrantStore.shared.access(botUserID: target.botUserID)?.satisfies(.invoke) ?? true
  }

  func insertFileReference(_ entry: AgentWorkFileEntry) {
    onInsertText?(AgentWorkFiles.referenceText(for: entry) + " ")
  }

  var showsChain: Bool {
    isAvailable && isChainOpen
  }

  // MARK: Resolution

  private func resolve() {
    let agentThreadBotUserID = threadModel.context?.botUserID
    let next = AgentComposeTargetResolver.resolve(
      leadingMentionUserIDs: leadingMentionUserIDs,
      replyToUserID: replyToUserID,
      agentThreadBotUserID: agentThreadBotUserID,
      directMessageBotUserID: directMessageBotUserID,
      isBot: { userID in
        if userID == agentThreadBotUserID || userID == self.directMessageBotUserID { return true }
        return ObjectCache.shared.getCachedUser(id: userID)?.user.bot == true
      }
    )
    let nextSource: Source? = next.map {
      $0.botUserID == agentThreadBotUserID ? .agentThread : .agentSettings
    }
    let targetChanged = next?.botUserID != target?.botUserID
    if next != target { target = next }
    if nextSource != source { source = nextSource }
    if targetChanged { loadTarget() }
    refreshAvailability()
  }

  private func loadTarget() {
    catalogTask?.cancel()
    settingsTask?.cancel()
    guard let target else {
      catalog = nil
      botUserInfo = nil
      return
    }
    let botUserID = target.botUserID
    // First frame: the durable catalog cache and the user cache are both local.
    catalog = AgentConfigurationCatalogStore.shared.cachedSnapshot(botUserID: botUserID)
    botUserInfo = ObjectCache.shared.getCachedUser(id: botUserID)
    catalogTask = Task { @MainActor [weak self, peer] in
      let refreshed = try? await AgentConfigurationCatalogStore.shared.refresh(
        botUserID: botUserID,
        peer: peer
      )
      guard let self, !Task.isCancelled, self.target?.botUserID == botUserID else { return }
      if let refreshed { self.catalog = refreshed }
      self.refreshAvailability()
    }
    if source == .agentSettings {
      prepareSettings(for: botUserID)
    }
  }

  /// The Agent's bridge publishes this chat's model, reasoning and folder in
  /// its settings document. Agent threads keep them in the server preset.
  private func prepareSettings(for botUserID: Int64) {
    let settings = ensureSettings()
    settingsTask?.cancel()
    settingsTask = Task { @MainActor [weak self, weak settings] in
      guard let settings else { return }
      if !settings.bots.contains(where: { $0.id == botUserID }) {
        await settings.warmUp()
      }
      guard let self, !Task.isCancelled, self.target?.botUserID == botUserID else { return }
      settings.selectBot(botUserID)
      self.observeSettings()
    }
  }

  func prepareUsage() {
    guard let target else { return }
    if source == .agentThread {
      prepareSettings(for: target.botUserID)
    } else {
      settings?.refreshSelectedIfStale()
    }
  }

  private func ensureSettings() -> BotChatSettingsCoordinator {
    if let settings { return settings }
    let settings = BotChatSettingsCoordinator(peer: peer)
    self.settings = settings
    return settings
  }

  private func observeSettings() {
    guard let settings else { return }
    withObservationTracking {
      _ = settings.selectedBotID
      _ = settings.selectedState
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        self?.objectWillChange.send()
        self?.refreshAvailability()
        self?.observeSettings()
      }
    }
  }

  private func refreshAvailability() {
    let next = computeAvailability()
    if next != isAvailable { isAvailable = next }
  }

  private func computeAvailability() -> Bool {
    guard let target, let source else { return false }
    // Friendly mode is a composer for talking to people (Oct 26).
    if outputMode(for: target.botUserID) == .friendly { return false }
    switch source {
    case .agentThread:
      return threadModel.context?.botUserID == target.botUserID
    case .agentSettings:
      // Only harness Agents publish a configuration catalog; ordinary bots
      // never get model controls.
      return catalog?.models?.isEmpty == false || settingsDocument?.item(ComposeAgentSettingsItem.model) != nil
    }
  }

  func outputMode(for botUserID: Int64) -> AgentThreadOutputMode {
    // The thread's override, else the agent's default; both are synced and
    // cached locally, so this is right on the first frame.
    AgentWorkStateStore.shared.outputMode(peer: peer, botUserID: botUserID)
  }

  // MARK: Presentation

  var settingsDocument: BotChatSettingsModel.Document? {
    guard let settings, let target, settings.selectedBotID == target.botUserID else { return nil }
    return settings.selectedState.document
  }

  var settingsState: BotChatSettingsBotState? {
    guard let settings, let target, settings.selectedBotID == target.botUserID else { return nil }
    return settings.selectedState
  }

  var agentName: String {
    botUserInfo?.user.firstName ?? botUserInfo?.user.displayName ?? "Agent"
  }

  var pillTitle: String {
    let parts = [modelTitle, reasoningTitle].compactMap { $0 }
    return parts.isEmpty ? agentName : parts.joined(separator: " · ")
  }

  var pillTooltip: String {
    let name = botUserInfo?.user.displayName ?? agentName
    return ([name] + [projectTitle, modelTitle, reasoningTitle].compactMap { $0 }).joined(separator: " · ")
  }

  var canEdit: Bool {
    switch source {
    case .agentThread: threadModel.canEdit && !threadModel.isUpdating
    case .agentSettings: settingsDocument != nil && settings?.isMutating != true
    case nil: false
    }
  }

  var projectTitle: String? {
    switch source {
    case .agentThread:
      return threadModel.projectTitle
    case .agentSettings:
      if let item = settingsDocument?.item(ComposeAgentSettingsItem.project), case let .select(value, options) = item.control {
        return options.first(where: { $0.value == value })?.label
      }
      if let folder = settingsDocument?.item(ComposeAgentSettingsItem.folder)?.control.folderPresentation {
        return folder.selectedFolder.label
      }
      return nil
    case nil:
      return nil
    }
  }

  var projectOptions: [AgentConfigurationOption] {
    switch source {
    case .agentThread:
      return threadModel.canEditProject ? (threadModel.catalog?.projects ?? []) : []
    case .agentSettings:
      if let item = settingsDocument?.item(ComposeAgentSettingsItem.project), case let .select(_, options) = item.control {
        return options.filter { !$0.isDisabled }.map {
          AgentConfigurationOption(id: $0.value, label: $0.label, description: $0.description)
        }
      }
      if let folder = settingsDocument?.item(ComposeAgentSettingsItem.folder)?.control.folderPresentation {
        return folder.recentFolders.filter { !$0.isDisabled }.map {
          AgentConfigurationOption(id: $0.value, label: $0.label, description: $0.parentHint)
        }
      }
      return []
    case nil:
      return []
    }
  }

  var selectedProjectID: String? {
    switch source {
    case .agentThread:
      return threadModel.effectiveProjectID
    case .agentSettings:
      if let item = settingsDocument?.item(ComposeAgentSettingsItem.project), case let .select(value, _) = item.control {
        return value
      }
      return settingsDocument?.item(ComposeAgentSettingsItem.folder)?.control.folderPresentation?.selectedFolder.value
    case nil:
      return nil
    }
  }

  var modelTitle: String? {
    switch source {
    case .agentThread:
      return threadModel.modelTitle
    case .agentSettings:
      if let title = selectedLabel(ComposeAgentSettingsItem.model) { return title }
      return catalog?.modelTitle(forModelID: catalog?.defaultModelID)
    case nil:
      return nil
    }
  }

  var modelOptions: [AgentModelConfigurationOption] {
    switch source {
    case .agentThread:
      return threadModel.catalog?.models ?? []
    case .agentSettings:
      return selectOptions(ComposeAgentSettingsItem.model).map {
        AgentModelConfigurationOption(id: $0.id, label: $0.label, description: $0.description)
      }
    case nil:
      return []
    }
  }

  var selectedModelID: String? {
    switch source {
    case .agentThread: threadModel.explicitModelID
    case .agentSettings: selectedValue(ComposeAgentSettingsItem.model)
    case nil: nil
    }
  }

  var automaticModelTitle: String? {
    source == .agentThread ? threadModel.automaticModelTitle : nil
  }

  var reasoningTitle: String? {
    switch source {
    case .agentThread:
      return threadModel.reasoningTitle
    case .agentSettings:
      if let title = selectedLabel(ComposeAgentSettingsItem.reasoning) { return title }
      guard let catalog, let id = catalog.defaultReasoningEffortID(forModelID: catalog.defaultModelID) else { return nil }
      return catalog.reasoning?.first(where: { $0.id == id })?.label
    case nil:
      return nil
    }
  }

  var reasoningOptions: [AgentConfigurationOption] {
    switch source {
    case .agentThread: threadModel.availableReasoningOptions ?? []
    case .agentSettings: selectOptions(ComposeAgentSettingsItem.reasoning)
    case nil: []
    }
  }

  var selectedReasoningID: String? {
    switch source {
    case .agentThread: threadModel.explicitReasoningID
    case .agentSettings: selectedValue(ComposeAgentSettingsItem.reasoning)
    case nil: nil
    }
  }

  var automaticReasoningTitle: String? {
    source == .agentThread ? threadModel.automaticReasoningTitle : nil
  }

  // MARK: Writes (apply to this thread from the next message on)

  func selectProject(_ id: String?) {
    switch source {
    case .agentThread:
      guard let context = threadModel.contextSelectingProject(id) else { return }
      threadModel.performUpdate(context, using: updateAgentContext)
    case .agentSettings:
      guard let id else { return }
      if settingsDocument?.item(ComposeAgentSettingsItem.project) != nil {
        settings?.invoke(itemID: ComposeAgentSettingsItem.project, value: .string(id))
      } else {
        settings?.invoke(itemID: ComposeAgentSettingsItem.folder, value: .string(id))
      }
    case nil:
      break
    }
  }

  func selectModel(_ id: String?) {
    switch source {
    case .agentThread:
      guard let context = threadModel.contextSelectingModel(id) else { return }
      threadModel.performUpdate(context, using: updateAgentContext)
    case .agentSettings:
      guard let id else { return }
      settings?.invoke(itemID: ComposeAgentSettingsItem.model, value: .string(id))
    case nil:
      break
    }
  }

  func selectReasoning(_ id: String?) {
    switch source {
    case .agentThread:
      guard let context = threadModel.contextSelectingReasoning(id) else { return }
      threadModel.performUpdate(context, using: updateAgentContext)
    case .agentSettings:
      guard let id else { return }
      settings?.invoke(itemID: ComposeAgentSettingsItem.reasoning, value: .string(id))
    case nil:
      break
    }
  }

  // MARK: Usage

  var usageItem: BotChatSettingsModel.Item? {
    settingsDocument?.item(ComposeAgentSettingsItem.usage)
  }

  private func selectOptions(_ itemID: String) -> [AgentConfigurationOption] {
    guard case let .select(_, options)? = settingsDocument?.item(itemID)?.control else { return [] }
    return options.filter { !$0.isDisabled }.map {
      AgentConfigurationOption(id: $0.value, label: $0.label, description: $0.description)
    }
  }

  private func selectedValue(_ itemID: String) -> String? {
    guard case let .select(value, _)? = settingsDocument?.item(itemID)?.control else { return nil }
    return value
  }

  private func selectedLabel(_ itemID: String) -> String? {
    guard case let .select(value, options)? = settingsDocument?.item(itemID)?.control else { return nil }
    return options.first(where: { $0.value == value })?.label
  }
}

/// Item IDs the bridge publishes in its per-chat settings document.
enum ComposeAgentSettingsItem {
  static let model = "agent.model"
  static let reasoning = "agent.reasoning"
  static let folder = "workspace.folder"
  static let project = "workspace.project"
  static let usage = "account.usage"
}

extension BotChatSettingsModel.Document {
  func item(_ id: String) -> BotChatSettingsModel.Item? {
    for section in sections {
      if let item = section.items.first(where: { $0.id == id }) { return item }
    }
    return nil
  }
}

// MARK: - Views

/// The compact pill that sits at the leading edge of the Compose pill, like
/// Telegram's bot menu button. It hugs its content and renders nothing when
/// the draft would not reach an Agent in Detailed mode.
@available(macOS 26.0, *)
struct ComposeAgentPill: View {
  @ObservedObject var model: ComposeAgentChainModel
  @State private var isHovering = false

  var body: some View {
    if model.isAvailable {
      Button(action: model.toggleChain) {
        HStack(spacing: 5) {
          if let userInfo = model.botUserInfo {
            UserAvatar(userInfo: userInfo, size: 16)
          } else {
            Image(systemName: "sparkle")
              .font(.system(size: 10, weight: .semibold))
              .frame(width: 16, height: 16)
          }
          Text(model.pillTitle)
            .font(.system(size: 11.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 132, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
          Image(systemName: "chevron.up")
            .font(.system(size: 8, weight: .bold))
            .rotationEffect(.degrees(model.isChainOpen ? 180 : 0))
            .opacity(isHovering || model.isChainOpen ? 0.8 : 0.45)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 24)
        .background {
          Capsule()
            .fill(.quaternary)
            .opacity(model.isChainOpen ? 1 : (isHovering ? 0.8 : 0.5))
        }
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .onHover { isHovering = $0 }
      .padding(.leading, 6)
      .padding(.trailing, 2)
      .frame(height: 34)
      .accessibilityLabel("Agent controls")
      .accessibilityValue(model.pillTooltip)
      .accessibilityHint(model.isChainOpen ? "Hide model and reasoning controls" : "Show model and reasoning controls")
      .inlineTooltip(
        verbatim: model.pillTooltip,
        description: model.isChainOpen
          ? "Hide agent controls"
          : "Show folder, model, reasoning and usage for this thread",
        placement: .above
      )
    }
  }
}

/// The chain in Compose's accessory row: folder or project, model, reasoning,
/// and a usage button. A change applies to this Agent's work in this thread
/// from the next message on.
@available(macOS 26.0, *)
struct ComposeAgentChainBar: View {
  @ObservedObject var model: ComposeAgentChainModel
  @State private var isShowingUsage = false
  @State private var isShowingFiles = false

  var body: some View {
    if model.showsChain {
      HStack(spacing: 4) {
        if let title = model.projectTitle {
          AgentConfigurationMenu(
            title: title,
            automaticTitle: nil,
            options: model.projectOptions,
            selection: model.selectedProjectID,
            isDisabled: !model.canEdit || model.projectOptions.isEmpty,
            tooltipTitle: "Project",
            tooltipDescription: "Choose the folder or project for this thread.",
            tooltipPlacement: .above,
            select: model.selectProject
          )
        }

        if let title = model.modelTitle {
          AgentModelConfigurationMenu(
            title: title,
            automaticTitle: model.automaticModelTitle,
            options: model.modelOptions,
            selection: model.selectedModelID,
            isDisabled: !model.canEdit || model.modelOptions.isEmpty,
            tooltipPlacement: .above,
            select: model.selectModel
          )
        }

        if let title = model.reasoningTitle {
          AgentConfigurationMenu(
            title: title,
            automaticTitle: model.automaticReasoningTitle,
            options: model.reasoningOptions,
            selection: model.selectedReasoningID,
            isDisabled: !model.canEdit || model.reasoningOptions.isEmpty,
            tooltipTitle: "Reasoning",
            tooltipDescription: "Choose reasoning effort for this thread from the next message on.",
            tooltipPlacement: .above,
            select: model.selectReasoning
          )
        }

        Spacer(minLength: 0)

        if model.canReferenceFiles {
        Button {
          isShowingFiles.toggle()
        } label: {
          Image(systemName: "doc.badge.plus")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Insert file reference")
        .inlineTooltip(
          verbatim: "Files",
          description: "Insert a path from this work's folder.",
          placement: .above
        )
        .popover(isPresented: $isShowingFiles, arrowEdge: .bottom) {
          ComposeAgentFilePicker(
            peer: model.peer,
            botUserID: model.target?.botUserID ?? 0,
            sessionID: model.workSessionID
          ) { entry in
            model.insertFileReference(entry)
            isShowingFiles = false
          }
        }
        }

        Button {
          model.prepareUsage()
          isShowingUsage.toggle()
        } label: {
          Image(systemName: "gauge.with.dots.needle.50percent")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Usage")
        .inlineTooltip(verbatim: "Usage", description: "Show this agent's usage limits.", placement: .above)
        .popover(isPresented: $isShowingUsage, arrowEdge: .bottom) {
          ComposeAgentUsagePopover(model: model)
        }
      }
      .padding(.horizontal, 6)
      .frame(height: 30)
    }
  }
}

@available(macOS 26.0, *)
private struct ComposeAgentUsagePopover: View {
  @ObservedObject var model: ComposeAgentChainModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        if let userInfo = model.botUserInfo {
          UserAvatar(userInfo: userInfo, size: 16)
        }
        Text("Usage")
          .font(.headline)
        Spacer(minLength: 12)
        if let item = model.usageItem, case let .info(text, tone) = item.control {
          Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(tone == .warning || tone == .error ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
        }
      }
      content
    }
    .padding(14)
    .frame(width: 280, alignment: .leading)
  }

  @ViewBuilder
  private var content: some View {
    if let item = model.usageItem {
      if let description = item.description {
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    } else if let problem = model.settingsState?.problem {
      Label(problem.message, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if model.settingsState?.phase == .loaded {
      Text("This agent doesn’t report usage.")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Asking \(model.agentName)…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Searchable picker over the work's folder. It inserts a plain path token,
/// never a mention entity; nothing it lists is cached.
@available(macOS 26.0, *)
private struct ComposeAgentFilePicker: View {
  let peer: InlineKit.Peer
  let botUserID: Int64
  let sessionID: Int64?
  let select: (AgentWorkFileEntry) -> Void

  @State private var query = ""
  @State private var path = ""
  @State private var entries: [AgentWorkFileEntry] = []
  @State private var nextAfter: String?
  @State private var phase: Phase = .loading

  private enum Phase: Equatable {
    case loading, loaded, unavailable, noWork, problem(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Search files", text: $query)
        .textFieldStyle(.roundedBorder)
      if !path.isEmpty, query.isEmpty {
        Button {
          path = parent(of: path)
        } label: {
          Label(path, systemImage: "chevron.left")
            .lineLimit(1)
            .truncationMode(.head)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      content
    }
    .padding(12)
    .frame(width: 320, height: 300, alignment: .top)
    .task(id: "\(sessionID ?? 0)|\(path)|\(query)") {
      await load(after: nil)
    }
  }

  @ViewBuilder
  private var content: some View {
    switch phase {
    case .loading where entries.isEmpty:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    case .noWork:
      message("Files appear once the agent has started work in this thread.")
    case .unavailable:
      message("This agent can't list its folder yet. Update the Inline CLI on its machine.")
    case let .problem(text):
      message(text)
    default:
      if entries.isEmpty {
        message(query.isEmpty ? "This folder is empty." : "No matching files.")
      } else {
        List {
          ForEach(entries) { entry in
            Button {
              if entry.isDirectory, query.isEmpty {
                path = entry.relativePath
              } else {
                select(entry)
              }
            } label: {
              Label(query.isEmpty ? entry.name : entry.relativePath, systemImage: entry.isDirectory ? "folder" : "doc")
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .buttonStyle(.plain)
          }
          if let nextAfter {
            Button("Show more") { Task { await load(after: nextAfter) } }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
          }
        }
        .listStyle(.plain)
      }
    }
  }

  private func message(_ text: LocalizedStringKey) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .multilineTextAlignment(.center)
  }

  private func message(_ text: String) -> some View {
    message(LocalizedStringKey(text))
  }

  private func parent(of path: String) -> String {
    var components = path.split(separator: "/")
    _ = components.popLast()
    return components.joined(separator: "/")
  }

  @MainActor
  private func load(after: String?) async {
    guard let sessionID else {
      phase = .noWork
      return
    }
    if after == nil {
      // Debounce typing; a newer task cancels this one.
      if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
      guard !Task.isCancelled else { return }
      phase = .loading
    }
    do {
      let page = try await AgentWorkFiles.listing.list(
        peer: peer,
        botUserID: botUserID,
        agentSessionID: sessionID,
        relativePath: path,
        query: query.isEmpty ? nil : query,
        after: after,
        limit: 100
      )
      guard !Task.isCancelled else { return }
      entries = after == nil ? page.entries : entries + page.entries
      nextAfter = page.nextAfter
      phase = .loaded
    } catch AgentWorkFilesError.unavailable {
      phase = .unavailable
    } catch let AgentWorkFilesError.problem(text) {
      phase = .problem(text)
    } catch {
      guard !Task.isCancelled else { return }
      phase = .problem(String(localized: "Couldn't list files. Try again."))
    }
  }
}
