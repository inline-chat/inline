import Combine
import GRDB
import InlineKit
import InlineMacUI
import InlineProtocol
import InlineUI
import Observation
import SwiftUI

/// Agent controls for the thread Compose.
///
/// While the draft would reach an Agent in Detailed mode, a quiet row under
/// the editor shows the Agent, its folder, context, model and reasoning, like
/// the empty-page Compose. Friendly mode shows nothing, and the plus menu can
/// hide the row. A stop or resume circle sits beside the send button while an
/// Agent's turn runs in this chat. The output mode itself is never set here;
/// it lives in the toolbar's Agent Settings.
@MainActor
final class ComposeAgentChainModel: ObservableObject {
  private static let hiddenDefaultsKey = "compose.agentControls.hidden"

  /// Where the chain reads and writes this thread's Agent configuration.
  enum Source: Equatable {
    /// The thread's server-side Agent preset (`Chat.agentContext`).
    case agentThread
    /// The Agent's own per-chat settings document, published by its bridge.
    case agentSettings
  }

  @Published private(set) var target: AgentComposeTarget?
  @Published private(set) var source: Source?
  /// The draft would reach an Agent in Detailed mode.
  @Published private(set) var isEligible = false
  /// Eligible and not hidden from the plus menu: the row shows.
  @Published private(set) var isAvailable = false
  @Published private(set) var isHidden: Bool
  /// The Agent work the stop or resume circle controls: the target's when it
  /// runs or is paused, else any running in this chat.
  @Published private(set) var runWork: AgentWorkState?
  @Published private(set) var botUserInfo: UserInfo?
  @Published private(set) var catalog: AgentConfigurationCatalogSnapshot?

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
    isHidden = UserDefaults.standard.bool(forKey: Self.hiddenDefaultsKey)
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
          // Thread preset and catalog changes re-render the row.
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
    store.objectWillChange
      .sink { [weak self] in
        // objectWillChange fires before the store changes.
        DispatchQueue.main.async { self?.refreshRunWork() }
      }
      .store(in: &cancellables)
    resolve()
    refreshRunWork()
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

  /// From the plus menu; remembered for every chat.
  func toggleHidden() {
    isHidden.toggle()
    UserDefaults.standard.set(isHidden, forKey: Self.hiddenDefaultsKey)
    refreshAvailability()
  }

  // MARK: Run state

  private var targetWasActive = false

  private func refreshRunWork() {
    let states = AgentWorkStateStore.shared.states(peer: peer)
    let targetState = target.flatMap { target in
      states.first(where: { $0.key.botUserID == target.botUserID })
    }
    let next = targetState.flatMap { $0.runState.isActive || $0.runState == .paused ? $0 : nil }
      ?? states.first(where: { $0.runState.isActive })
    if next != runWork {
      runWork = next
      if let next { AgentGrantStore.shared.ensureLoaded(botUserID: next.key.botUserID) }
    }
    // A finished turn changes the context fill and usage: read them again.
    let targetActive = targetState?.runState.isActive == true
    if targetWasActive, !targetActive, settingsDocument != nil {
      settings?.refreshSelected()
    }
    targetWasActive = targetActive
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
    if targetChanged {
      loadTarget()
      refreshRunWork()
    }
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
    // Both sources read the folder, context and usage from the settings.
    prepareSettings(for: botUserID)
  }

