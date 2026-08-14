import Foundation
import InlineKit

public struct InlineSearchUsageSignal: Sendable, Hashable {
  public let switchFrecency: Double
  public let queryAffinity: Double
  public let lastOpenedAt: Date?

  public init(
    switchFrecency: Double = 0,
    queryAffinity: Double = 0,
    lastOpenedAt: Date? = nil
  ) {
    self.switchFrecency = switchFrecency
    self.queryAffinity = queryAffinity
    self.lastOpenedAt = lastOpenedAt
  }
}

public struct InlineSearchChatProjection: Sendable, Equatable {
  public let suggestions: [InlineSearchChatResult]
  public let chats: [InlineSearchChatResult]
  public let knownUsers: [InlineSearchLocalUserResult]

  public static let empty = Self(suggestions: [], chats: [], knownUsers: [])
}

public actor InlineSearchChatCatalog {
  private var entries: [Entry] = []
  private var knownUserEntries: [KnownUserEntry] = []

  public init() {}

  public func replace(_ snapshots: [HomeChatListItemSnapshot], knownUsers: [User] = []) {
    var previousByPeer: [Peer: Entry] = [:]
    previousByPeer.reserveCapacity(entries.count)
    for entry in entries {
      previousByPeer[entry.snapshot.peerId] = entry
    }

    entries = snapshots.enumerated().map { index, snapshot in
      Entry(
        snapshot: snapshot,
        productIndex: index,
        reusing: previousByPeer[snapshot.peerId]
      )
    }

    let dialogUserIDs = Set(snapshots.compactMap { snapshot -> Int64? in
      guard case let .user(id) = snapshot.peerId else { return nil }
      return id
    })
    knownUserEntries = knownUsers.compactMap { user in
      guard user.id > 0,
            user.pendingSetup != true,
            dialogUserIDs.contains(user.id) == false,
            user.needsDisplayNameFetch == false
      else { return nil }
      return KnownUserEntry(user: user)
    }
  }

  public func project(
    query: String,
    usage: [Peer: InlineSearchUsageSignal],
    currentPeer: Peer?,
    currentUserID: Int64? = nil,
    contextSpaceId: Int64? = nil,
    scope: InlineSearchScope,
    suggestionLimit: Int = 5,
    chatLimit: Int = 20
  ) -> InlineSearchChatProjection {
    guard let preparedQuery = InlineSearchMatcher.prepare(query) else {
      let candidates = entries.filter {
        Self.includes($0, currentPeer: currentPeer, scope: scope)
      }
      let suggestions = candidates
        .compactMap { entry -> RankedSuggestion? in
          let signal = usage[entry.snapshot.peerId] ?? InlineSearchUsageSignal()
          guard signal.switchFrecency > 0 else { return nil }
          return RankedSuggestion(entry: entry, signal: signal)
        }
        .sorted(by: Self.suggestionPrecedes)
        .prefix(max(0, suggestionLimit))

      let suggestionPeers = Set(suggestions.map { $0.entry.snapshot.peerId })
      let chats = candidates
        .filter { suggestionPeers.contains($0.snapshot.peerId) == false }
        .prefix(max(0, chatLimit))
        .map { Self.result(from: $0, score: 0) }

      return InlineSearchChatProjection(
        suggestions: suggestions.map {
          Self.result(from: $0.entry, score: Self.suggestionScore($0.signal))
        },
        chats: chats,
        knownUsers: []
      )
    }

    let resultLimit = max(0, chatLimit)
    guard resultLimit > 0 else {
      return InlineSearchChatProjection(suggestions: [], chats: [], knownUsers: [])
    }

    var bestMatches: [RankedSearchResult] = []
    bestMatches.reserveCapacity(resultLimit)
    for entry in entries {
      guard Self.includes(entry, currentPeer: currentPeer, scope: scope) else { continue }
      guard let match = InlineSearchMatcher.match(
        query: preparedQuery,
        preparedFields: entry.fields
      ) else { continue }

      Self.insert(
        RankedSearchResult(
          entry: entry,
          match: match,
          usage: usage[entry.snapshot.peerId] ?? InlineSearchUsageSignal(),
          currentSpace: contextSpaceId != nil && entry.spaceId == contextSpaceId
        ),
        into: &bestMatches,
        limit: resultLimit
      )
    }

    let ranked = bestMatches.map { ranked in
      Self.result(from: ranked.entry, score: Self.searchScore(ranked))
    }

    var bestKnownUsers: [RankedKnownUser] = []
    if scope.spaceId == nil {
      bestKnownUsers.reserveCapacity(resultLimit)
      for entry in knownUserEntries {
        guard entry.user.id != currentUserID,
              currentPeer != .user(id: entry.user.id),
              let match = InlineSearchMatcher.match(query: preparedQuery, preparedFields: entry.fields)
        else { continue }
        Self.insert(
          RankedKnownUser(entry: entry, match: match),
          into: &bestKnownUsers,
          limit: resultLimit
        )
      }
    }
    let knownUsers = bestKnownUsers.map {
      InlineSearchLocalUserResult(
        user: $0.entry.user,
        score: Self.knownUserSearchScore($0)
      )
    }

    return InlineSearchChatProjection(suggestions: [], chats: ranked, knownUsers: knownUsers)
  }

  private static func result(from entry: Entry, score: Int) -> InlineSearchChatResult {
    InlineSearchChatResult(snapshot: entry.snapshot, messageCount: 0, score: score)
  }

  private static func includes(
    _ entry: Entry,
    currentPeer: Peer?,
    scope: InlineSearchScope
  ) -> Bool {
    guard entry.snapshot.peerId != currentPeer else { return false }
    guard scope.includeArchived || entry.snapshot.archived == false else { return false }

    if let spaceId = scope.spaceId {
      return entry.spaceId == spaceId
    }
    if scope.includeSpaceChatsInHome == false {
      return entry.spaceId == nil
    }
    return true
  }

  private static func suggestionPrecedes(_ lhs: RankedSuggestion, _ rhs: RankedSuggestion) -> Bool {
    if lhs.signal.switchFrecency != rhs.signal.switchFrecency {
      return lhs.signal.switchFrecency > rhs.signal.switchFrecency
    }
    if lhs.signal.lastOpenedAt != rhs.signal.lastOpenedAt {
      return (lhs.signal.lastOpenedAt ?? .distantPast) > (rhs.signal.lastOpenedAt ?? .distantPast)
    }
    return lhs.entry.productIndex < rhs.entry.productIndex
  }

  private static func searchResultPrecedes(_ lhs: RankedSearchResult, _ rhs: RankedSearchResult) -> Bool {
    if lhs.match.tier != rhs.match.tier {
      return lhs.match.tier > rhs.match.tier
    }
    if lhs.usage.queryAffinity != rhs.usage.queryAffinity {
      return lhs.usage.queryAffinity > rhs.usage.queryAffinity
    }
    if lhs.usage.switchFrecency != rhs.usage.switchFrecency {
      return lhs.usage.switchFrecency > rhs.usage.switchFrecency
    }
    if lhs.match.fieldPriority != rhs.match.fieldPriority {
      return lhs.match.fieldPriority > rhs.match.fieldPriority
    }
    if lhs.currentSpace != rhs.currentSpace {
      return lhs.currentSpace
    }

    let lhsWeakSignal = (lhs.entry.snapshot.pinned ? 2 : 0) + (lhs.entry.snapshot.unread ? 1 : 0)
    let rhsWeakSignal = (rhs.entry.snapshot.pinned ? 2 : 0) + (rhs.entry.snapshot.unread ? 1 : 0)
    if lhsWeakSignal != rhsWeakSignal {
      return lhsWeakSignal > rhsWeakSignal
    }
    if lhs.entry.snapshot.sortDate != rhs.entry.snapshot.sortDate {
      return lhs.entry.snapshot.sortDate > rhs.entry.snapshot.sortDate
    }

    let lhsPeer = lhs.entry.snapshot.peerId
    let rhsPeer = rhs.entry.snapshot.peerId
    if lhsPeer.id != rhsPeer.id {
      return lhsPeer.id < rhsPeer.id
    }
    return lhsPeer.isPrivate && rhsPeer.isThread
  }

  private static func knownUserResultPrecedes(_ lhs: RankedKnownUser, _ rhs: RankedKnownUser) -> Bool {
    if lhs.match != rhs.match {
      return InlineSearchMatch.isBetter(lhs.match, than: rhs.match)
    }
    let nameOrder = lhs.entry.user.displayName.localizedCaseInsensitiveCompare(rhs.entry.user.displayName)
    if nameOrder != .orderedSame {
      return nameOrder == .orderedAscending
    }
    return lhs.entry.user.id < rhs.entry.user.id
  }

  private static func insert(
    _ candidate: RankedSearchResult,
    into results: inout [RankedSearchResult],
    limit: Int
  ) {
    if results.count == limit,
       let last = results.last,
       searchResultPrecedes(candidate, last) == false {
      return
    }

    var lowerBound = 0
    var upperBound = results.count
    while lowerBound < upperBound {
      let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
      if searchResultPrecedes(results[midpoint], candidate) {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }

    results.insert(candidate, at: lowerBound)
    if results.count > limit {
      results.removeLast()
    }
  }

  private static func insert(
    _ candidate: RankedKnownUser,
    into results: inout [RankedKnownUser],
    limit: Int
  ) {
    if results.count == limit,
       let last = results.last,
       knownUserResultPrecedes(candidate, last) == false {
      return
    }

    var lowerBound = 0
    var upperBound = results.count
    while lowerBound < upperBound {
      let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
      if knownUserResultPrecedes(results[midpoint], candidate) {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }

    results.insert(candidate, at: lowerBound)
    if results.count > limit {
      results.removeLast()
    }
  }

  private static func suggestionScore(_ signal: InlineSearchUsageSignal) -> Int {
    Int(min(signal.switchFrecency * 100, 1_000_000))
  }

  private static func searchScore(_ result: RankedSearchResult) -> Int {
    let tier = result.match.tier.rawValue * 100_000
    let query = Int(min(result.usage.queryAffinity * 1_000, 90_000))
    let usage = Int(min(result.usage.switchFrecency * 100, 9_000))
    return tier + query + usage + result.match.fieldPriority
  }

  private static func knownUserSearchScore(_ result: RankedKnownUser) -> Int {
    result.match.tier.rawValue * 100_000 + result.match.fieldPriority
  }

  private struct Entry: Sendable {
    let snapshot: HomeChatListItemSnapshot
    let fields: [InlineSearchPreparedField]
    let searchKey: SearchKey
    let spaceId: Int64?
    let productIndex: Int

    init(snapshot: HomeChatListItemSnapshot, productIndex: Int, reusing previous: Entry?) {
      self.snapshot = snapshot
      self.productIndex = productIndex
      spaceId = snapshot.item.dialog.spaceId ?? snapshot.item.chat?.spaceId ?? snapshot.item.space?.id

      let user = snapshot.item.displayUserInfo?.user
      searchKey = SearchKey(
        title: snapshot.title,
        username: user?.username,
        email: user?.email,
        chatTitle: snapshot.item.chat?.title,
        spaceTitle: snapshot.spaceTitle
      )
      if let previous, previous.searchKey == searchKey {
        fields = previous.fields
      } else {
        fields = [
          InlineSearchField(searchKey.title, priority: 400),
          InlineSearchField(searchKey.username, priority: 500),
          InlineSearchField(searchKey.email, priority: 200),
          InlineSearchField(searchKey.chatTitle, priority: 400),
          InlineSearchField(searchKey.spaceTitle, priority: 100),
        ].compactMap(InlineSearchMatcher.prepareField)
      }
    }

    struct SearchKey: Sendable, Hashable {
      let title: String
      let username: String?
      let email: String?
      let chatTitle: String?
      let spaceTitle: String?
    }
  }

  private struct KnownUserEntry: Sendable {
    let user: User
    let fields: [InlineSearchPreparedField]

    init(user: User) {
      self.user = user
      fields = [
        InlineSearchField(user.displayName, priority: 500),
        InlineSearchField(user.username, priority: 600),
        InlineSearchField(user.email, priority: 200),
      ].compactMap(InlineSearchMatcher.prepareField)
    }
  }

  private struct RankedSuggestion: Sendable {
    let entry: Entry
    let signal: InlineSearchUsageSignal
  }

  private struct RankedSearchResult: Sendable {
    let entry: Entry
    let match: InlineSearchMatch
    let usage: InlineSearchUsageSignal
    let currentSpace: Bool
  }

  private struct RankedKnownUser: Sendable {
    let entry: KnownUserEntry
    let match: InlineSearchMatch
  }
}
