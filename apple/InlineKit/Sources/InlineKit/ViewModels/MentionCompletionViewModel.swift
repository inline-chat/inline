import Auth
import Foundation
import Observation

public enum MentionCompletionSource: Int, Sendable {
  case participant
  case spaceMember
  case directChat
}

public struct MentionCompletionUser: Hashable, Sendable {
  public var userInfo: UserInfo
  public var source: MentionCompletionSource
  public var lastMsgId: Int64?
  public var isPinned: Bool

  public init(
    userInfo: UserInfo,
    source: MentionCompletionSource,
    lastMsgId: Int64? = nil,
    isPinned: Bool = false
  ) {
    self.userInfo = userInfo
    self.source = source
    self.lastMsgId = lastMsgId
    self.isPinned = isPinned
  }

  /// Keep the strongest source without losing the same person's direct-chat signals.
  static func mergingDuplicates(_ users: [Self]) -> [Self] {
    var indicesById: [Int64: Int] = [:]
    var merged: [Self] = []
    for user in users {
      guard let index = indicesById[user.userInfo.id] else {
        indicesById[user.userInfo.id] = merged.count
        merged.append(user)
        continue
      }

      let existing = merged[index]
      var preferred = existing.source.rawValue <= user.source.rawValue ? existing : user
      preferred.isPinned = existing.isPinned || user.isPinned
      preferred.lastMsgId = max(existing.lastMsgId ?? 0, user.lastMsgId ?? 0)
      merged[index] = preferred
    }
    return merged
  }
}

public struct MentionCompletionCandidates: Equatable, Sendable {
  public var users: [MentionCompletionUser]
  public var groups: [UserGroup]
  public var agents: [MentionableBotAgent]

  public static let empty = MentionCompletionCandidates(users: [], groups: [], agents: [])

  public init(
    users: [MentionCompletionUser],
    groups: [UserGroup],
    agents: [MentionableBotAgent] = []
  ) {
    self.users = users
    self.groups = groups
    self.agents = agents
  }
}

public enum MentionCompletionItem: Hashable, Identifiable, Sendable {
  case user(MentionCompletionUser)
  case group(UserGroup)
  case agent(MentionableBotAgent)

  public var id: String {
    switch self {
      case let .user(user):
        "user:\(user.userInfo.user.id)"
      case let .group(group):
        "group:\(group.id)"
      case let .agent(agent):
        "agent:\(agent.id)"
    }
  }

  public var userInfo: UserInfo? {
    switch self {
      case let .user(user):
        user.userInfo
      case .group:
        nil
      case let .agent(agent):
        agent.botUserInfo
    }
  }

  public var group: UserGroup? {
    switch self {
      case .user:
        nil
      case let .group(group):
        group
      case .agent:
        nil
    }
  }

  public var agent: MentionableBotAgent? {
    guard case let .agent(agent) = self else { return nil }
    return agent
  }

  public var title: String {
    switch self {
      case let .user(user):
        user.userInfo.user.displayName
      case let .group(group):
        group.name
      case let .agent(agent):
        agent.displayName
    }
  }

  public var subtitle: String? {
    switch self {
      case let .user(user):
        if let username = user.userInfo.user.username, !username.isEmpty {
          return "@\(username)"
        }
        return nil
      case let .group(group):
        let count = "\(group.memberCount) \(group.memberCount == 1 ? "person" : "people")"
        guard let description = group.description, !description.isEmpty else {
          return count
        }
        return "\(description) - \(count)"
      case let .agent(agent):
        guard let description = agent.description, !description.isEmpty else {
          return "via \(agent.botDisplayName)"
        }
        return "via \(agent.botDisplayName) · \(description)"
    }
  }
}

@MainActor
@Observable
public final class MentionCompletionViewModel {
  public private(set) var query = ""
  public private(set) var items: [MentionCompletionItem] = []
  public private(set) var selectedIndex = 0