  /// The Agent's bridge publishes this chat's model, reasoning, folder,
  /// context and usage in its settings document. Agent threads keep model
  /// and reasoning in the server preset.
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
    if settingsDocument == nil {
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
    let eligible = computeAvailability()
    if eligible != isEligible { isEligible = eligible }
    let available = eligible && !isHidden
    if available != isAvailable { isAvailable = available }
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
      let folder = settingsDocument?.item(ComposeAgentSettingsItem.folder)
      if let presentation = folder?.control.folderPresentation {
        return presentation.selectedFolder.label
      }
      // Bridge v2 shows its working folder read-only.
      if case let .info(text, _)? = folder?.control { return text }
      return nil
    case nil:
      return nil
    }
  }

  /// Where the folder lives, for the read-only folder's tooltip.
  var projectDetail: String? {
    guard source == .agentSettings else { return nil }
    return settingsDocument?.item(ComposeAgentSettingsItem.folder)?.description
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
      return catalog?.modelTitle(forModelID: effectiveSettingsModelID) ?? selectedLabel(ComposeAgentSettingsItem.model)
    case nil:
      return nil
    }
  }

  /// The model this thread runs: its choice, else the harness's default.
  private var effectiveSettingsModelID: String? {
    selectedValue(ComposeAgentSettingsItem.model) ?? catalog?.defaultModelID
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
    switch source {
    case .agentThread: threadModel.automaticModelTitle
    case .agentSettings: settingsDocument == nil ? nil : catalog?.automaticModelTitle
    case nil: nil
    }
  }

  var reasoningTitle: String? {
    switch source {
    case .agentThread:
      return threadModel.reasoningTitle
    case .agentSettings:
      if let title = selectedLabel(ComposeAgentSettingsItem.reasoning) { return title }
      guard let catalog, let id = catalog.defaultReasoningEffortID(forModelID: effectiveSettingsModelID) else { return nil }
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
    switch source {
    case .agentThread: threadModel.automaticReasoningTitle
    case .agentSettings:
      settingsDocument == nil ? nil : catalog?.automaticReasoningTitle(forModelID: effectiveSettingsModelID)
    case nil: nil
    }
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
      settings?.invoke(itemID: ComposeAgentSettingsItem.model, value: .string(id ?? ComposeAgentSettingsItem.defaultValue))
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
      settings?.invoke(itemID: ComposeAgentSettingsItem.reasoning, value: .string(id ?? ComposeAgentSettingsItem.defaultValue))
    case nil:
      break
    }
  }

  // MARK: Usage

  /// One usage limit, as the bridge publishes it.
  struct UsageWindow: Identifiable, Equatable {
    let id: String
    let title: String
    let usedPercent: Int
    let resetsAt: Date?
  }

  /// How full this thread's context window is.
  struct ContextFill: Equatable {
    let used: Int
    let window: Int
    var fraction: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }
  }

  /// 5-hour, weekly and other limits. Bridge v2 carries the numbers in each
  /// item's ID: `account.usage.window:<minutes>:<used %>:<resets at>`.
  var usageWindows: [UsageWindow] {
    allItems.compactMap { item in
      let parts = item.id.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 4, parts[0] == ComposeAgentSettingsItem.usageWindow,
            let used = Int(parts[2]), let resets = Int(parts[3])
      else { return nil }
      return UsageWindow(
        id: item.id,
        title: item.label ?? String(localized: "Limit"),
        usedPercent: min(100, max(0, used)),
        resetsAt: resets > 0 ? Date(timeIntervalSince1970: TimeInterval(resets)) : nil
      )
    }
  }

  /// `session.context:<used tokens>:<window>`, once a turn reported it.
  var contextFill: ContextFill? {
    for item in allItems {
      let parts = item.id.split(separator: ":")
      guard parts.count == 3, parts[0] == ComposeAgentSettingsItem.context,
            let used = Int(parts[1]), let window = Int(parts[2]), window > 0
      else { continue }
      return ContextFill(used: used, window: window)
    }
    return nil
  }

  /// A v1 bridge's one-line usage summary.
  var usageItem: BotChatSettingsModel.Item? {
    settingsDocument?.item(ComposeAgentSettingsItem.usage)
  }

  private var allItems: [BotChatSettingsModel.Item] {
    settingsDocument?.sections.flatMap(\.items) ?? []
  }

  // MARK: Stop and resume

  @Published private(set) var isControlling = false

  func runWorkName(_ work: AgentWorkState) -> String {
    ObjectCache.shared.getCachedUser(id: work.key.botUserID)?.user.firstName ?? String(localized: "Agent")
  }

  /// Nil when the viewer may stop or resume this work; grants not loaded
  /// yet count as allowed and the server decides.
  func controlDisabledReason(_ work: AgentWorkState) -> String? {
    let access = AgentGrantStore.shared.access(botUserID: work.key.botUserID)
    return MessageActionPresentation.disabledReason(
      requirement: .steer,
      access: access,
      ownerName: access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user.firstName },
      botName: runWorkName(work)
    )
  }

  /// Stops a running turn, or resumes paused work.
  func toggleRun() {
    guard let work = runWork, !isControlling, work.runState != .stopping else { return }
    let op: InlineProtocol.AgentSessionControl = work.runState == .paused ? .resume : .stop
    isControlling = true
    Task { @MainActor [weak self] in
      defer { self?.isControlling = false }
      do {
        _ = try await Api.realtime.callRpcDirect(
          method: .controlAgentSession,
          input: .controlAgentSession(.with {
            $0.agentSessionID = work.sessionID
            $0.op = op
          })
        )
      } catch {
        ToastCenter.shared.showError(error.localizedDescription)
      }
    }
  }

  /// The harness's "Default" choice is the menu's "Use default — …" row,
  /// so it is left out of the options and reads as no selection.
  private func selectOptions(_ itemID: String) -> [AgentConfigurationOption] {
    guard case let .select(_, options)? = settingsDocument?.item(itemID)?.control else { return [] }
    return options.filter { !$0.isDisabled && $0.value != ComposeAgentSettingsItem.defaultValue }.map {
      AgentConfigurationOption(id: $0.value, label: $0.label, description: $0.description)
    }
  }

  private func selectedValue(_ itemID: String) -> String? {
    guard case let .select(value, _)? = settingsDocument?.item(itemID)?.control,
          value != ComposeAgentSettingsItem.defaultValue
    else { return nil }
    return value
  }

  private func selectedLabel(_ itemID: String) -> String? {
    guard let value = selectedValue(itemID),
          case let .select(_, options)? = settingsDocument?.item(itemID)?.control
    else { return nil }
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
  static let usageWindow = "account.usage.window"
  static let context = "session.context"
  /// The select value meaning "the harness's own default".
  static let defaultValue = "__inline_provider_default__"
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

/// The row under the editor: the Agent and its folder at the leading edge;
/// context, model and reasoning at the trailing edge, as in the empty-page
/// Compose. A change applies to this Agent's work in this thread from the
/// next message on.
@available(macOS 26.0, *)
struct ComposeAgentChainBar: View {
  @ObservedObject var model: ComposeAgentChainModel

  var body: some View {
    if model.isAvailable {
      HStack(spacing: 2) {
        if let userInfo = model.botUserInfo {
          UserAvatar(userInfo: userInfo, size: 16)
            .frame(width: 24, height: 24)
            .inlineTooltip(
              verbatim: userInfo.user.displayName,
              description: "Gets this message and these settings. Start your message with another agent's mention to switch.",
              placement: .above
            )
            .accessibilityLabel("Agent: \(userInfo.user.displayName)")
        }

        if let title = model.projectTitle {
          if model.projectOptions.isEmpty {
            AllChatsComposePillLabel(title: title, systemImage: "folder")
              .fixedSize(horizontal: true, vertical: true)
              .inlineTooltip(
                verbatim: "Folder",
                description: model.projectDetail ?? "The folder this agent works in.",
                placement: .above
              )
          } else {
            AgentConfigurationMenu(
              title: title,
              automaticTitle: nil,
              options: model.projectOptions,
              selection: model.selectedProjectID,
              isDisabled: !model.canEdit,
              tooltipTitle: "Folder",
              tooltipDescription: "Choose the folder for this thread.",
              tooltipPlacement: .above,
              systemImage: "folder",
              select: model.selectProject
            )
          }
        }

        Spacer(minLength: 0)

        ComposeAgentUsageButton(model: model)

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
      }
      .padding(.leading, 6)
      .padding(.trailing, 8)
      .frame(height: 28)
    }
  }
}

/// A small ring for how full this thread's context is, with the numbers in
/// its tooltip. Clicking it shows the account's usage limits.
@available(macOS 26.0, *)
private struct ComposeAgentUsageButton: View {
  @ObservedObject var model: ComposeAgentChainModel
  @State private var isShowingUsage = false

  var body: some View {
    let fill = model.contextFill
    Button {
      model.prepareUsage()
      isShowingUsage.toggle()
    } label: {
      ZStack {
        Circle()
          .stroke(.quaternary, lineWidth: 2)
        if let fill {
          Circle()
            .trim(from: 0, to: fill.fraction)
            .stroke(
              fill.fraction >= 0.9 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary),
              style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
        }
      }
      .frame(width: 12, height: 12)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .inlineTooltip(
      verbatim: fill.map { "Context window: \(Int(($0.fraction * 100).rounded()))% full" } ?? "Usage",
      description: fill.map { "\(ComposeAgentTokens.text($0.used)) / \(ComposeAgentTokens.text($0.window)) tokens used" }
        ?? "Show usage limits.",
      placement: .above
    )
    .accessibilityLabel("Usage")
    .accessibilityValue(fill.map { "Context \(Int(($0.fraction * 100).rounded())) percent full" } ?? "")
    .popover(isPresented: $isShowingUsage, arrowEdge: .bottom) {
      ComposeAgentUsagePopover(model: model)
    }
  }
}

/// The account's limits, one track each, then this thread's context.
@available(macOS 26.0, *)
private struct ComposeAgentUsagePopover: View {
  @ObservedObject var model: ComposeAgentChainModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Usage limits · \(model.agentName)")
        .font(.callout)
        .foregroundStyle(.secondary)
      content
    }
    .padding(14)
    .frame(width: 300, alignment: .leading)
  }

  @ViewBuilder
  private var content: some View {
    let windows = model.usageWindows
    if !windows.isEmpty || model.contextFill != nil {
      ForEach(windows) { window in
        track(
          title: window.title,
          detail: window.resetsAt.map(Self.resetText),
          value: "\(window.usedPercent)%",
          fraction: Double(window.usedPercent) / 100
        )
      }
      if let fill = model.contextFill {
        if !windows.isEmpty { Divider() }
        track(
          title: String(localized: "Context window"),
          detail: "\(ComposeAgentTokens.text(fill.used)) / \(ComposeAgentTokens.text(fill.window))",
          value: "\(Int((fill.fraction * 100).rounded()))%",
          fraction: fill.fraction
        )
      }
    } else if let item = model.usageItem, let description = item.description {
      Text(description)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    } else if let problem = model.settingsState?.problem {
      Label(problem.message, systemImage: "exclamationmark.triangle")
        .font(.callout)
        .foregroundStyle(.secondary)
    } else if model.settingsState?.phase == .loaded {
      Text("No usage reported yet. It shows after \(model.agentName)’s next turn.")
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

  private func track(title: String, detail: String?, value: String, fraction: Double) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(title)
        Spacer(minLength: 8)
        if let detail {
          Text(detail).foregroundStyle(.secondary)
        }
        Text(value)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .font(.callout)
      ProgressView(value: min(1, max(0, fraction)))
        .progressViewStyle(.linear)
        .tint(fraction >= 0.9 ? .orange : .accentColor)
    }
  }

  /// "Resets at 2:30 PM" today, "Resets Tue 9:30 AM" this week, else a date.
  private static func resetText(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) {
      return String(localized: "Resets at \(date.formatted(date: .omitted, time: .shortened))")
    }
    if date.timeIntervalSinceNow < 6 * 24 * 3600 {
      let day = date.formatted(.dateTime.weekday(.abbreviated))
      return String(localized: "Resets \(day) \(date.formatted(date: .omitted, time: .shortened))")
    }
    return String(localized: "Resets \(date.formatted(.dateTime.month(.abbreviated).day()))")
  }
}

