import AppKit
import Combine
import GRDB
import InlineKit
import InlineMacUI
import InlineProtocol
import InlineUI
import Logger
import os.signpost
import RealtimeV2
import SwiftUI

struct AllChatsComposeSpace: Identifiable, Equatable {
  let id: Int64
  let title: String
}

struct AllChatsAgentChoice: Identifiable, Equatable {
  let bot: InlineProtocol.User
  let agent: InlineProtocol.BotAgent?

  var id: String {
    "\(bot.id):\(agent?.id ?? 0)"
  }

  var title: String {
    agent?.name ?? InlineKit.User(from: bot).displayName
  }

  var providerTitle: String? {
    agent == nil ? nil : InlineKit.User(from: bot).displayName
  }
}

private struct AllChatsAgentMentionTarget: Equatable {
  let botUserID: Int64
  let agentID: Int64?
}

private struct AllChatsComposeAgentConfiguration: Equatable {
  let projectID: String?
  let modelID: String?
  let reasoningID: String?
}

enum AllChatsNewThreadComposePlacement {
  case top
  case bottom

  var tooltipPlacement: InlineTooltipPlacement {
    switch self {
      case .top: .below
      case .bottom: .above
    }
  }

  var completionMenuPlacement: GlassComposeCompletionMenuPlacement {
    switch self {
      case .top: .below
      case .bottom: .above
    }
  }
}

private struct AllChatsComposePreferences {
  private let defaults: UserDefaults
  private let destinationKey: String
  private let visibilityKey: String
  private let sendSilentlyKey: String
  private let agentConfigurationPrefix: String
  private let agentChoiceKey: String

  init(userID: Int64?, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let account = userID.map(String.init) ?? "signed-out"
    destinationKey = "macos.allChats.newThread.destination.\(account)"
    visibilityKey = "macos.allChats.newThread.public.\(account)"
    sendSilentlyKey = "macos.allChats.newThread.sendSilently.\(account)"
    agentConfigurationPrefix = "macos.allChats.newThread.agentConfiguration.\(account)"
    agentChoiceKey = "macos.allChats.newThread.agentChoice.\(account)"
  }

  var agentChoiceID: String? {
    defaults.string(forKey: agentChoiceKey)
  }

  func saveAgentChoice(_ id: String?) {
    save(id, forKey: agentChoiceKey)
  }

  var destinationSpaceID: Int64? {
    guard let value = defaults.string(forKey: destinationKey),
          value.hasPrefix("space:"),
          let id = Int64(value.dropFirst("space:".count))
    else {
      return nil
    }
    return id
  }

  var isHome: Bool {
    defaults.string(forKey: destinationKey) == "home"
  }

  var visibility: NewThreadComposeDestination.SpaceVisibility {
    defaults.bool(forKey: visibilityKey) ? .public : .private
  }

  var sendSilently: Bool {
    defaults.bool(forKey: sendSilentlyKey)
  }

  func save(destination: NewThreadComposeDestination) {
    if let spaceID = destination.spaceID {
      defaults.set("space:\(spaceID)", forKey: destinationKey)
    } else {
      defaults.set("home", forKey: destinationKey)
    }
  }

  func save(visibility: NewThreadComposeDestination.SpaceVisibility) {
    defaults.set(visibility == .public, forKey: visibilityKey)
  }

  func save(sendSilently: Bool) {
    defaults.set(sendSilently, forKey: sendSilentlyKey)
  }

  func agentConfiguration(for choice: AllChatsAgentChoice) -> AllChatsComposeAgentConfiguration {
    AllChatsComposeAgentConfiguration(
      projectID: defaults.string(forKey: agentConfigurationKey("project", choice: choice)),
      modelID: defaults.string(forKey: agentConfigurationKey("model", choice: choice)),
      reasoningID: defaults.string(forKey: agentConfigurationKey("reasoning", choice: choice))
    )
  }

  func saveAgentConfiguration(
    _ configuration: AllChatsComposeAgentConfiguration,
    for choice: AllChatsAgentChoice
  ) {
    save(configuration.projectID, forKey: agentConfigurationKey("project", choice: choice))
    save(configuration.modelID, forKey: agentConfigurationKey("model", choice: choice))
    save(configuration.reasoningID, forKey: agentConfigurationKey("reasoning", choice: choice))
  }

  private func agentConfigurationKey(_ field: String, choice: AllChatsAgentChoice) -> String {
    "\(agentConfigurationPrefix).\(choice.bot.id).\(choice.agent?.id ?? 0).\(field)"
  }

