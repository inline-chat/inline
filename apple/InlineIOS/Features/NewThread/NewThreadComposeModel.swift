import Auth
import Combine
import Foundation
import GRDB
import InlineKit
import InlineProtocol
import Logger
import RealtimeV2
import TextProcessing
import UIKit

/// State and sending for the iOS New Thread composer, the counterpart of the macOS
/// `AllChatsNewThreadComposeModel`: mentions decide who is in the thread, the first
/// mentioned Agent (or bot) becomes the thread's Agent, and its model, reasoning and
/// folder can be chosen before the first message.
@MainActor
final class NewThreadComposeModel: ObservableObject {
  struct AgentTarget: Equatable {
    let botUserID: Int64
    let agentID: Int64?
  }

  /// Asks before the user's own bots join the selected space.
  struct AdmissionPrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    fileprivate let resume: (Bool) -> Void
  }

  // MARK: Destination

  @Published private(set) var spaceID: Int64?
  @Published var isPublic: Bool {
    didSet { defaults.set(isPublic, forKey: keys.visibility) }
  }

  // MARK: Text

  /// The editor's content; mentions carry `.mentionUserId` / `.mentionGroupId` attributes.
  @Published private(set) var attributedText = NSAttributedString()
  /// The open `@query` at the cursor, if any.
  @Published private(set) var mentionQuery: MentionRange?
  /// Candidates matching `mentionQuery`.
  @Published private(set) var mentionItems: [MentionCompletionItem] = []
  /// Quick picks shown under the editor before anyone is mentioned.
  @Published private(set) var suggestions: [MentionCompletionItem] = []

  // MARK: Agent

  @Published private(set) var agentTarget: AgentTarget?
  @Published private(set) var agentUserInfo: UserInfo?
  @Published private(set) var agentName: String?
  @Published private(set) var agentCatalog: AgentConfigurationCatalogSnapshot?
  @Published private(set) var selectedProjectID: String?
  @Published private(set) var selectedModelID: String?
  @Published private(set) var selectedReasoningID: String?

  // MARK: Submit

  @Published private(set) var isSending = false
  @Published var admissionPrompt: AdmissionPrompt?

  let detector = MentionDetector()

  private let database: AppDatabase
  private let realtimeV2: RealtimeV2
  private let currentUserID: Int64?
  private let mentionSource: MentionCandidatesSource
  private let completion = MentionCompletionViewModel()
  private let defaults: UserDefaults
  private let keys: Keys
  private var candidates: MentionCompletionCandidates = .empty
  private var mentionedUserIDs: [Int64] = []
  private var mentionedGroupIDs: [Int64] = []
  private var catalogTask: Task<Void, Never>?
  private var cancellables = Set<AnyCancellable>()
  private let log = Log.scoped("NewThreadComposeModel")

  init(
    initialSpaceID: Int64?,
    database: AppDatabase = .shared,
    realtimeV2: RealtimeV2,
    currentUserID: Int64?,
    defaults: UserDefaults = .standard
  ) {
    self.database = database
    self.realtimeV2 = realtimeV2
    self.currentUserID = currentUserID
    self.defaults = defaults
    keys = Keys(userID: currentUserID)
    spaceID = initialSpaceID
    isPublic = initialSpaceID != nil && defaults.bool(forKey: keys.visibility)
    mentionSource = MentionCandidatesSource(db: database, scope: .newThread(spaceId: initialSpaceID))

    mentionSource.updates
      .sink { [weak self] candidates in
        self?.candidatesDidChange(candidates)
      }
      .store(in: &cancellables)
    restoreDraft()
  }

  deinit {
    catalogTask?.cancel()
  }

  /// Starts observing people, groups and the user's bots for suggestions and mentions.
  func start() {
    mentionSource.beginSession()
    candidatesDidChange(mentionSource.candidates)
  }

  func stop() {
    mentionSource.endSession()
    catalogTask?.cancel()
    // A sheet closed under the "add agent" alert must not leave the send waiting on it.
    if let admissionPrompt { answerAdmission(admissionPrompt, agreed: false) }
  }

  // MARK: - Destination

  func selectSpace(_ id: Int64?) {
    guard spaceID != id, !isSending else { return }
    spaceID = id
    if id == nil {
      isPublic = false
    } else {
      isPublic = defaults.bool(forKey: keys.visibility)
    }
    mentionSource.setScope(.newThread(spaceId: id))
    mentionSource.beginSession()
    candidatesDidChange(mentionSource.candidates)
  }

  // MARK: - Text

  var trimmedText: String {
    attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var canSend: Bool {
    !trimmedText.isEmpty && !isSending
  }

  /// Called by the editor after every edit or selection change.
  func textDidChange(_ text: NSAttributedString, cursor: Int?) {
    if !text.isEqual(to: attributedText) {
      attributedText = text
      updateMentions(in: text)
      saveDraft()
    }
    updateMentionQuery(cursor: cursor, in: text)
  }

  /// The people and groups mentioned so far, in order, for the access line.
  var accessSummary: String {
    if isPublic, spaceID != nil {
      return String(localized: "Everyone in \(selectedSpaceName ?? "the space") can find this thread.")
    }
    var names: [String] = []
    let usersByID = Dictionary(
      candidates.users.map { ($0.userInfo.id, $0.userInfo.user.firstName ?? $0.userInfo.user.displayName) },
      uniquingKeysWith: { first, _ in first }
    )
    for id in mentionedUserIDs where id != currentUserID {
      if let name = usersByID[id] ?? mentionName(userID: id) { names.append(name) }
    }
    let groupsByID = Dictionary(candidates.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for id in mentionedGroupIDs {
      if let name = groupsByID[id] { names.append(name) }
    }
    if names.isEmpty {
      return String(localized: "Only you, until you mention someone.")
    }
    return ([String(localized: "You")] + names).formatted(.list(type: .and)) + "."
  }

  var selectedSpaceName: String? {
    guard let spaceID else { return nil }
    return try? database.reader.read { db in try Space.fetchOne(db, id: spaceID)?.displayName }
  }

  // MARK: - Agent configuration

  var effectiveProjectID: String? { selectedProjectID ?? agentCatalog?.defaultProjectID }
  var effectiveModelID: String? { selectedModelID ?? agentCatalog?.defaultModelID }
  var effectiveReasoningID: String? {
    selectedReasoningID ?? agentCatalog?.defaultReasoningEffortID(forModelID: effectiveModelID)
  }

  var projectOptions: [AgentConfigurationOption] { agentCatalog?.projects ?? [] }
  var projectTitle: String? { label(effectiveProjectID, in: agentCatalog?.projects) }

  var modelOptions: [AgentConfigurationOption] {
    (agentCatalog?.models ?? []).map {
      AgentConfigurationOption(id: $0.id, label: $0.label, description: $0.description)
    }
  }

  var modelTitle: String? {
    guard agentCatalog?.models != nil else { return nil }
    return agentCatalog?.modelTitle(forModelID: effectiveModelID) ?? selectedModelID
  }

  var automaticModelTitle: String? { agentCatalog?.automaticModelTitle }

  var reasoningOptions: [AgentConfigurationOption] {
    agentCatalog?.reasoningOptions(forModelID: effectiveModelID) ?? []
  }

  var reasoningTitle: String? {
    guard agentCatalog != nil else { return nil }
    if let title = label(effectiveReasoningID, in: reasoningOptions) { return title }
    return automaticReasoningTitle != nil ? String(localized: "Automatic") : nil
  }

  var automaticReasoningTitle: String? {
    agentCatalog?.automaticReasoningTitle(forModelID: effectiveModelID)
      ?? (selectedReasoningID != nil ? String(localized: "Use default") : nil)
  }

  func selectProject(_ id: String?) {
    selectedProjectID = id
    saveAgentConfiguration()
  }

  func selectModel(_ id: String?) {
    let next = id ?? agentCatalog?.defaultModelID
    if next != effectiveModelID, let reasoning = selectedReasoningID, let agentCatalog,
       agentCatalog.compatibleReasoningEffortID(reasoning, forModelID: next) == nil
    {
      selectedReasoningID = nil
    }
    selectedModelID = id
    saveAgentConfiguration()
  }

  func selectReasoning(_ id: String?) {
    selectedReasoningID = id
    saveAgentConfiguration()
  }

  var agentThreadContext: InlineProtocol.AgentThreadContext? {
    guard let agentTarget else { return nil }
    let projectID = effectiveProjectID
    let modelID = selectedModelID
    let reasoningID = selectedReasoningID
    return .with {
      $0.botUserID = agentTarget.botUserID
      if let agentID = agentTarget.agentID { $0.agentID = agentID }
      if projectID != nil || modelID != nil || reasoningID != nil {
        $0.configuration = .with {
          if let projectID { $0.projectID = projectID }
          if let modelID { $0.modelID = modelID }
          if let reasoningID { $0.reasoningEffortID = reasoningID }
        }
      }
    }
  }

  // MARK: - Mentions

  private func candidatesDidChange(_ candidates: MentionCompletionCandidates) {
    self.candidates = candidates
    completion.updateCandidates(candidates)
    if let mentionQuery {
      completion.filter(with: mentionQuery.query)
      mentionItems = completion.items
    }
    suggestions = Self.suggestions(from: candidates, currentUserID: currentUserID)
    refreshAgent()
  }

  private func updateMentionQuery(cursor: Int?, in text: NSAttributedString) {
    guard let cursor, let range = detector.detectMentionAt(cursorPosition: cursor, in: text) else {
      if mentionQuery != nil {
        mentionQuery = nil
        mentionItems = []
      }
      return
    }
    mentionQuery = range
    completion.filter(with: range.query)
    mentionItems = completion.items
  }

  private func updateMentions(in text: NSAttributedString) {
    var users: [Int64] = []
    var groups: [Int64] = []
    var agentTargets: [AgentTarget] = []
    let full = NSRange(location: 0, length: text.length)
    text.enumerateAttributes(in: full) { attributes, _, _ in
      if let userID = attributes[.mentionUserId] as? Int64 {
        if !users.contains(userID) { users.append(userID) }
        let agentID = attributes[.mentionAgentId] as? Int64
        let target = AgentTarget(botUserID: userID, agentID: agentID.flatMap { $0 > 0 ? $0 : nil })
        if !agentTargets.contains(target) { agentTargets.append(target) }
      } else if let groupID = attributes[.mentionGroupId] as? Int64, !groups.contains(groupID) {
        groups.append(groupID)
      }
    }
    mentionedUserIDs = users
    mentionedGroupIDs = groups
    mentionTargets = agentTargets
    refreshAgent()
  }

  private var mentionTargets: [AgentTarget] = []

  /// Text for a picked candidate, as the chat composer writes it.
  func mentionText(for item: MentionCompletionItem) -> String {
    completion.mentionText(for: item)
  }

  /// The first mentioned Agent, else the first mentioned bot, is the thread's Agent.
  private func refreshAgent() {
    let botIDs = Set(candidates.users.filter { $0.userInfo.user.bot == true }.map(\.userInfo.id))
      .union(OwnedBotsDirectory.shared.snapshot.bots.map(\.id))
    let target = mentionTargets.first { $0.agentID != nil }
      ?? mentionTargets.first { botIDs.contains($0.botUserID) }
    guard target != agentTarget else { return }
    agentTarget = target
    catalogTask?.cancel()
    agentCatalog = nil
    selectedProjectID = nil
    selectedModelID = nil
    selectedReasoningID = nil
    guard let target else {
      agentUserInfo = nil
      agentName = nil
      return
    }

    let agent = target.agentID.flatMap { id in
      candidates.agents.first { $0.id == id }
        ?? OwnedBotsDirectory.shared.snapshot.agents.first { $0.id == id }
    }
    let botInfo = candidates.users.first { $0.userInfo.id == target.botUserID }?.userInfo
      ?? OwnedBotsDirectory.shared.snapshot.bots.first { $0.id == target.botUserID }
    agentUserInfo = agent?.botUserInfo ?? botInfo
    agentName = agent?.name ?? botInfo?.user.displayName

    let saved = savedAgentConfiguration(for: target)
    selectedProjectID = saved.project
    selectedModelID = saved.model
    selectedReasoningID = saved.reasoning
    agentCatalog = AgentConfigurationCatalogStore.shared.cachedSnapshot(botUserID: target.botUserID)

    catalogTask = Task { [weak self] in
      do {
        let refreshed = try await AgentConfigurationCatalogStore.shared.refresh(botUserID: target.botUserID)
        guard let self, !Task.isCancelled, agentTarget == target, let refreshed else { return }
        agentCatalog = refreshed
      } catch {
        guard !Task.isCancelled else { return }
        self?.log.error("Could not refresh the Agent's configuration", error: error)
      }
    }
  }

  private func mentionName(userID: Int64) -> String? {
    var name: String?
    attributedText.enumerateAttribute(
      .mentionUserId,
      in: NSRange(location: 0, length: attributedText.length)
    ) { value, range, stop in
      guard (value as? Int64) == userID else { return }
      let text = (attributedText.string as NSString).substring(with: range)
      name = text.hasPrefix("@") ? String(text.dropFirst()) : text
      stop.pointee = true
    }
    return name
  }

  /// The user's Agents and bots first (the threads people start most), then the people
  /// they talk to most recently.
  static func suggestions(
    from candidates: MentionCompletionCandidates,
    currentUserID: Int64?
  ) -> [MentionCompletionItem] {
    var items: [MentionCompletionItem] = candidates.agents.map { .agent($0) }
    let agentBotIDs = Set(candidates.agents.map(\.botUserId))
    let users = candidates.users.filter { $0.userInfo.id != currentUserID }
    let bots = users
      .filter { $0.source == .ownedBot && !agentBotIDs.contains($0.userInfo.id) }
    items += bots.map { .user($0) }
    let people = users
      .filter { $0.source != .ownedBot }
      .sorted { lhs, rhs in
        switch (lhs.lastDirectMessageDate, rhs.lastDirectMessageDate) {
          case let (l?, r?): l > r
          case (_?, nil): true
          case (nil, _?): false
          case (nil, nil): lhs.source.rawValue < rhs.source.rawValue
        }
      }
    items += people.prefix(12).map { .user($0) }
    return items
  }

  // MARK: - Submit

  /// Creates the thread with its first message. Returns the new peer, or nil when nothing
  /// was created (the text stays in the composer).
  func submit() async -> InlineKit.Peer? {
    guard canSend, let currentUserID else {
      if currentUserID == nil {
        ToastManager.shared.showToast(
          "You're signed out. Please log in again.",
          type: .error,
          systemImage: "exclamationmark.triangle"
        )
      }
      return nil
    }

    let attributed = attributedText
    let destinationSpaceID = spaceID
    let threadIsPublic = destinationSpaceID != nil && isPublic
    let agentContext = agentThreadContext
    let (rawText, entities) = ProcessEntities.fromAttributedString(
      attributed,
      threadLinkSpaceId: destinationSpaceID
    )
    let normalizedEntities = Drafts2.normalizedEntities(entities)
    let mentionedUsers = Set(mentionedUserIDs)
    let groupIDs = mentionedGroupIDs

    if !groupIDs.isEmpty {
      guard let destinationSpaceID, await groupsBelong(groupIDs, to: destinationSpaceID) else {
        showError("A group mention doesn't belong to the selected space. Remove it or choose its space.")
        return nil
      }
    }

    isSending = true
    defer { isSending = false }

    let agentBotIDs: Set<Int64> = agentContext.map { [$0.botUserID] } ?? []
    if let destinationSpaceID {
      guard await admitOwnedBots(
        mentionedUsers.union(agentBotIDs),
        spaceID: destinationSpaceID,
        isPublic: threadIsPublic
      ) else { return nil }
    }

    let participants = threadIsPublic
      ? []
      : Array(mentionedUsers.union(agentBotIDs).union([currentUserID])).sorted()
    let needsConfirmation = agentContext != nil || !groupIDs.isEmpty

    var createdPeer: InlineKit.Peer?
    do {
      let chatID = try await realtimeV2.createThreadLocally(
        title: nil,
        placeholderTitle: Self.placeholderTitle(for: rawText),
        emoji: nil,
        isPublic: threadIsPublic,
        spaceId: destinationSpaceID,
        participants: participants,
        agentContext: agentContext,
        requireServerConfirmation: needsConfirmation
      )
      let peer: InlineKit.Peer = .thread(id: chatID)
      createdPeer = peer
      // A new thread belongs to Inbox right away, matching macOS.
      await realtimeV2.sendQueued(.updateDialogOpen(peerId: peer, open: true, requiresChatCreated: true))

      if !threadIsPublic {
        for groupID in groupIDs {
          try await realtimeV2.send(.addChatParticipant(chatID: chatID, groupID: groupID))
        }
      }

      let admitted = await realtimeV2.sendQueuedIfAccepted(.sendMessage(
        text: rawText,
        peerId: peer,
        chatId: chatID,
        entities: normalizedEntities
      )) != nil
      if !admitted {
        let revision = Drafts2.shared.updateText(peer: peer, text: rawText)
        _ = Drafts2.shared.updateEntities(peer: peer, entities: normalizedEntities, forRevision: revision)
        showError("The thread was created, but the message couldn't be sent. It was saved as a draft.")
      }
      clearDraft()
      return peer
    } catch {
      log.error("Failed to start a thread from the composer", error: error)
      if let createdPeer {
        let revision = Drafts2.shared.updateText(peer: createdPeer, text: rawText)
        _ = Drafts2.shared.updateEntities(peer: createdPeer, entities: normalizedEntities, forRevision: revision)
        showError("The thread was created, but the message couldn't be sent. It was saved as a draft.")
        clearDraft()
        return createdPeer
      }
      if let accessError = error as? AgentThreadSpaceAccessError {
        showError(accessError.localizedDescription)
      } else {
        showError("Couldn't start the thread. Your message is still here.")
      }
      return nil
    }
  }

  /// Matches macOS: the first 60 characters of the message, whitespace collapsed.
  static func placeholderTitle(for text: String) -> String {
    let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !normalized.isEmpty else { return "Message" }
    return String(normalized.prefix(60))
  }

  private func groupsBelong(_ groupIDs: [Int64], to spaceID: Int64) async -> Bool {
    let ids = Set(groupIDs)
    let count = try? await database.reader.read { db in
      try UserGroup
        .filter(ids.contains(UserGroup.Columns.id))
        .filter(UserGroup.Columns.spaceId == spaceID)
        .fetchCount(db)
    }
    return count == ids.count
  }

  /// The server adds only space members to space threads, so the user's own bots join
  /// the space first, once the user agrees. Returns false when the send should stop.
  private func admitOwnedBots(_ requested: Set<Int64>, spaceID: Int64, isPublic: Bool) async -> Bool {
    let ownedBots = Set(candidates.users.filter { $0.source == .ownedBot }.map(\.userInfo.id))
      .union(OwnedBotsDirectory.shared.snapshot.bots.map(\.id))
    guard !requested.isDisjoint(with: ownedBots) else { return true }

    let members: Set<Int64>
    do {
      guard case let .getSpaceMembers(response) = try await realtimeV2.send(.getSpaceMembers(spaceId: spaceID)) else {
        throw CancellationError()
      }
      members = Set(response.members.map(\.userID))
    } catch {
      log.error("Could not read the new thread's space members", error: error)
      showError("Couldn't check who's in \(selectedSpaceName ?? "the space"). Your message is still here.")
      return false
    }

    let missing = OwnedBotSpaceAdmission.botsToAdd(requested: requested, ownedBots: ownedBots, members: members)
    guard !missing.isEmpty else { return true }

    let names = missing.map { id in
      candidates.users.first { $0.userInfo.id == id }?.userInfo.user.displayName
        ?? OwnedBotsDirectory.shared.snapshot.bots.first { $0.id == id }?.user.displayName
        ?? String(localized: "your agent")
    }
    let spaceName = selectedSpaceName ?? String(localized: "this space")
    let agreed = await withCheckedContinuation { continuation in
      admissionPrompt = AdmissionPrompt(
        title: names.count == 1
          ? String(localized: "Add \(names[0]) to \(spaceName)?")
          : String(localized: "Add \(names.count) agents to \(spaceName)?"),
        message: isPublic
          ? String(localized: "It joins this space and can read its public threads. Everyone in the space can see it.")
          : String(localized: "It joins this space and can read only the threads it's added to. Everyone in the space can see it."),
        resume: { continuation.resume(returning: $0) }
      )
    }
    guard agreed else { return false }

    do {
      for botID in missing {
        try await realtimeV2.send(.inviteToSpace(
          spaceId: spaceID,
          access: .member(canAccessPublicChats: isPublic),
          userId: botID
        ))
      }
      return true
    } catch {
      log.error("Could not add owned bots to the new thread's space", error: error)
      showError("Couldn't add the agent to \(spaceName). You may need to be a space admin; your message is still here.")
      return false
    }
  }

  func answerAdmission(_ prompt: AdmissionPrompt, agreed: Bool) {
    // Answered once: the alert's button and its dismissal (or the sheet closing) can both
    // report, and a second resume would crash.
    guard admissionPrompt?.id == prompt.id else { return }
    admissionPrompt = nil
    prompt.resume(agreed)
  }

  private func showError(_ message: String) {
    ToastManager.shared.showToast(message, type: .error, systemImage: "exclamationmark.triangle")
  }

  // MARK: - Persistence

  private struct Keys {
    let visibility: String
    let draft: String
    let agentPrefix: String

    init(userID: Int64?) {
      let account = userID.map(String.init) ?? "signed-out"
      visibility = "ios.newThread.public.\(account)"
      draft = "ios.newThread.draft.\(account)"
      agentPrefix = "ios.newThread.agentConfiguration.\(account)"
    }
  }

  private struct StoredDraft: Codable {
    let text: String
    let entities: Data?
  }

  /// Draft text the editor should show when the sheet opens again.
  @Published private(set) var restoredDraft: NSAttributedString?

  private func restoreDraft() {
    guard attributedText.length == 0,
          let data = defaults.data(forKey: keys.draft),
          let stored = try? JSONDecoder().decode(StoredDraft.self, from: data),
          !stored.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    let entities = stored.entities.flatMap { try? MessageEntities(serializedBytes: $0) }
    let configuration = ProcessEntities.Configuration(
      font: NewThreadTextView.font,
      primaryColor: .label,
      linkColor: ThemeManager.shared.selected.accent,
      convertMentionsToLink: false,
      renderPhoneNumbers: false
    )
    let text = ProcessEntities.toAttributedString(text: stored.text, entities: entities, configuration: configuration)
    attributedText = text
    restoredDraft = text
    updateMentions(in: text)
  }

  private func saveDraft() {
    let (text, entities) = ProcessEntities.fromAttributedString(attributedText, parseMarkdown: false)
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      clearDraft()
      return
    }
    let stored = StoredDraft(
      text: text,
      entities: Drafts2.normalizedEntities(entities).flatMap { try? $0.serializedData() }
    )
    if let data = try? JSONEncoder().encode(stored) {
      defaults.set(data, forKey: keys.draft)
    }
  }

  private func clearDraft() {
    defaults.removeObject(forKey: keys.draft)
  }

  private func agentKey(_ field: String, target: AgentTarget) -> String {
    "\(keys.agentPrefix).\(target.botUserID).\(target.agentID ?? 0).\(field)"
  }

  private func savedAgentConfiguration(for target: AgentTarget) -> (project: String?, model: String?, reasoning: String?) {
    (
      defaults.string(forKey: agentKey("project", target: target)),
      defaults.string(forKey: agentKey("model", target: target)),
      defaults.string(forKey: agentKey("reasoning", target: target))
    )
  }

  private func saveAgentConfiguration() {
    guard let agentTarget else { return }
    for (field, value) in [
      ("project", selectedProjectID),
      ("model", selectedModelID),
      ("reasoning", selectedReasoningID),
    ] {
      let key = agentKey(field, target: agentTarget)
      if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
  }

  private func label(_ id: String?, in options: [AgentConfigurationOption]?) -> String? {
    guard let id else { return nil }
    return options?.first { $0.id == id }?.label ?? id
  }
}