enum ComposeAgentTokens {
  /// "850", "439k", "1.2M".
  static func text(_ tokens: Int) -> String {
    switch tokens {
    case ..<1000: "\(tokens)"
    case ..<1_000_000: "\(tokens / 1000)k"
    default: (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(0 ... 1))) + "M"
    }
  }
}

/// The circle beside the send button while an Agent's turn runs in this
/// chat: a quiet stop square, or a play glyph to resume paused work. Sending
/// stays available; a message while it works steers.
@available(macOS 26.0, *)
struct ComposeAgentRunButton: View {
  @ObservedObject var model: ComposeAgentChainModel
  @ObservedObject private var grants = AgentGrantStore.shared
  let size: CGFloat

  var body: some View {
    if let work = model.runWork {
      let paused = work.runState == .paused
      let name = model.runWorkName(work)
      let disabledReason = model.controlDisabledReason(work)
      Button(action: model.toggleRun) {
        Image(systemName: paused ? "play.fill" : "stop.fill")
          .font(.system(size: size * 0.3, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: size, height: size)
        .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .glassEffect(.regular.interactive(), in: .circle)
      .disabled(disabledReason != nil || model.isControlling || work.runState == .stopping)
      .inlineTooltip(
        verbatim: paused ? "Resume \(name)" : (work.runState == .stopping ? "Stopping \(name)…" : "Stop \(name)"),
        description: disabledReason ?? (paused ? "Continue the paused work." : "Sending a message still works; it steers the turn."),
        placement: .above
      )
      .accessibilityLabel(paused ? "Resume \(name)" : "Stop \(name)")
    }
  }
}