  @ObservationIgnored private var candidates: [MentionCompletionCandidate] = []
  @ObservationIgnored private let currentUserId: @MainActor () -> Int64?
  @ObservationIgnored private let locale: Locale

  public init(
    currentUserId: @escaping @MainActor () -> Int64? = { Auth.shared.getCurrentUserId() },
    locale: Locale = .current
  ) {
    self.currentUserId = currentUserId
    self.locale = locale
  }

  public var isVisible: Bool {
    !items.isEmpty
  }

  public var selectedItem: MentionCompletionItem? {
    item(at: selectedIndex)
  }

  public var selectedUser: UserInfo? {
    selectedItem?.userInfo
  }

  public var singleItem: MentionCompletionItem? {
    items.count == 1 ? items.first : nil
  }

  public func updateParticipants(_ participants: [UserInfo]) {
    updateCandidates(MentionCompletionCandidates(users: participants.map {
      MentionCompletionUser(userInfo: $0, source: .participant)
    }, groups: []))
  }

  public func updateCandidates(_ users: [MentionCompletionUser]) {
    updateCandidates(MentionCompletionCandidates(users: users, groups: []))
  }

  public func updateCandidates(_ input: MentionCompletionCandidates) {
    let currentUserId = currentUserId()
    let users = MentionCompletionUser.mergingDuplicates(input.users.filter { user in
      user.userInfo.user.pendingSetup != true &&
        (user.source != .directChat || (user.lastMsgId ?? 0) > 0) &&
        user.userInfo.user.id != currentUserId
    })
    let usersById = Dictionary(uniqueKeysWithValues: users.map { ($0.userInfo.id, $0) })
    var groupCandidatesById: [Int64: MentionCompletionCandidate] = [:]
    var agentCandidatesById: [Int64: MentionCompletionCandidate] = [:]

    for group in input.groups where group.id > 0 {
      groupCandidatesById[group.id] = MentionCompletionCandidate(group: group, locale: locale)
    }

    for agent in input.agents where agent.id > 0 && agent.botUserId > 0 {
      agentCandidatesById[agent.id] = MentionCompletionCandidate(
        agent: agent,
        relationship: usersById[agent.botUserId],
        locale: locale
      )
    }

    // Query-independent order is computed only when the observed candidates change.
    // Filtering keeps this order inside each relevance tier, without sorting per keystroke.
    candidates = (
      Array(groupCandidatesById.values) +
        Array(agentCandidatesById.values) +
        users.map { MentionCompletionCandidate(user: $0, locale: locale) }
    ).sorted {
      if $0.isPinned != $1.isPinned {
        return $0.isPinned
      }

      if $0.lastMsgId != $1.lastMsgId {
        return $0.lastMsgId > $1.lastMsgId
      }

      if $0.sortRank != $1.sortRank {
        return $0.sortRank < $1.sortRank
      }

      if $0.sortText != $1.sortText {
        return $0.sortText < $1.sortText
      }

      return $0.id < $1.id
    }

    let selectedId = selectedItem?.id
    applyFilter(resetSelection: false, selectedId: selectedId)
  }

  public func filter(with query: String) {
    guard self.query != query else { return }
    self.query = query
    applyFilter(resetSelection: true)
  }

  public func clear() {
    query = ""
    items = []
    selectedIndex = 0
  }

  public func selectNext() {
    guard !items.isEmpty else { return }
    selectedIndex = (selectedIndex + 1) % items.count
  }

  public func selectPrevious() {
    guard !items.isEmpty else { return }
    selectedIndex = selectedIndex > 0 ? selectedIndex - 1 : items.count - 1
  }

  public func select(index: Int) {
    guard items.indices.contains(index) else { return }
    selectedIndex = index
  }

  public func item(at index: Int) -> MentionCompletionItem? {
    guard items.indices.contains(index) else { return nil }
    return items[index]
  }