  private func save(_ value: String?, forKey key: String) {
    if let value {
      defaults.set(value, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

private struct AllChatsComposeAccessMentions: Equatable {
  var userIDs: Set<Int64> = []
  var groupIDs: Set<Int64> = []
  var userNamesByID: [Int64: String] = [:]
  var groupNamesByID: [Int64: String] = [:]

  init(text: String = "", entities: MessageEntities? = nil) {
    let nsText = text as NSString
    for entity in entities?.entities ?? [] {
      if entity.type == .mention, entity.mention.userID > 0 {
        userIDs.insert(entity.mention.userID)
        userNamesByID[entity.mention.userID] = Self.displayName(for: entity, in: nsText)
      } else if entity.type == .groupMention, entity.groupMention.groupID > 0 {
        groupIDs.insert(entity.groupMention.groupID)
        groupNamesByID[entity.groupMention.groupID] = Self.displayName(for: entity, in: nsText)
      }
    }
  }

  private static func displayName(for entity: MessageEntity, in text: NSString) -> String? {
    guard let location = Int(exactly: entity.offset),
          let length = Int(exactly: entity.length),
          location >= 0,
          length > 0,
          location <= text.length,
          length <= text.length - location
    else {
      return nil
    }

    let entityText = text.substring(with: NSRange(location: location, length: length))
    let withoutSigil = entityText.hasPrefix("@") ? String(entityText.dropFirst()) : entityText
    let name = withoutSigil.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
  }
}

@MainActor
final class AllChatsNewThreadComposeModel: ObservableObject {
  @Published private(set) var destination: NewThreadComposeDestination
  @Published private(set) var spaces: [AllChatsComposeSpace]
  @Published private(set) var lockedSpaceID: Int64?
  @Published private(set) var visibilityTooltipTitle = String(localized: "Private thread")
  @Published private(set) var visibilityTooltipDescription = String(
    localized: "Only you can access this thread. Mention people or groups to add them."
  )
  @Published private(set) var composeHeight: CGFloat = 42
  @Published private(set) var isSubmitting = false
  private(set) var sendSilently: Bool
  @Published private(set) var agentChoices: [AllChatsAgentChoice] = []
  @Published private(set) var agentPickerEnabled = ExperimentalFeatureFlags.newThreadAgentPickerEnabled
  @Published private(set) var isLoadingAgentChoices = false
  @Published private(set) var agentChoicesLoadFailed = false
  @Published private(set) var selectedAgentChoiceID: String?
  @Published private(set) var agentCatalog: AgentConfigurationCatalogSnapshot?
  @Published private(set) var selectedProjectID: String?
  @Published private(set) var selectedModelID: String?
  @Published private(set) var selectedReasoningID: String?

  let dependencies: AppDependencies

  private let attachmentStore = NewThreadComposeAttachmentStore()
  private let log = Log.scoped("AllChatsNewThreadCompose")
  private let performanceLog = OSLog(subsystem: "InlineMac", category: "PointsOfInterest")
  private let mentionSource: DefaultNewThreadComposeMentionSource
  private let preferences: AllChatsComposePreferences
  private var lastSpaceVisibility: NewThreadComposeDestination.SpaceVisibility
  private var accessMentions = AllChatsComposeAccessMentions()
  private var mentionedAgentTargets: [AllChatsAgentMentionTarget] = []
  private var lastMentionedAgentChoiceID: String?
  private var observedAgentChoiceID: String?
  private var agentCatalogTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()

  init(
    dependencies: AppDependencies,
    spaces: [AllChatsComposeSpace],
    initialSpaceID: Int64?
  ) {
    self.dependencies = dependencies
    self.spaces = spaces
    lockedSpaceID = initialSpaceID
    let preferences = AllChatsComposePreferences(userID: dependencies.auth.currentUserId)
    self.preferences = preferences
    observedAgentChoiceID = preferences.agentChoiceID
    sendSilently = preferences.sendSilently
    lastSpaceVisibility = preferences.visibility
    let persistedSpaceID = preferences.isHome ? nil : preferences.destinationSpaceID
    let restoredSpaceID = persistedSpaceID.flatMap { spaceID in
      spaces.isEmpty || spaces.contains(where: { $0.id == spaceID }) ? spaceID : nil
    }
    let initialDestination: NewThreadComposeDestination = (initialSpaceID ?? restoredSpaceID).map {
      .space(id: $0, visibility: preferences.visibility)
    } ?? .home
    destination = initialDestination
    mentionSource = DefaultNewThreadComposeMentionSource(
      db: dependencies.database,
      destination: initialDestination
    )
    mentionSource.candidateUpdates
      .sink { [weak self] _ in
        guard let self else { return }
        updateVisibilityTooltip()
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: .botAgentsChanged)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          await self?.loadAgentChoices()
        }
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        let enabled = ExperimentalFeatureFlags.newThreadAgentPickerEnabled
        let choiceID = preferences.agentChoiceID
        guard enabled != agentPickerEnabled || choiceID != observedAgentChoiceID else { return }
        observedAgentChoiceID = choiceID
        agentPickerEnabled = enabled
        applyFirstAgentMentionIfNeeded()
        updateVisibilityTooltip()
      }
      .store(in: &cancellables)
  }

  var destinationTitle: String {
    guard let spaceID = destination.spaceID else { return "Home" }
    return spaces.first(where: { $0.id == spaceID })?.title ?? "Space"
  }

  var isDestinationLocked: Bool {
    lockedSpaceID != nil
  }

  var destinationTooltipDescription: String {
    if isDestinationLocked {
      return String(
        localized: "All Chats is filtered to \(destinationTitle). Change the All Chats view or go Home to choose another destination.",
        comment: "Tooltip for a new-thread destination locked to the currently filtered All Chats space. The variable is a space name."
      )
    }
    return String(localized: "Choose Home or a space for the new thread.")
  }

  var showsVisibility: Bool {
    destination.spaceID != nil
  }

  var isPublic: Bool {
    destination.isPublic
  }

  var selectedAgentChoice: AllChatsAgentChoice? {
    agentChoices.first { $0.id == selectedAgentChoiceID }
  }

  var rememberedAgentChoiceID: String? {
    preferences.agentChoiceID
  }

  var agentPickerTitle: String {
    if let choice = selectedAgentChoice { return choice.title }
    guard rememberedAgentChoiceID != nil else { return "None" }
    return isLoadingAgentChoices ? "Loading…" : "Unavailable agent"
  }

  var effectiveProjectID: String? {
    selectedProjectID ?? agentCatalog?.defaultProjectID
  }

  var effectiveModelID: String? {
    selectedModelID ?? agentCatalog?.defaultModelID
  }

  var effectiveReasoningID: String? {
    selectedReasoningID ?? agentCatalog?.defaultReasoningEffortID(forModelID: effectiveModelID)
  }

  var projectTitle: String? {
    selectedLabel(effectiveProjectID, in: agentCatalog?.projects)
  }

  var modelTitle: String? {
    guard let effectiveModelID else { return nil }
    return agentCatalog?.models?.first(where: { $0.id == effectiveModelID })?.label ?? selectedModelID
  }

  var reasoningTitle: String? {
    selectedLabel(effectiveReasoningID, in: availableReasoningOptions)
  }

  var automaticProjectTitle: String? {
    automaticTitle(agentCatalog?.defaultProjectID, in: agentCatalog?.projects)
  }

  var automaticModelTitle: String? {
    guard let defaultModelID = agentCatalog?.defaultModelID,
          let label = agentCatalog?.models?.first(where: { $0.id == defaultModelID })?.label
    else { return nil }
    return automaticTitle(label)
  }

  var automaticReasoningTitle: String? {
    automaticTitle(
      agentCatalog?.defaultReasoningEffortID(forModelID: effectiveModelID),
      in: availableReasoningOptions
    )
  }

  var availableReasoningOptions: [AgentConfigurationOption]? {
    guard let reasoning = agentCatalog?.reasoning else { return nil }
    guard let models = agentCatalog?.models else { return reasoning }
    guard let model = models.first(where: { $0.id == effectiveModelID }) else { return nil }
    guard !model.reasoningEffortIDs.isEmpty else { return reasoning }
    let supported = Set(model.reasoningEffortIDs)
    return reasoning.filter { supported.contains($0.id) }
  }

  var agentThreadContext: InlineProtocol.AgentThreadContext? {
    guard let choice = selectedAgentChoice else { return nil }
    return .with {
      $0.botUserID = choice.bot.id
      if let agent = choice.agent { $0.agentID = agent.id }
      if effectiveProjectID != nil || selectedModelID != nil || selectedReasoningID != nil {
        $0.configuration = .with {
          if let effectiveProjectID { $0.projectID = effectiveProjectID }
          if let selectedModelID { $0.modelID = selectedModelID }
          if let selectedReasoningID { $0.reasoningEffortID = selectedReasoningID }
        }
      }
    }
  }

  func updateSpaces(_ spaces: [AllChatsComposeSpace]) {
    self.spaces = spaces
    if let lockedSpaceID {
      setDestination(.space(id: lockedSpaceID, visibility: lastSpaceVisibility))
      updateVisibilityTooltip()
      return
    }
    if let spaceID = destination.spaceID,
       !spaces.contains(where: { $0.id == spaceID })
    {
      setDestination(.home)
    } else {
      updateVisibilityTooltip()
    }
  }

  func followSelectedSpace(_ spaceID: Int64?) {
    lockedSpaceID = spaceID
    let next: NewThreadComposeDestination = spaceID.map {
      .space(id: $0, visibility: lastSpaceVisibility)
    } ?? .home
    setDestination(next)
  }

  func selectHome() {
    guard !isDestinationLocked else { return }
    setDestination(.home)
  }

  func selectSpace(_ spaceID: Int64) {
    guard !isDestinationLocked else { return }
    setDestination(.space(id: spaceID, visibility: lastSpaceVisibility))
  }

  func toggleVisibility() {
    guard case let .space(id, visibility) = destination else { return }
    let next: NewThreadComposeDestination.SpaceVisibility = visibility == .private ? .public : .private
    lastSpaceVisibility = next
    preferences.save(visibility: next)
    setDestination(.space(id: id, visibility: next))
  }

  private func setSendSilently(_ enabled: Bool) {
    guard !isSubmitting, sendSilently != enabled else { return }
    sendSilently = enabled
    preferences.save(sendSilently: enabled)
  }

  func loadAgentChoices() async {
    guard !isLoadingAgentChoices else { return }
    isLoadingAgentChoices = true
    agentChoicesLoadFailed = false
    defer { isLoadingAgentChoices = false }
    do {
      let result = try await dependencies.realtimeV2.send(.listBots())
      guard case let .listBots(response) = result else { return }
      var choices: [AllChatsAgentChoice] = []
      for bot in response.bots {
        choices.append(AllChatsAgentChoice(bot: bot, agent: nil))
        let agentsResponse = try? await Api.realtime.callRpcDirect(
          method: .listBotAgents,
          input: .listBotAgents(.with { $0.botUserID = bot.id })
        )
        if case let .listBotAgents(agents)? = agentsResponse {
          choices.append(contentsOf: agents.agents.map { AllChatsAgentChoice(bot: bot, agent: $0) })
        }
      }
      agentChoices = choices
      mentionSource.setAgents(choices.compactMap { choice in
        guard let agent = choice.agent else { return nil }
        let userInfo = ObjectCache.shared.getCachedUser(id: choice.bot.id)
          ?? UserInfo(user: InlineKit.User(from: choice.bot))
        return MentionableBotAgent(agent: agent, botUserInfo: userInfo)
      })
      applyFirstAgentMentionIfNeeded()
      updateVisibilityTooltip()
    } catch {
      agentChoicesLoadFailed = true
      log.error("Could not load Agent choices", error: error)
    }
  }

  func selectAgent(_ id: String?) {
    guard agentPickerEnabled, !isSubmitting,
          id == nil || agentChoices.contains(where: { $0.id == id }) else { return }
    preferences.saveAgentChoice(id)
    applyFirstAgentMentionIfNeeded()
    updateVisibilityTooltip()
  }

  func selectProject(_ id: String?) {
    selectedProjectID = id
    saveCurrentAgentConfiguration()
  }

  func selectModel(_ id: String?) {
    let nextModelID = id ?? agentCatalog?.defaultModelID
    if nextModelID != effectiveModelID,
       let model = agentCatalog?.models?.first(where: { $0.id == nextModelID }),
       let reasoning = selectedReasoningID,
       !model.reasoningEffortIDs.isEmpty,
       !model.reasoningEffortIDs.contains(reasoning)
    {
      // The user changed models; use the new model's default if necessary.
      selectedReasoningID = nil
    }
    selectedModelID = id
    saveCurrentAgentConfiguration()
  }

  func selectReasoning(_ id: String?) {
    selectedReasoningID = id
    saveCurrentAgentConfiguration()
  }

  func makeContext(
    overlayHost: @escaping @MainActor () -> NSView?,
    supplementaryAccessoryView: NSView
  ) -> NewThreadComposeContext {
    NewThreadComposeContext(
      destination: { [weak self] in self?.destination ?? .home },
      sendSilently: { self.sendSilently },
      setSendSilently: { self.setSendSilently($0) },
      agentContext: { [weak self] in self?.agentThreadContext },
      mentionSource: mentionSource,
      attachmentStore: attachmentStore,
      overlayHostView: overlayHost,
      supplementaryAccessoryView: supplementaryAccessoryView,
      placeholderSymbolName: "square.and.pencil",
      didChangeDraft: { [weak self] text, entities, hasAttachments in
        self?.draftDidChange(text: text, entities: entities, hasAttachments: hasAttachments)
      },
      didChangeHeight: { [weak self] height in
        self?.composeHeight = height
      },
      didFinishSubmission: { [weak self] result in
        AllChatsNewThreadComposeModel.presentSubmissionFeedback(result)
        self?.submissionDidFinish(result)
      },
      submit: { [weak self] draft, intent in
        guard let self else {
          return .failure(NewThreadComposeSubmissionFailure(
            message: "The new thread composer is no longer available.",
            createdPeer: nil
          ))
        }
        return await submit(draft, intent: intent)
      }
    )
  }

  private func setDestination(_ destination: NewThreadComposeDestination) {
    guard self.destination != destination else { return }
    self.destination = destination
    preferences.save(destination: destination)
    mentionSource.setDestination(destination)
    updateVisibilityTooltip()
    Task { await mentionSource.refresh() }
  }

  private func draftDidChange(
    text: String,
    entities: MessageEntities?,
    hasAttachments _: Bool
  ) {
    let nextMentions = AllChatsComposeAccessMentions(text: text, entities: entities)
    let nextAgentTargets = entities?.entities.lazy
      .filter { $0.type == .mention }
      .map { entity in
        AllChatsAgentMentionTarget(
          botUserID: entity.mention.userID,
          agentID: entity.mention.hasAgentID && entity.mention.agentID > 0
            ? entity.mention.agentID
            : nil
        )
      }
      .reduce(into: [AllChatsAgentMentionTarget]()) { targets, target in
        if !targets.contains(target) { targets.append(target) }
      } ?? []
    guard accessMentions != nextMentions || mentionedAgentTargets != nextAgentTargets else { return }
    accessMentions = nextMentions
    mentionedAgentTargets = nextAgentTargets
    applyFirstAgentMentionIfNeeded()
    updateVisibilityTooltip()
  }

  private func applyFirstAgentMentionIfNeeded() {
    let mentionedChoice = firstMentionedAgentChoice
    // A newly added mention also becomes the next thread's default. Removing
    // draft text (including after send) must not discard that remembered choice.
    if agentPickerEnabled, let mentionedChoice, mentionedChoice.id != lastMentionedAgentChoiceID {
      preferences.saveAgentChoice(mentionedChoice.id)
    }
    lastMentionedAgentChoiceID = mentionedChoice?.id
    let choice = agentPickerEnabled
      ? agentChoices.first { $0.id == preferences.agentChoiceID }
      : mentionedChoice
    guard selectedAgentChoiceID != choice?.id else { return }

    agentCatalogTask?.cancel()
    clearAgentSelection()
    guard let choice else { return }

    // The selection establishes the Chat's Agent target immediately. A catalog
    // is optional and only controls whether configuration pickers appear.
    selectedAgentChoiceID = choice.id
    let saved = preferences.agentConfiguration(for: choice)
    selectedProjectID = saved.projectID
    selectedModelID = saved.modelID
    selectedReasoningID = saved.reasoningID

    agentCatalogTask = Task { [weak self] in
      guard let self else { return }
      if let cached = await AgentConfigurationCatalogStore.shared.cached(botUserID: choice.bot.id),
         !Task.isCancelled,
         isCurrentAgentSelection(choice) {
        applyAgentSelection(choice, catalog: cached)
      }

      do {
        let refreshed = try await AgentConfigurationCatalogStore.shared.refresh(botUserID: choice.bot.id)
        guard !Task.isCancelled, isCurrentAgentSelection(choice) else { return }
        if let refreshed {
          applyAgentSelection(choice, catalog: refreshed)
        }
      } catch {
        guard !Task.isCancelled, isCurrentAgentSelection(choice) else { return }
        log.error("Could not refresh Agent configuration catalog", error: error)
      }
    }
  }

  private var firstMentionedAgentChoice: AllChatsAgentChoice? {
    mentionedAgentTargets.lazy.compactMap { target in
      self.agentChoices.first { choice in
        choice.bot.id == target.botUserID && choice.agent?.id == target.agentID
      }
    }.first
  }

  private func isCurrentAgentSelection(_ choice: AllChatsAgentChoice) -> Bool {
    selectedAgentChoiceID == choice.id
  }

  private func applyAgentSelection(
    _ choice: AllChatsAgentChoice,
    catalog: AgentConfigurationCatalogSnapshot
  ) {
    // Refresh options without replacing explicit selections. Missing catalog
    // entries are not evidence that the provider can no longer use a choice.
    selectedAgentChoiceID = choice.id
    agentCatalog = catalog
  }

  private func clearAgentSelection() {
    selectedAgentChoiceID = nil
    clearAgentConfiguration()
  }

  private func clearAgentConfiguration() {
    agentCatalog = nil
    clearExplicitAgentConfiguration()
  }

  private func clearExplicitAgentConfiguration() {
    selectedProjectID = nil
    selectedModelID = nil
    selectedReasoningID = nil
  }

  private func saveCurrentAgentConfiguration() {
    guard let choice = selectedAgentChoice else { return }
    preferences.saveAgentConfiguration(
      AllChatsComposeAgentConfiguration(
        projectID: selectedProjectID,
        modelID: selectedModelID,
        reasoningID: selectedReasoningID
      ),
      for: choice
    )
  }

  private func selectedLabel(
    _ id: String?,
    in options: [AgentConfigurationOption]?
  ) -> String? {
    guard let id else { return nil }
    return options?.first(where: { $0.id == id })?.label ?? id
  }

  private func automaticTitle(
    _ id: String?,
    in options: [AgentConfigurationOption]?
  ) -> String? {
    guard let label = selectedLabel(id, in: options) else { return nil }
    return automaticTitle(label)
  }

  private func automaticTitle(_ label: String) -> String {
    String(
      localized: "Use default — \(label)",
      comment:
        "Reset label for an Agent setting. The variable is the current harness-selected option name."
    )
  }

  private func updateVisibilityTooltip() {
    if destination.isPublic {
      visibilityTooltipTitle = String(localized: "Public thread")
      visibilityTooltipDescription = String(
        localized: "Members of \(destinationTitle) can access this thread.",
        comment: "Tooltip description for the Public visibility pill. The variable is a space name."
      )
      return
    }

    visibilityTooltipTitle = String(localized: "Private thread")

    let candidates = mentionSource.candidates
    let usersByID = Dictionary(uniqueKeysWithValues: candidates.users.map {
      ($0.userInfo.id, $0.userInfo.user.displayName)
    })
    let groupsByID = Dictionary(uniqueKeysWithValues: candidates.groups.map { ($0.id, $0.name) })
    var names = ["You"]

    for userID in accessMentions.userIDs.sorted() {
      if let name = usersByID[userID] ?? accessMentions.userNamesByID[userID] {
        names.append(name)
      }
    }
    for groupID in accessMentions.groupIDs.sorted() {
      if let name = groupsByID[groupID] ?? accessMentions.groupNamesByID[groupID] {
        names.append(name)
      }
    }
    if let choice = selectedAgentChoice, !accessMentions.userIDs.contains(choice.bot.id) {
      names.append(InlineKit.User(from: choice.bot).displayName)
    }
    visibilityTooltipDescription = if names.count == 1 {
      String(localized: "Only you can access this thread. Mention people or groups to add them.")
    } else {
      String(
        localized: "\(names.formatted()) can access this thread. Mention more people or groups to add them.",
        comment: "Tooltip description for the Private visibility pill. The variable is a localized list of people or groups."
      )
    }
  }

  private func submit(
    _ draft: PreparedNewThreadDraft,
    intent: NewThreadComposeSubmissionIntent
  ) async -> Result<InlineKit.Peer, NewThreadComposeSubmissionFailure> {
    guard !isSubmitting else {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "This thread is already being created.",
        createdPeer: nil
      ))
    }

    if agentPickerEnabled, rememberedAgentChoiceID != nil, selectedAgentChoice == nil {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "Your selected agent isn't available yet. Retry loading agents, choose another agent, or select None.",
        createdPeer: nil
      ))
    }

    isSubmitting = true
    let signpostID = OSSignpostID(log: performanceLog)
    os_signpost(
      .begin,
      log: performanceLog,
      name: "AllChatsNewThreadSubmit",
      signpostID: signpostID
    )
    defer {
      isSubmitting = false
      os_signpost(
        .end,
        log: performanceLog,
        name: "AllChatsNewThreadSubmit",
        signpostID: signpostID
      )
    }

    do {
      try await validateGroupMentions(in: draft)
    } catch NewThreadComposeSubmitError.invalidGroupMentionDestination {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "A group mention doesn't belong to the selected space. Remove it or choose its space.",
        createdPeer: nil
      ))
    } catch {
      log.error("New-thread group mention validation failed", error: error)
      return .failure(NewThreadComposeSubmissionFailure(
        message: "Couldn't verify the mentioned groups. Your message is still here.",
        createdPeer: nil
      ))
    }

    // Validate locally fixable content before reporting connectivity. Durable
    // Realtime transactions intentionally wait for a connection, but this
    // transient composer cannot turn an offline click into an indefinite
    // spinner because it has no persisted pre-chat draft after relaunch.
    guard dependencies.realtimeV2.stateObject.connectionState != .connecting else {
      return .failure(NewThreadComposeSubmissionFailure(
        message: "You're offline. Reconnect and try again; your message is still here.",
        createdPeer: nil
      ))
    }

    let agentBotIDs = draft.agentContext.map { Set([$0.botUserID]) } ?? []
    let participantIDs = draft.destination.isPublic
      ? []
      : Array(draft.mentionedUserIDs.union(agentBotIDs).union([draft.authorUserID])).sorted()

    if draft.attachments.isEmpty, draft.mentionedGroupIDs.isEmpty {
      return await submitOptimistically(
        draft,
        participantIDs: participantIDs,
        signpostID: signpostID,
        intent: intent
      )
    }

    return await submitAfterAuthoritativeCreation(
      draft,
      participantIDs: participantIDs,
      signpostID: signpostID,
      intent: intent
    )
  }

  /// Human-only text threads can use a reserved shell. Agent threads wait for
  /// server confirmation in createThreadLocally so rejection leaves the
  /// composer intact, before the first message or navigation is admitted.
  private func submitOptimistically(
    _ draft: PreparedNewThreadDraft,
    participantIDs: [Int64],
    signpostID: OSSignpostID,
    intent: NewThreadComposeSubmissionIntent
  ) async -> Result<InlineKit.Peer, NewThreadComposeSubmissionFailure> {
    var createdPeer: InlineKit.Peer?
    do {
      let chatID = try await dependencies.realtimeV2.createThreadLocally(
        title: nil,
        placeholderTitle: placeholderTitle(for: draft),
        emoji: nil,
        isPublic: draft.destination.isPublic,
        spaceId: draft.destination.spaceID,
        participants: participantIDs,
        agentContext: draft.agentContext
      )
      let peer: InlineKit.Peer = .thread(id: chatID)
      createdPeer = peer
      ChatsManager.get(for: peer, chatId: chatID).setSendSilently(draft.sendSilently)
      os_signpost(
        .event,
        log: performanceLog,
        name: "AllChatsLocalThreadReady",
        signpostID: signpostID,
        "%{public}s",
        "optimistic"
      )

      guard await admitTextSend(draft, peer: peer, chatID: chatID) else {
        log.error("New-thread durable send admission failed after local creation")
        installDraft(draft, on: peer)
        await finishCreatedThread(peer, intent: intent)
        os_signpost(
          .event,
          log: performanceLog,
          name: "AllChatsCreatedRouteStateUpdated",
          signpostID: signpostID,
          "%{public}s",
          "recovery_draft"
        )
        await Drafts2.shared.flush()
        return .failure(NewThreadComposeSubmissionFailure(
          message: "The thread was created, but the message couldn't be queued. It was saved as a draft.",
          createdPeer: peer
        ))
      }
      os_signpost(
        .event,
        log: performanceLog,
        name: "AllChatsFirstMessageAdmitted",
        signpostID: signpostID,
        "%{public}s",
        "durable"
      )

      await finishCreatedThread(peer, intent: intent)
      os_signpost(
        .event,
        log: performanceLog,
        name: "AllChatsCreatedRouteStateUpdated",
        signpostID: signpostID,
        "%{public}s",
        "message_ready"
      )
      return .success(peer)
    } catch {
      log.error("Optimistic new-thread submission failed", error: error)
      return .failure(NewThreadComposeSubmissionFailure(
        message: createdPeer == nil
          ? creationFailureMessage(error)
          : "The thread was created, but the message couldn't be sent. It was saved as a draft.",
        createdPeer: createdPeer
      ))
    }
  }

  /// Media and group access still require their existing authoritative order.
  /// We nevertheless skip chat preloading and yield while the recovery draft is
  /// flushed. The route commits once its first frame owns a message or recovery.
  private func submitAfterAuthoritativeCreation(
    _ draft: PreparedNewThreadDraft,
    participantIDs: [Int64],
    signpostID: OSSignpostID,
    intent: NewThreadComposeSubmissionIntent
  ) async -> Result<InlineKit.Peer, NewThreadComposeSubmissionFailure> {
    var createdPeer: InlineKit.Peer?
    do {
      let chatID = try await dependencies.realtimeV2.createThreadLocally(
        title: nil,
        placeholderTitle: placeholderTitle(for: draft),
        emoji: nil,
        isPublic: draft.destination.isPublic,
        spaceId: draft.destination.spaceID,
        participants: participantIDs,
        agentContext: draft.agentContext,
        requireServerConfirmation: true
      )
      let peer: InlineKit.Peer = .thread(id: chatID)
      createdPeer = peer
      ChatsManager.get(for: peer, chatId: chatID).setSendSilently(draft.sendSilently)
      os_signpost(
        .event,
        log: performanceLog,
        name: "AllChatsLocalThreadReady",
        signpostID: signpostID,
        "%{public}s",
        "authoritative"
      )

      installDraft(draft, on: peer)

      // Preserve a disk-backed recovery copy before any legacy attachment
      // transaction owns the content, while yielding the main actor.
      await Drafts2.shared.flush()

      if !draft.destination.isPublic {
        for groupID in draft.mentionedGroupIDs.sorted() {
          try await dependencies.realtimeV2.send(.addChatParticipant(
            chatID: chatID,
            groupID: groupID
          ))
        }
      }

      let admitted = if draft.attachments.isEmpty {
        await admitTextSend(draft, peer: peer, chatID: chatID)
      } else {
        admitAttachmentSends(draft, peer: peer, chatID: chatID)
      }
      guard admitted else {
        log.error("New-thread send transaction admission failed after thread creation")
        await finishCreatedThread(peer, intent: intent)
        os_signpost(
          .event,
          log: performanceLog,
          name: "AllChatsCreatedRouteStateUpdated",
          signpostID: signpostID,
          "%{public}s",
          "recovery_draft"
        )
        await Drafts2.shared.flush()
        return .failure(NewThreadComposeSubmissionFailure(
          message: "The thread was created, but the message couldn't be queued. It was saved as a draft.",
          createdPeer: peer
        ))
      }

      os_signpost(
        .event,
        log: performanceLog,
        name: "AllChatsFirstMessageAdmitted",
        signpostID: signpostID,
        "%{public}s",
        draft.attachments.isEmpty ? "durable" : "legacy_media"
      )
      Drafts2.shared.clear(peer: peer)
      await Drafts2.shared.flush()
      await finishCreatedThread(peer, intent: intent)
      os_signpost(
        .event,
        log: performanceLog,
        name: "AllChatsCreatedRouteStateUpdated",
        signpostID: signpostID,
        "%{public}s",
        "message_ready"
      )
      return .success(peer)
    } catch {
      log.error("New-thread submission failed", error: error)
      if let createdPeer {
        await finishCreatedThread(createdPeer, intent: intent)
        os_signpost(
          .event,
          log: performanceLog,
          name: "AllChatsCreatedRouteStateUpdated",
          signpostID: signpostID,
          "%{public}s",
          "recovery_draft"
        )
      }
      return .failure(NewThreadComposeSubmissionFailure(
        message: createdPeer == nil
          ? creationFailureMessage(error)
          : "The thread was created, but the message couldn't be sent. It was saved as a draft.",
        createdPeer: createdPeer
      ))
    }
  }

  private func creationFailureMessage(_ error: Error) -> String {
    if let accessError = error as? AgentThreadSpaceAccessError {
      return accessError.localizedDescription
    }
    if let transactionError = error as? TransactionError2,
       case .commitOutcomeUnknownAfterReconnect = transactionError {
      return "Couldn't confirm whether the thread was created. Check All Chats before trying again. Your message is still here."
    }
    return "Failed to create thread. Your message is still here."
  }

  private func validateGroupMentions(in draft: PreparedNewThreadDraft) async throws {
    guard !draft.mentionedGroupIDs.isEmpty else { return }
    guard let spaceID = draft.destination.spaceID else {
      throw NewThreadComposeSubmitError.invalidGroupMentionDestination
    }

    let groupIDs = draft.mentionedGroupIDs
    let validCount = try await dependencies.database.reader.read { db in
      try UserGroup
        .filter(groupIDs.contains(UserGroup.Columns.id))
        .filter(UserGroup.Columns.spaceId == spaceID)
        .fetchCount(db)
    }
    guard validCount == groupIDs.count else {
      throw NewThreadComposeSubmitError.invalidGroupMentionDestination
    }
  }

  private func placeholderTitle(for draft: PreparedNewThreadDraft) -> String {
    let normalized = draft.text
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
    guard !normalized.isEmpty else { return "Message" }
    return String(normalized.prefix(60))
  }

  private func installDraft(_ draft: PreparedNewThreadDraft, on peer: InlineKit.Peer) {
    let revision = Drafts2.shared.updateText(peer: peer, text: draft.text)
    _ = Drafts2.shared.updateEntities(peer: peer, entities: draft.entities, forRevision: revision)
    for attachment in draft.attachments {
      Drafts2.shared.appendAttachment(peer: peer, media: attachment.media, id: attachment.id)
    }
  }

  private func finishCreatedThread(
    _ peer: InlineKit.Peer,
    intent: NewThreadComposeSubmissionIntent
  ) async {
    // Install the local open state and admit its durable transaction before
    // navigation replaces the composer. This awaits local work, not the server.
    await dependencies.realtimeV2.sendQueued(
      .updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true)
    )
    SidebarCleanup.shared.markOpened(peer)
    if case .openThread = intent {
      dependencies.openNewlyCreatedChatInCurrentContext(peer: peer)
    }
  }

  private func admitTextSend(
    _ draft: PreparedNewThreadDraft,
    peer: InlineKit.Peer,
    chatID: Int64
  ) async -> Bool {
    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil
      : draft.text
    return await dependencies.realtimeV2.sendQueuedIfAccepted(.sendMessage(
      text: text,
      peerId: peer,
      chatId: chatID,
      entities: draft.entities,
      sendMode: draft.sendSilently ? .modeSilent : nil
    )) != nil
  }

  private func admitAttachmentSends(
    _ draft: PreparedNewThreadDraft,
    peer: InlineKit.Peer,
    chatID: Int64
  ) -> Bool {
    let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? nil
      : draft.text
    for (index, attachment) in draft.attachments.enumerated() {
      let admitted = dependencies.transactions.mutate(transaction: .sendMessage(
        TransactionSendMessage(
          text: index == 0 ? text : nil,
          peerId: peer,
          chatId: chatID,
          mediaItems: [attachment.media],
          entities: index == 0 ? draft.entities : nil,
          sendMode: draft.sendSilently ? .modeSilent : nil
        )
      ))
      guard admitted else {
        Drafts2.shared.flushBlocking()
        return false
      }

      // Once the existing media transaction accepts this portion, remove only
      // that portion from recovery so a later admission failure cannot make the
      // fallback draft duplicate already-queued work.
      Drafts2.shared.removeAttachment(peer: peer, id: attachment.id)
      if index == 0 {
        let revision = Drafts2.shared.updateText(peer: peer, text: "")
        _ = Drafts2.shared.updateEntities(peer: peer, entities: nil, forRevision: revision)
      }
      Drafts2.shared.flushBlocking()
    }
    return true
  }

  private func submissionDidFinish(
    _ result: Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>
  ) {
    switch result {
      case .success:
        accessMentions = AllChatsComposeAccessMentions()
        updateVisibilityTooltip()
      case let .failure(failure):
        if failure.createdPeer != nil {
          accessMentions = AllChatsComposeAccessMentions()
          updateVisibilityTooltip()
        }
    }
  }

  private static func presentSubmissionFeedback(
    _ result: Result<InlineKit.Peer, NewThreadComposeSubmissionFailure>
  ) {
    if case let .failure(failure) = result {
      ToastCenter.shared.showError(failure.message)
    }
  }
}

