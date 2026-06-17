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

@MainActor
@Observable
public final class MentionCompletionViewModel {
  public private(set) var query = ""
  public private(set) var items: [UserInfo] = []
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

  public var selectedItem: UserInfo? {
    item(at: selectedIndex)
  }

  public var singleItem: UserInfo? {
    items.count == 1 ? items.first : nil
  }

  public func updateParticipants(_ participants: [UserInfo]) {
    updateCandidates(participants.map {
      MentionCompletionUser(userInfo: $0, source: .participant)
    })
  }

  public func updateCandidates(_ users: [MentionCompletionUser]) {
    let currentUserId = currentUserId()
    var candidatesByUserId: [Int64: MentionCompletionCandidate] = [:]

    for user in users {
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

    candidates = candidatesByUserId.values.sorted {
      if $0.source != $1.source {
        return $0.source.rawValue < $1.source.rawValue
      }

      if $0.sortText != $1.sortText {
        return $0.sortText < $1.sortText
      }

      return $0.userInfo.id < $1.userInfo.id
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

  public func item(at index: Int) -> UserInfo? {
    guard items.indices.contains(index) else { return nil }
    return items[index]
  }

  public func mentionText(for user: UserInfo) -> String {
    Self.mentionText(for: user)
  }

  public nonisolated static func mentionText(for user: UserInfo) -> String {
    let displayName = user.user.displayName
    let firstName = displayName.split(separator: " ").first.map(String.init) ?? displayName
    return "@\(firstName)"
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

  private func applyFilter(resetSelection: Bool, selectedId: Int64? = nil) {
    let normalizedQuery = Self.normalized(query, locale: locale)
    let compactQuery = Self.compact(normalizedQuery)

    let nextItems: [UserInfo]
    if normalizedQuery.isEmpty {
      nextItems = candidates.compactMap { candidate in
        candidate.source == .directChat ? nil : candidate.userInfo
      }
    } else {
      nextItems = candidates.compactMap { candidate in
        guard candidate.matches(normalizedQuery, compactQuery: compactQuery) else { return nil }
        return candidate.userInfo
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
  let userInfo: UserInfo
  let source: MentionCompletionSource
  let matchText: String
  let compactMatchText: String
  let sortText: String

  init(user: MentionCompletionUser, locale: Locale) {
    userInfo = user.userInfo
    source = user.source

    let values = Self.matchValues(for: user.userInfo)
      .map { MentionCompletionViewModel.normalized($0, locale: locale) }
      .filter { !$0.isEmpty }

    matchText = values.joined(separator: "\n")
    compactMatchText = MentionCompletionViewModel.compact(matchText)
    sortText = MentionCompletionViewModel.normalized(user.userInfo.user.displayName, locale: locale)
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