  public func mentionText(for item: MentionCompletionItem) -> String {
    switch item {
      case let .user(user):
        Self.mentionText(for: user.userInfo)
      case let .group(group):
        Self.mentionText(for: group)
      case let .agent(agent):
        "@\(agent.displayName)"
    }
  }

  public nonisolated static func mentionText(for user: UserInfo) -> String {
    if user.user.bot,
       let botName = user.user.firstName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !botName.isEmpty {
      return "@\(botName)"
    }
    let displayName = user.user.displayName
    let firstName = displayName.split(separator: " ").first.map(String.init) ?? displayName
    return "@\(firstName)"
  }

  public nonisolated static func mentionText(for group: UserGroup) -> String {
    "@\(group.name)"
  }

  public nonisolated static func query(
    _ query: String,
    exactlyMatches user: UserInfo,
    locale: Locale = .current
  ) -> Bool {
    let normalizedQuery = normalized(query, locale: locale)
    guard !normalizedQuery.isEmpty else { return false }

    return MentionCompletionCandidate.exactMatchValues(for: user, locale: locale)
      .contains(normalizedQuery)
  }

  public nonisolated static func query(
    _ query: String,
    exactlyMatches item: MentionCompletionItem,
    locale: Locale = .current
  ) -> Bool {
    let normalizedQuery = normalized(query, locale: locale)
    guard !normalizedQuery.isEmpty else { return false }
    switch item {
      case let .user(user):
        return Self.query(query, exactlyMatches: user.userInfo, locale: locale)
      case let .group(group):
        return normalized(group.name, locale: locale) == normalizedQuery
      case let .agent(agent):
        let values = [agent.name, agent.handle].compactMap { $0 }
        return values
          .map { normalized($0, locale: locale) }
          .contains(normalizedQuery)
    }
  }

  private func applyFilter(resetSelection: Bool, selectedId: String? = nil) {
    let normalizedQuery = Self.normalized(query, locale: locale)
    let compactQuery = Self.compact(normalizedQuery)

    let nextItems: [MentionCompletionItem]
    if normalizedQuery.isEmpty {
      nextItems = candidates.compactMap { candidate in
        candidate.isDirectChat ? nil : candidate.item
      }
    } else {
      var tiers = Array(repeating: [MentionCompletionItem](), count: MentionMatchRank.allCases.count)
      for candidate in candidates {
        guard let rank = candidate.matchRank(normalizedQuery, compactQuery: compactQuery) else { continue }
        tiers[rank.rawValue].append(candidate.item)
      }
      nextItems = tiers.flatMap(\.self)
    }

    items = nextItems

    if resetSelection {
      selectedIndex = 0
      return
    }

    if let selectedId, let index = items.firstIndex(where: { $0.id == selectedId }) {
      selectedIndex = index
      return
    }

    selectedIndex = items.isEmpty ? 0 : min(selectedIndex, items.count - 1)
  }

  fileprivate nonisolated static func normalized(_ text: String, locale: Locale) -> String {
    text
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
      .lowercased()
  }

  fileprivate nonisolated static func compact(_ text: String) -> String {
    text.filter { !$0.isWhitespace }
  }
}

private enum MentionMatchRank: Int, CaseIterable {
  case exactUsername
  case exactName
  case prefix
  case substring
  case detail
}

private struct MentionCompletionCandidate {
  let item: MentionCompletionItem
  let sortRank: Int
  let sortText: String
  let isPinned: Bool
  let lastMsgId: Int64
  private let fields: [MatchField]

  var id: String {
    item.id
  }

  var isDirectChat: Bool {
    if case let .user(user) = item {
      return user.source == .directChat
    }
    return false
  }