private enum NewThreadComposeSubmitError: Error {
  case invalidGroupMentionDestination
}

private final class WeakNewThreadComposeHost {
  weak var view: NSView?
}

private final class NewThreadComposeOverlayHostView: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    for subview in subviews.reversed() where !subview.isHidden {
      let convertedPoint = convert(point, to: subview)
      if let hitView = subview.hitTest(convertedPoint) {
        return hitView
      }
    }
    return nil
  }
}

@available(macOS 26.0, *)
private final class NewThreadGlassComposeHostView: ChatDropView {
  let compose: GlassComposeAppKit
  private weak var completionOverlayHostView: NewThreadComposeOverlayHostView?
  private var focusRequested: Binding<Bool> = .constant(false)
  private let fillsAvailableDropSurface: Bool
  private var composeHeightConstraint: NSLayoutConstraint?

  init(
    model: AllChatsNewThreadComposeModel,
    placement: AllChatsNewThreadComposePlacement,
    fillsAvailableDropSurface: Bool
  ) {
    self.fillsAvailableDropSurface = fillsAvailableDropSurface
    let weakHost = WeakNewThreadComposeHost()
    let supplementaryAccessoryView = NSHostingView(
      rootView: AllChatsComposeAccessoryView(
        model: model,
        tooltipPlacement: placement.tooltipPlacement
      )
    )
    compose = GlassComposeAppKit(
      newThread: model.makeContext(
        overlayHost: {
          (weakHost.view as? NewThreadGlassComposeHostView)?.completionOverlayHost()
        },
        supplementaryAccessoryView: supplementaryAccessoryView
      ),
      dependencies: model.dependencies,
      layout: .accessoryBar,
      capabilities: .allChatsNewThread,
      completionMenuPlacement: placement.completionMenuPlacement
    )
    super.init(frame: .zero)
    weakHost.view = self
    drawsSurfaceBackground = false
    dropHandler = { [weak self] sender in
      self?.compose.handleAttachments(from: sender.draggingPasteboard) ?? false
    }
    compose.configureNewThreadSendTooltip(placement: placement.tooltipPlacement)

    translatesAutoresizingMaskIntoConstraints = false
    compose.translatesAutoresizingMaskIntoConstraints = false
    addSubview(compose)
    var constraints = [
      compose.leadingAnchor.constraint(equalTo: leadingAnchor),
      compose.trailingAnchor.constraint(equalTo: trailingAnchor),
    ]
    if fillsAvailableDropSurface {
      let heightConstraint = compose.heightAnchor.constraint(equalToConstant: model.composeHeight)
      composeHeightConstraint = heightConstraint
      constraints.append(heightConstraint)
      switch placement {
        case .top:
          constraints.append(compose.topAnchor.constraint(equalTo: topAnchor))
        case .bottom:
          constraints.append(compose.bottomAnchor.constraint(equalTo: bottomAnchor))
      }
    } else {
      constraints.append(contentsOf: [
        compose.topAnchor.constraint(equalTo: topAnchor),
        compose.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    }
    NSLayoutConstraint.activate(constraints)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    super.layout()
    compose.didLayout()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard fillsAvailableDropSurface else { return super.hitTest(point) }
    return compose.hitTest(convert(point, to: compose))
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    scheduleRequestedFocus()
  }

  func updateFocusRequest(_ focusRequested: Binding<Bool>) {
    self.focusRequested = focusRequested
    scheduleRequestedFocus()
  }

  func updateComposeHeight(_ height: CGFloat) {
    guard let composeHeightConstraint,
          composeHeightConstraint.constant != height
    else { return }
    composeHeightConstraint.constant = height
  }

  private func scheduleRequestedFocus() {
    guard focusRequested.wrappedValue, window != nil else { return }

    // Focusing expands Compose and publishes its height, so wait until the
    // native view is mounted and the current SwiftUI update has finished.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.focusRequested.wrappedValue else { return }

      self.focusRequested.wrappedValue = false
      guard self.window?.isKeyWindow == true,
            !self.isHiddenOrHasHiddenAncestor
      else { return }

      self.compose.focus()
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      completionOverlayHostView?.removeFromSuperview()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  private func completionOverlayHost() -> NSView? {
    if let completionOverlayHostView,
       completionOverlayHostView.superview != nil
    {
      return completionOverlayHostView
    }

    guard let contentView = window?.contentView,
          let frameView = contentView.superview
    else {
      return nil
    }

    let overlayView = NewThreadComposeOverlayHostView()
    overlayView.translatesAutoresizingMaskIntoConstraints = false
    frameView.addSubview(overlayView, positioned: .above, relativeTo: contentView)
    NSLayoutConstraint.activate([
      overlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
    // Completion constraints use coordinates local to this overlay immediately
    // after it is created. Resolve its content-view constraints before handing
    // it to Compose so the first menu frame is not calculated from `.zero`.
    frameView.layoutSubtreeIfNeeded()
    completionOverlayHostView = overlayView
    return overlayView
  }
}

@available(macOS 26.0, *)
private struct NewThreadGlassComposeRepresentable: NSViewRepresentable {
  @ObservedObject var model: AllChatsNewThreadComposeModel
  @Binding var focusRequested: Bool
  let placement: AllChatsNewThreadComposePlacement
  let fillsAvailableDropSurface: Bool

  func makeNSView(context: Context) -> NewThreadGlassComposeHostView {
    NewThreadGlassComposeHostView(
      model: model,
      placement: placement,
      fillsAvailableDropSurface: fillsAvailableDropSurface
    )
  }

  func updateNSView(_ nsView: NewThreadGlassComposeHostView, context: Context) {
    nsView.updateFocusRequest($focusRequested)
    nsView.updateComposeHeight(model.composeHeight)
  }
}

@available(macOS 26.0, *)
struct AllChatsNewThreadComposeHost: View {
  @StateObject private var model: AllChatsNewThreadComposeModel
  @Binding private var focusRequested: Bool

  let spaces: [AllChatsComposeSpace]
  let selectedSpaceID: Int64?
  let placement: AllChatsNewThreadComposePlacement
  let fillsAvailableDropSurface: Bool

  init(
    dependencies: AppDependencies,
    spaces: [AllChatsComposeSpace],
    selectedSpaceID: Int64?,
    placement: AllChatsNewThreadComposePlacement,
    focusRequested: Binding<Bool> = .constant(false),
    fillsAvailableDropSurface: Bool = false
  ) {
    self.spaces = spaces
    self.selectedSpaceID = selectedSpaceID
    self.placement = placement
    self.fillsAvailableDropSurface = fillsAvailableDropSurface
    _focusRequested = focusRequested
    _model = StateObject(wrappedValue: AllChatsNewThreadComposeModel(
      dependencies: dependencies,
      spaces: spaces,
      initialSpaceID: selectedSpaceID
    ))
  }

  var body: some View {
    composeHost
      .padding(.horizontal, 12)
      .zIndex(10)
      .onChange(of: spaces) { _, value in
        model.updateSpaces(value)
      }
      .onChange(of: selectedSpaceID) { _, value in
        model.followSelectedSpace(value)
      }
      .task {
        await model.loadAgentChoices()
      }
  }

  @ViewBuilder
  private var composeHost: some View {
    let representable = NewThreadGlassComposeRepresentable(
      model: model,
      focusRequested: $focusRequested,
      placement: placement,
      fillsAvailableDropSurface: fillsAvailableDropSurface
    )

    if fillsAvailableDropSurface {
      representable
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      representable
        .frame(maxWidth: .infinity)
        .frame(height: model.composeHeight)
    }
  }
}

@available(macOS 26.0, *)
private struct AllChatsComposeAccessoryView: View {
  @ObservedObject var model: AllChatsNewThreadComposeModel
  let tooltipPlacement: InlineTooltipPlacement

  var body: some View {
    // This view fills the AppKit accessory slot. Controls hug their contents;
    // Agent choice labels cap long titles at 112 points.
    HStack(spacing: 4) {
      Menu {
        Button("Home", action: model.selectHome)
        if !model.spaces.isEmpty {
          Divider()
        }
        ForEach(model.spaces) { space in
          Button(space.title) {
            model.selectSpace(space.id)
          }
        }
      } label: {
        AllChatsComposePillLabel(title: model.destinationTitle)
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .fixedSize(horizontal: true, vertical: true)
      .disabled(model.isSubmitting || model.isDestinationLocked)
      .inlineTooltip(
        verbatim: String(localized: "Thread destination"),
        description: model.destinationTooltipDescription,
        placement: tooltipPlacement
      )

      if model.showsVisibility {
        Button(action: model.toggleVisibility) {
          AllChatsComposePillLabel(title: model.isPublic ? "Public" : "Private")
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
        .disabled(model.isSubmitting)
        .inlineTooltip(
          verbatim: model.visibilityTooltipTitle,
          description: model.visibilityTooltipDescription,
          placement: tooltipPlacement
        )
        .transition(.opacity)
      }

      if model.agentPickerEnabled {
        agentPicker
      }

      if let projects = model.agentCatalog?.projects, let title = model.projectTitle {
        AgentConfigurationMenu(
          title: title,
          automaticTitle: nil,
          options: projects,
          selection: model.effectiveProjectID,
          isDisabled: model.isSubmitting,
          tooltipTitle: "Project",
          tooltipDescription: "Choose the project for this thread only.",
          tooltipPlacement: tooltipPlacement,
          select: model.selectProject
        )
      }

      Spacer(minLength: 0)

      if let models = model.agentCatalog?.models, let title = model.modelTitle {
        AgentModelConfigurationMenu(
          title: title,
          automaticTitle: model.automaticModelTitle,
          options: models,
          selection: model.selectedModelID,
          isDisabled: model.isSubmitting,
          tooltipPlacement: tooltipPlacement,
          select: model.selectModel
        )
      }

      if let reasoning = model.availableReasoningOptions, let title = model.reasoningTitle {
        AgentConfigurationMenu(
          title: title,
          automaticTitle: model.automaticReasoningTitle,
          options: reasoning,
          selection: model.selectedReasoningID,
          isDisabled: model.isSubmitting,
          tooltipTitle: "Reasoning",
          tooltipDescription: "Choose reasoning effort for this thread only.",
          tooltipPlacement: tooltipPlacement,
          select: model.selectReasoning
        )
      }

      if model.isSubmitting {
        ProgressView()
          .controlSize(.mini)
      }
    }
    .frame(height: 24)
    .animation(.easeOut(duration: 0.16), value: model.showsVisibility)
  }

  private var agentPicker: some View {
    Menu {
      Button {
        model.selectAgent(nil)
      } label: {
        AgentConfigurationOptionMenuLabel(
          title: "None", description: nil, isSelected: model.rememberedAgentChoiceID == nil
        )
      }
      Divider()
      ForEach(model.agentChoices) { choice in
        Button {
          model.selectAgent(choice.id)
        } label: {
          AgentConfigurationOptionMenuLabel(
            title: choice.title,
            description: choice.providerTitle,
            isSelected: model.selectedAgentChoiceID == choice.id
          )
        }
      }
      if model.isLoadingAgentChoices {
        Text("Loading agents…")
      } else if model.agentChoicesLoadFailed {
        Button("Couldn't load agents. Retry") {
          Task { await model.loadAgentChoices() }
        }
      } else if model.rememberedAgentChoiceID != nil, model.selectedAgentChoice == nil {
        Button("Reload agents") {
          Task { await model.loadAgentChoices() }
        }
      } else if model.agentChoices.isEmpty {
        Text("No agents available")
      }
    } label: {
      AllChatsComposePillLabel(title: model.agentPickerTitle, showsRobot: true)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: true, vertical: true)
    .disabled(model.isSubmitting)
    .accessibilityLabel("New thread agent")
    .accessibilityValue(model.agentPickerTitle)
    .inlineTooltip(
      verbatim: "New thread agent",
      description: "Remember this agent for future threads. Choose None to stop adding an agent automatically.",
      placement: tooltipPlacement
    )
  }
}

@available(macOS 26.0, *)
private struct AgentConfigurationMenu: View {
  let title: String
  let automaticTitle: String?
  let options: [AgentConfigurationOption]
  let selection: String?
  let isDisabled: Bool
  let tooltipTitle: String
  let tooltipDescription: String
  let tooltipPlacement: InlineTooltipPlacement
  let select: (String?) -> Void

  var body: some View {
    Menu {
      if let automaticTitle {
        Button {
          select(nil)
        } label: {
          AgentConfigurationOptionMenuLabel(
            title: automaticTitle,
            description: nil,
            isSelected: selection == nil
          )
        }
        if !options.isEmpty { Divider() }
      }
      ForEach(options) { option in
        Button {
          select(option.id)
        } label: {
          AgentConfigurationOptionMenuLabel(
            title: option.label,
            description: option.description,
            isSelected: selection == option.id
          )
        }
      }
    } label: {
      AllChatsComposePillLabel(title: title)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: true, vertical: true)
    .disabled(isDisabled)
    .inlineTooltip(
      verbatim: tooltipTitle,
      description: tooltipDescription,
      placement: tooltipPlacement
    )
  }
}

@available(macOS 26.0, *)
private struct AgentModelConfigurationMenu: View {
  let title: String
  let automaticTitle: String?
  let options: [AgentModelConfigurationOption]
  let selection: String?
  let isDisabled: Bool
  let tooltipPlacement: InlineTooltipPlacement
  let select: (String?) -> Void

  var body: some View {
    Menu {
      if let automaticTitle {
        Button {
          select(nil)
        } label: {
          AgentConfigurationOptionMenuLabel(
            title: automaticTitle,
            description: nil,
            isSelected: selection == nil
          )
        }
        if !options.isEmpty { Divider() }
      }
      ForEach(options) { option in
        Button {
          select(option.id)
        } label: {
          AgentConfigurationOptionMenuLabel(
            title: option.label,
            description: option.description,
            isSelected: selection == option.id
          )
        }
      }
    } label: {
      AllChatsComposePillLabel(title: title)
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .fixedSize(horizontal: true, vertical: true)
    .disabled(isDisabled)
    .inlineTooltip(
      verbatim: "Model",
      description: "Choose the provider model for this thread only.",
      placement: tooltipPlacement
    )
  }
}

@available(macOS 26.0, *)
private struct AgentConfigurationOptionMenuLabel: View {
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

@available(macOS 26.0, *)
private struct AllChatsComposePillLabel: View {
  let title: String
  var showsRobot = false
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 4) {
      if showsRobot {
        Text("🤖")
          .accessibilityHidden(true)
      }
      Text(title)
    }
      .font(.system(size: 11.5, weight: .medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.horizontal, 8)
      .frame(maxWidth: 112, alignment: .leading)
      .frame(height: 24)
      .background {
        Capsule()
          .fill(.quaternary)
          .opacity(isHovering ? 1 : 0)
      }
      .contentShape(Capsule())
      .onHover { isHovering = $0 }
  }
}
