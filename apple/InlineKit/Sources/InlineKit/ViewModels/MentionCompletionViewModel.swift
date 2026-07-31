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

  public init(userInfo: UserInfo, source: MentionCompletionSource, lastMsgId: Int64? = nil) {
    self.userInfo = userInfo
    self.source = source
    self.lastMsgId = lastMsgId
  }
}

public struct MentionCompletionCandidates: Equatable, Sendable {
  public var users: [MentionCompletionUser]
  public var groups: [UserGroup]

  public static let empty = MentionCompletionCandidates(users: [], groups: [])

  public init(users: [MentionCompletionUser], groups: [UserGroup]) {
    self.users = users
    self.groups = groups
  }
}

public enum MentionCompletionItem: Hashable, Identifiable, Sendable {
  case user(MentionCompletionUser)
  case group(UserGroup)

  public var id: String {
    switch self {
      case let .user(user):
        "user:\(user.userInfo.user.id)"
      case let .group(group):
        "group:\(group.id)"
    }
  }

  public var userInfo: UserInfo? {
    switch self {
      case let .user(user):
        user.userInfo
      case .group:
        nil
    }
  }

  public var group: UserGroup? {
    switch self {
      case .user:
        nil
      case let .group(group):
        group
    }
  }

  public var title: String {
    switch self {
      case let .user(user):
        user.userInfo.user.displayName
      case let .group(group):
        group.name
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
    var candidatesByUserId: [Int64: MentionCompletionCandidate] = [:]
    var groupCandidatesById: [Int64: MentionCompletionCandidate] = [:]

    for user in input.users {
      guard user.userInfo.user.pendingSetup != true else { continue }
      guard user.source != .directChat || (user.lastMsgId ?? 0) > 0 else { continue }
      if let currentUserId, user.userInfo.user.id == currentUserId {
        continue
      }

      let candidate = MentionCompletionCandidate(user: user, locale: locale)
      if let existing = candidatesByUserId[user.userInfo.id],
         existing.source.rawValue <= candidate.source.rawValue
      {
        continue
      }

      candidatesByUserId[user.userInfo.id] = candidate
    }

    for group in input.groups where group.id > 0 {
      groupCandidatesById[group.id] = MentionCompletionCandidate(group: group, locale: locale)
    }

    candidates = (Array(groupCandidatesById.values) + Array(candidatesByUserId.values)).sorted {
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
    switch item {
      case let .user(user):
        return Self.query(query, exactlyMatches: user.userInfo, locale: locale)
      case let .group(group):
        let normalizedQuery = normalized(query, locale: locale)
        guard !normalizedQuery.isEmpty else { return false }
        return normalized(group.name, locale: locale) == normalizedQuery
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
      nextItems = candidates.compactMap { candidate in
        guard candidate.matches(normalizedQuery, compactQuery: compactQuery) else { return nil }
        return candidate.item
      }
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

private struct MentionCompletionCandidate: Equatable {
  let item: MentionCompletionItem
  let sortRank: Int
  let matchText: String
  let compactMatchText: String
  let sortText: String

  var id: String {
    item.id
  }

  var source: MentionCompletionSource {
    switch item {
      case let .user(user):
        user.source
      case .group:
        .participant
    }
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

    let values = Self.matchValues(for: user.userInfo)
      .map { MentionCompletionViewModel.normalized($0, locale: locale) }
      .filter { !$0.isEmpty }

    matchText = values.joined(separator: "\n")
    compactMatchText = MentionCompletionViewModel.compact(matchText)
    sortText = MentionCompletionViewModel.normalized(user.userInfo.user.displayName, locale: locale)
  }

  init(group: UserGroup, locale: Locale) {
    item = .group(group)
    sortRank = 0

    var values = [group.name]
    if let description = group.description {
      values.append(description)
    }

    let normalizedValues = values
      .map { MentionCompletionViewModel.normalized($0, locale: locale) }
      .filter { !$0.isEmpty }

    matchText = normalizedValues.joined(separator: "\n")
    compactMatchText = MentionCompletionViewModel.compact(matchText)
    sortText = MentionCompletionViewModel.normalized(group.name, locale: locale)
  }

  func matches(_ query: String, compactQuery: String) -> Bool {
    matchText.contains(query) || (!compactQuery.isEmpty && compactMatchText.contains(compactQuery))
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