  init(user: MentionCompletionUser, locale: Locale) {
    item = .user(user)
    sortRank = user.source.rawValue + 1
    isPinned = user.isPinned
    lastMsgId = user.lastMsgId ?? 0
    fields = Self.fields([user.userInfo.user.username], exactRank: .exactUsername, locale: locale) +
      Self.fields(
        [user.userInfo.user.displayName, user.userInfo.user.fullName],
        exactRank: .exactName,
        locale: locale
      )
    sortText = MentionCompletionViewModel.normalized(user.userInfo.user.displayName, locale: locale)
  }

  init(group: UserGroup, locale: Locale) {
    item = .group(group)
    sortRank = 0
    isPinned = false
    lastMsgId = 0
    fields = Self.fields([group.name], exactRank: .exactName, locale: locale) +
      Self.fields([group.description], exactRank: .detail, locale: locale)
    sortText = MentionCompletionViewModel.normalized(group.name, locale: locale)
  }

  init(agent: MentionableBotAgent, relationship: MentionCompletionUser?, locale: Locale) {
    item = .agent(agent)
    sortRank = 1
    isPinned = relationship?.isPinned ?? false
    lastMsgId = relationship?.lastMsgId ?? 0
    fields = Self.fields([agent.handle], exactRank: .exactUsername, locale: locale) +
      Self.fields([agent.name], exactRank: .exactName, locale: locale) +
      Self.fields(
        [agent.description, agent.botDisplayName, agent.botUserInfo.user.username],
        exactRank: .detail,
        locale: locale
      )
    sortText = MentionCompletionViewModel.normalized(agent.name, locale: locale)
  }

  func matchRank(_ query: String, compactQuery: String) -> MentionMatchRank? {
    var best: MentionMatchRank?
    for field in fields {
      guard let rank = field.matchRank(query, compactQuery: compactQuery) else { continue }
      if rank.rawValue < (best?.rawValue ?? Int.max) {
        best = rank
      }
      if best == .exactUsername { break }
    }
    return best
  }

  private static func fields(_ values: [String?], exactRank: MentionMatchRank, locale: Locale) -> [MatchField] {
    var seen = Set<String>()
    return values.compactMap { value in
      guard let value else { return nil }
      let text = MentionCompletionViewModel.normalized(value, locale: locale)
      guard !text.isEmpty, seen.insert(text).inserted else { return nil }
      return MatchField(text: text, exactRank: exactRank)
    }
  }

  private struct MatchField {
    let text: String
    let compactText: String
    let words: [Substring]
    let exactRank: MentionMatchRank

    init(text: String, exactRank: MentionMatchRank) {
      self.text = text
      compactText = MentionCompletionViewModel.compact(text)
      words = text.split(whereSeparator: \.isWhitespace)
      self.exactRank = exactRank
    }

    func matchRank(_ query: String, compactQuery: String) -> MentionMatchRank? {
      // Compact each field independently: "aden" + "aden" must never match "dena".
      guard text.contains(query) || (!compactQuery.isEmpty && compactText.contains(compactQuery)) else { return nil }
      guard exactRank != .detail else { return .detail }
      if text == query { return exactRank }
      let isPrefix = text.hasPrefix(query) || words.contains(where: { $0.hasPrefix(query) }) ||
        (!compactQuery.isEmpty && compactText.hasPrefix(compactQuery))
      return isPrefix ? .prefix : .substring
    }
  }

  static func exactMatchValues(for userInfo: UserInfo, locale: Locale) -> Set<String> {
    Set(
      matchValues(for: userInfo, includeFirstNames: true)
        .map { MentionCompletionViewModel.normalized($0, locale: locale) }
        .filter { !$0.isEmpty }
    )
  }

  private static func matchValues(for userInfo: UserInfo, includeFirstNames: Bool = false) -> [String] {
    var values = [
      userInfo.user.displayName,
      userInfo.user.fullName,
    ]

    if includeFirstNames {
      let firstNames = values.compactMap { $0.split(separator: " ").first.map(String.init) }
      values.append(contentsOf: firstNames)
    }

    if let username = userInfo.user.username {
      values.append(username)
    }

    return values
  }
}
