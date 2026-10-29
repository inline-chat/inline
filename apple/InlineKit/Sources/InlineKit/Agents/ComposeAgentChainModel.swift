import Combine
import Foundation
import InlineProtocol
import Observation

/// Where Agent control failures show; each app points this at its toasts.
@MainActor
public enum AgentControlErrors {
  public static var report: @MainActor (String) -> Void = { _ in }
}

/// Agent controls for the thread Compose, shared by macOS and iOS.
///
/// While the draft would reach an Agent in Detailed mode, Compose shows the
/// Agent, its folder, context, model and reasoning, like the empty-page
/// Compose. Friendly mode shows nothing, and the plus menu can
/// hide the row. A stop or resume circle sits beside the send button while an
/// Agent's turn runs in this chat. The output mode itself is never set here;
/// it lives in the toolbar's Agent Settings.
@MainActor
public final class ComposeAgentChainModel: ObservableObject {
  private static let hiddenDefaultsKey = "compose.agentControls.hidden"

  /// Where the chain reads and writes this thread's Agent configuration.
  public enum Source: Equatable {
    /// The thread's server-side Agent preset (`Chat.agentContext`).
    case agentThread
    /// The Agent's own per-chat settings document, published by its bridge.
    case agentSettings
  }

  @Published public private(set) var target: AgentComposeTarget?
  @Published public private(set) var source: Source?
  /// The draft would reach an Agent in Detailed mode.
  @Published public private(set) var isEligible = false
  /// Eligible and not hidden from the plus menu: the row shows.
  @Published public private(set) var isAvailable = false
  @Published public private(set) var isHidden: Bool
  /// The Agent work the stop or resume circle controls: the target's when it
  /// runs or is paused, else any running in this chat.
  @Published public private(set) var runWork: AgentWorkState?
  @Published public private(set) var botUserInfo: UserInfo?
  @Published public private(set) var catalog: AgentConfigurationCatalogSnapshot?

  public let peer: Peer
  public let chatID: Int64?
  public let threadModel: AgentThreadToolbarModel
  public private(set) var settings: BotChatSettingsCoordinator?

  private let database: AppDatabase
  private let updateAgentContext: @Sendable (InlineProtocol.AgentThreadContext) async throws -> Void
  private let directMessageBotUserID: Int64?
  private var leadingMentionUserIDs: [Int64] = []
  private var replyToUserID: Int64?
  private var cancellables: Set<AnyCancellable> = []
  private var catalogTask: Task<Void, Never>?
  private var settingsTask: Task<Void, Never>?
  private var isStarted = false

  public init(
    peer: Peer,
    chatID: Int64?,
    peerUser: User?,
    database: AppDatabase,
    updateAgentContext: @escaping @Sendable (InlineProtocol.AgentThreadContext) async throws -> Void
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

  public func start() {
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
        Task { @MainActor [weak self] in self?.refreshRunWork() }
      }
      .store(in: &cancellables)
    resolve()
    refreshRunWork()
  }

  public func stop() {
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
  public func updateDraft(_ text: NSAttributedString) {
    let ids = AgentComposeTargetResolver.leadingMentionUserIDs(in: text)
    guard ids != leadingMentionUserIDs else { return }
    leadingMentionUserIDs = ids
    resolve()
  }

  public func updateReply(toUserID userID: Int64?) {
    guard replyToUserID != userID else { return }
    replyToUserID = userID
    resolve()
  }

  /// From the plus menu; remembered for every chat.
  public func toggleHidden() {
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
    // Paused work keeps its resume circle without a mention in the draft.
    let next = targetState.flatMap { $0.runState.isActive || $0.runState == .paused ? $0 : nil }
      ?? states.first(where: { $0.runState.isActive })
      ?? states.first(where: { $0.runState == .paused })
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

  public func prepareUsage() {
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

  public func outputMode(for botUserID: Int64) -> AgentThreadOutputMode {
    // The thread's override, else the agent's default; both are synced and
    // cached locally, so this is right on the first frame.
    AgentWorkStateStore.shared.outputMode(peer: peer, botUserID: botUserID)
  }

  // MARK: Presentation

  public var settingsDocument: BotChatSettingsModel.Document? {
    guard let settings, let target, settings.selectedBotID == target.botUserID else { return nil }
    return settings.selectedState.document
  }

  public var settingsState: BotChatSettingsBotState? {
    guard let settings, let target, settings.selectedBotID == target.botUserID else { return nil }
    return settings.selectedState
  }

  public var agentName: String {
    botUserInfo?.user.firstName ?? botUserInfo?.user.displayName ?? "Agent"
  }

  public var canEdit: Bool {
    switch source {
    case .agentThread: threadModel.canEdit && !threadModel.isUpdating
    case .agentSettings: settingsDocument != nil && settings?.isMutating != true
    case nil: false
    }
  }

  public var projectTitle: String? {
    switch source {
    case .agentThread:
      return threadModel.projectTitle
    case .agentSettings:
      return settingsDocument?.folderTitle
    case nil:
      return nil
    }
  }

  /// Where the folder lives, for the read-only folder's tooltip.
  public var projectDetail: String? {
    guard source == .agentSettings else { return nil }
    return settingsDocument?.item(ComposeAgentSettingsItem.folder)?.description
  }

  public var projectOptions: [AgentConfigurationOption] {
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

  /// The Agent has no work in this chat yet, so its next message starts a
  /// session and the folder is still a real choice. iOS shows the folder in
  /// the row only then; afterwards it lives in the header.
  public var isBeforeFirstTurn: Bool {
    guard let target else { return false }
    return !AgentWorkStateStore.shared.states(peer: peer).contains { $0.key.botUserID == target.botUserID }
  }

  public var selectedProjectID: String? {
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

  public var modelTitle: String? {
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

  public var modelOptions: [AgentModelConfigurationOption] {
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

  public var selectedModelID: String? {
    switch source {
    case .agentThread: threadModel.explicitModelID
    case .agentSettings: selectedValue(ComposeAgentSettingsItem.model)
    case nil: nil
    }
  }

  public var automaticModelTitle: String? {
    switch source {
    case .agentThread: threadModel.automaticModelTitle
    case .agentSettings: settingsDocument == nil ? nil : catalog?.automaticModelTitle
    case nil: nil
    }
  }

  public var reasoningTitle: String? {
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

  public var reasoningOptions: [AgentConfigurationOption] {
    switch source {
    case .agentThread: threadModel.availableReasoningOptions ?? []
    case .agentSettings: selectOptions(ComposeAgentSettingsItem.reasoning)
    case nil: []
    }
  }

  public var selectedReasoningID: String? {
    switch source {
    case .agentThread: threadModel.explicitReasoningID
    case .agentSettings: selectedValue(ComposeAgentSettingsItem.reasoning)
    case nil: nil
    }
  }

  public var automaticReasoningTitle: String? {
    switch source {
    case .agentThread: threadModel.automaticReasoningTitle
    case .agentSettings:
      settingsDocument == nil ? nil : catalog?.automaticReasoningTitle(forModelID: effectiveSettingsModelID)
    case nil: nil
    }
  }

  // MARK: Writes (apply to this thread from the next message on)

  public func selectProject(_ id: String?) {
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

  public func selectModel(_ id: String?) {
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

  public func selectReasoning(_ id: String?) {
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
  public struct UsageWindow: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let usedPercent: Int
    public let resetsAt: Date?
  }

  /// How full this thread's context window is.
  public struct ContextFill: Equatable {
    public let used: Int
    public let window: Int
    public var fraction: Double { window > 0 ? min(1, Double(used) / Double(window)) : 0 }
  }

  /// 5-hour, weekly and other limits. Bridge v2 carries the numbers in each
  /// item's ID: `account.usage.window:<minutes>:<used %>:<resets at>:<index>`.
  public var usageWindows: [UsageWindow] {
    allItems.compactMap { item in
      let parts = item.id.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count >= 4, parts[0] == ComposeAgentSettingsItem.usageWindow,
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
  public var contextFill: ContextFill? {
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
  public var usageItem: BotChatSettingsModel.Item? {
    settingsDocument?.item(ComposeAgentSettingsItem.usage)
  }

  private var allItems: [BotChatSettingsModel.Item] {
    settingsDocument?.sections.flatMap(\.items) ?? []
  }

  // MARK: Stop and resume

  @Published public private(set) var isControlling = false

  public func runWorkName(_ work: AgentWorkState) -> String {
    ObjectCache.shared.getCachedUser(id: work.key.botUserID)?.user.firstName ?? String(localized: "Agent")
  }

  /// Nil when the viewer may stop or resume this work; grants not loaded
  /// yet count as allowed and the server decides.
  public func controlDisabledReason(_ work: AgentWorkState) -> String? {
    let access = AgentGrantStore.shared.access(botUserID: work.key.botUserID)
    return MessageActionPresentation.disabledReason(
      requirement: .steer,
      access: access,
      ownerName: access.flatMap { ObjectCache.shared.getCachedUser(id: $0.ownerUserID)?.user.firstName },
      botName: runWorkName(work)
    )
  }

  /// Stops a running turn, or resumes paused work.
  public func toggleRun() {
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
        AgentControlErrors.report(error.localizedDescription)
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
public enum ComposeAgentSettingsItem {
  public static let model = "agent.model"
  public static let reasoning = "agent.reasoning"
  public static let folder = "workspace.folder"
  public static let project = "workspace.project"
  public static let usage = "account.usage"
  public static let usageWindow = "account.usage.window"
  public static let context = "session.context"
  /// The select value meaning "the harness's own default".
  public static let defaultValue = "__inline_provider_default__"
}

public extension BotChatSettingsModel.Document {
  func item(_ id: String) -> BotChatSettingsModel.Item? {
    for section in sections {
      if let item = section.items.first(where: { $0.id == id }) { return item }
    }
    return nil
  }

  /// The folder the Agent works in for this chat, as its bridge reports it.
  var folderTitle: String? {
    if let item = item(ComposeAgentSettingsItem.project), case let .select(value, options) = item.control {
      return options.first(where: { $0.value == value })?.label
    }
    let folder = item(ComposeAgentSettingsItem.folder)
    if let presentation = folder?.control.folderPresentation {
      return presentation.selectedFolder.label
    }
    // Bridge v2 shows its working folder read-only.
    if case let .info(text, _)? = folder?.control { return text }
    return nil
  }
}

public enum ComposeAgentTokens {
  /// "850", "439k", "1.2M".
  public static func text(_ tokens: Int) -> String {
    switch tokens {
    case ..<1000: "\(tokens)"
    case ..<1_000_000: "\(tokens / 1000)k"
    default: (Double(tokens) / 1_000_000).formatted(.number.precision(.fractionLength(0 ... 1))) + "M"
    }
  }
}
